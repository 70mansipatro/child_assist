import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text_platform_interface/speech_to_text_platform_interface.dart';

import 'package:child_assist/app_services.dart';
import 'package:child_assist/core/permissions/permission_service.dart';
import 'package:child_assist/core/widgets/widgets.dart';
import 'package:child_assist/features/chat/screens/chat_screen.dart';
import 'package:child_assist/features/chat/services/text_to_speech_service.dart';
import 'package:child_assist/features/chat/services/voice_input.dart';
import 'package:child_assist/features/permissions/screens/permissions_screen.dart';
import 'package:child_assist/features/photos/services/photo_gallery_service.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

/// The device speech service as `speech_to_text` sees it. Tests push results, errors and
/// statuses the way the Android/iOS recogniser would.
class FakeSpeechPlatform extends SpeechToTextPlatform with MockPlatformInterfaceMixin {
  bool initResult = true;

  /// False: the device recogniser refuses to start (e.g. a session is still open).
  bool listenStarts = true;
  final List<String> calls = [];
  List<SpeechConfigOption>? initOptions;
  SpeechListenOptions? listenOptions;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<bool> initialize({debugLogging = false, List<SpeechConfigOption>? options}) async {
    calls.add('initialize');
    initOptions = options;
    return initResult;
  }

  @override
  Future<bool> listen({
    String? localeId,
    partialResults = true,
    onDevice = false,
    int listenMode = 0,
    sampleRate = 0,
    SpeechListenOptions? options,
  }) async {
    calls.add('listen');
    listenOptions = options;
    if (!listenStarts) return false;
    onStatus?.call(SpeechToText.listeningStatus);
    return true;
  }

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> cancel() async => calls.add('cancel');

  @override
  Future<List<dynamic>> locales() async => ['en_US:English (United States)', 'hi_IN:Hindi (India)'];

  void result(String words, {bool last = false}) => onTextRecognition!(jsonEncode({
        'alternates': [
          {'recognizedWords': words, 'confidence': 0.9},
        ],
        'resultType': last ? 2 : 0,
      }));

  /// The microphone is open: Android reports sound levels the whole time, even in silence.
  void soundLevel([double level = -2]) => onSoundLevel!(level);

  void error(String code) => onError!(jsonEncode({'errorMsg': code, 'permanent': true}));

  void status(String value) => onStatus!(value);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SpeechToTextVoiceInput', () {
    late FakeSpeechPlatform platform;
    late SpeechToTextVoiceInput voice;

    setUp(() {
      platform = FakeSpeechPlatform();
      SpeechToTextPlatform.instance = platform;
      // A fresh plugin object per test (the app uses the shared one).
      // ignore: invalid_use_of_visible_for_testing_member
      voice = SpeechToTextVoiceInput(speech: SpeechToText.withMethodChannel(), platform: TargetPlatform.android);
    });

    test('is unavailable on web and desktop and never touches the plugin there', () async {
      for (final unsupported in [
        SpeechToTextVoiceInput(isWeb: true, platform: TargetPlatform.android),
        SpeechToTextVoiceInput(platform: TargetPlatform.windows),
      ]) {
        expect(unsupported.isAvailable, isFalse);
        expect(await unsupported.initialize(), isFalse);
        await expectLater(
          unsupported.listen(),
          throwsA(isA<VoiceInputException>().having((e) => e.kind, 'kind', VoiceErrorKind.unavailable)),
        );
      }
      expect(platform.calls, isEmpty);
      expect(const UnavailableVoiceInput().isAvailable, isFalse);
    });

    test('initialises once, without Bluetooth, only when first used', () async {
      expect(platform.calls, isEmpty);
      expect(await voice.initialize(), isTrue);
      expect(await voice.initialize(), isTrue);
      expect(platform.calls, ['initialize']);
      expect(platform.initOptions, contains(SpeechToText.androidNoBluetooth));
    });

    test('a device without a speech service reports unavailable', () async {
      platform.initResult = false;
      expect(await voice.initialize(), isFalse);
      await expectLater(
        voice.listen(),
        throwsA(isA<VoiceInputException>().having((e) => e.kind, 'kind', VoiceErrorKind.unavailable)),
      );
      expect(platform.calls, isNot(contains('listen')));
    });

    test('reports partial results and completes once with the final transcript', () async {
      final partials = <String>[];
      final result = voice.listen(onPartialResult: partials.add);
      await pumpEventQueue();
      expect(voice.isListening, isTrue);
      expect(platform.listenOptions!.partialResults, isTrue);
      expect(platform.listenOptions!.listenFor, isNotNull, reason: 'never listens indefinitely');

      platform.result('Where did');
      platform.result('Where did I go');
      platform.result('Where did I go yesterday?', last: true);
      // A recogniser that repeats its final result must not produce a second message.
      platform.result('Where did I go yesterday?', last: true);
      platform.status(SpeechToText.doneStatus);

      expect(await result, 'Where did I go yesterday?');
      expect(partials, ['Where did', 'Where did I go']);
      expect(voice.isListening, isFalse);
    });

    test('stop asks the recogniser to finish; the final result completes listen', () async {
      final result = voice.listen();
      await pumpEventQueue();
      platform.result('What is your');
      await voice.stopListening();
      expect(platform.calls.last, 'stop');
      platform.result('What is your name?', last: true);
      expect(await result, 'What is your name?');
    });

    test('cancel discards the utterance', () async {
      final result = voice.listen();
      await pumpEventQueue();
      platform.result('Hello');
      await voice.cancelListening();
      expect(await result, isNull);
      expect(platform.calls.last, 'cancel');
      platform.result('Hello there', last: true);
      expect(voice.isListening, isFalse);
    });

    test('silence completes with an empty transcript instead of an error', () async {
      var result = voice.listen();
      await pumpEventQueue();
      platform.soundLevel();
      platform.error('error_no_match');
      expect(await result, '');

      result = voice.listen();
      await pumpEventQueue();
      platform.soundLevel();
      platform.error('error_speech_timeout');
      expect(await result, '');

      result = voice.listen();
      await pumpEventQueue();
      platform.status('doneNoResult');
      expect(await result, '');
    });

    test('"no match" before the microphone ever opened is not reported as silence', () async {
      // The phone's speech service failed: no sound level, no words, then "no match".
      final result = voice.listen();
      await pumpEventQueue();
      platform.error('error_speech_timeout');
      await expectLater(
        result,
        throwsA(isA<VoiceInputException>().having((e) => e.kind, 'kind', VoiceErrorKind.notStarted)),
      );
      expect(voice.isListening, isFalse);
      expect(VoiceErrorKind.notStarted.message, isNot(VoiceErrorKind.noSpeech.message));
    });

    test('a recogniser that refuses to start fails instead of hanging', () async {
      platform.listenStarts = false;
      await expectLater(
        voice.listen(),
        throwsA(isA<VoiceInputException>().having((e) => e.kind, 'kind', VoiceErrorKind.notStarted)),
      );
      expect(voice.isListening, isFalse);

      // The next tap can listen again.
      platform.listenStarts = true;
      final result = voice.listen();
      await pumpEventQueue();
      platform.result('What is my name?', last: true);
      expect(await result, 'What is my name?');
    });

    test('words alone prove the microphone was open', () async {
      final result = voice.listen();
      await pumpEventQueue();
      platform.result('Where did I');
      platform.error('error_no_match');
      expect(await result, 'Where did I');
    });

    test('concurrent first uses share one initialisation', () async {
      final both = await Future.wait([voice.initialize(), voice.initialize()]);
      expect(both, [true, true]);
      expect(platform.calls, ['initialize']);
    });

    test('can look up the recogniser by its component name', () async {
      // ignore: invalid_use_of_visible_for_testing_member
      final lookup = SpeechToTextVoiceInput(
        speech: SpeechToText.withMethodChannel(),
        platform: TargetPlatform.android,
        lookUpRecognizer: true,
      );
      expect(await lookup.initialize(), isTrue);
      expect(platform.initOptions, contains(SpeechToText.androidIntentLookup));
      expect(await voice.initialize(), isTrue);
      expect(platform.initOptions, isNot(contains(SpeechToText.androidIntentLookup)));
    });

    test('recognition errors become friendly error kinds', () async {
      final result = voice.listen();
      await pumpEventQueue();
      platform.error('error_network');
      await expectLater(
        result,
        throwsA(isA<VoiceInputException>().having((e) => e.kind, 'kind', VoiceErrorKind.network)),
      );
      expect(voice.isListening, isFalse);

      expect(SpeechToTextVoiceInput.errorKindFor('error_permission'), VoiceErrorKind.permissionDenied);
      expect(SpeechToTextVoiceInput.errorKindFor('error_busy'), VoiceErrorKind.busy);
      expect(SpeechToTextVoiceInput.errorKindFor('error_speech_timeout'), VoiceErrorKind.noSpeech);
      expect(SpeechToTextVoiceInput.errorKindFor('error_language_unavailable'), VoiceErrorKind.unavailable);
      expect(SpeechToTextVoiceInput.errorKindFor('error_client'), VoiceErrorKind.notStarted);
      expect(SpeechToTextVoiceInput.errorKindFor('error_unknown (42)'), VoiceErrorKind.unknown);
      for (final kind in VoiceErrorKind.values) {
        expect(kind.message, isNot(contains('error_')));
      }
    });

    test('a second listen while listening is refused', () async {
      unawaited(voice.listen());
      await pumpEventQueue();
      await expectLater(
        voice.listen(),
        throwsA(isA<VoiceInputException>().having((e) => e.kind, 'kind', VoiceErrorKind.busy)),
      );
    });

    test('lists recognition languages and stops listening on dispose', () async {
      final locales = await voice.locales();
      expect(locales.map((l) => l.id), ['en_US', 'hi_IN']);

      final result = voice.listen();
      await pumpEventQueue();
      await voice.dispose();
      expect(await result, isNull);
      expect(platform.calls.last, 'cancel');
    });
  });

  group('FlutterTextToSpeechService', () {
    const channel = MethodChannel('flutter_tts');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return 1;
      });
    });
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    Future<void> nativeEvent(String method) async {
      await messenger.handlePlatformMessage(
        'flutter_tts',
        const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
        (_) {},
      );
    }

    test('voice replies are off by default and nothing is spoken until asked', () async {
      final tts = FlutterTextToSpeechService(tts: FlutterTts(), platform: TargetPlatform.android);
      expect(tts.repliesEnabled, isFalse);
      expect(tts.isSpeaking, isFalse);
      expect(calls.where((c) => c.method == 'speak'), isEmpty);
    });

    test('speaks only the readable words and tracks when speech ends', () async {
      final tts = FlutterTextToSpeechService(tts: FlutterTts(), platform: TargetPlatform.android);
      await tts.speak('**You visited** the City Library yesterday. https://maps.example.com/x {"toolName":"x"}');
      final speak = calls.lastWhere((c) => c.method == 'speak');
      expect(speak.arguments, contains('You visited the City Library yesterday.'));
      expect(speak.arguments.toString(), isNot(contains('http')));
      expect(speak.arguments.toString(), isNot(contains('toolName')));
      expect(tts.isSpeaking, isTrue);

      await nativeEvent('speak.onComplete');
      expect(tts.isSpeaking, isFalse);
    });

    test('stop silences immediately; a new reply stops the previous one first', () async {
      final tts = FlutterTextToSpeechService(tts: FlutterTts(), platform: TargetPlatform.android);
      await tts.speak('First reply.');
      await tts.speak('Second reply.');
      final methods = calls.map((c) => c.method).toList();
      expect(methods.lastIndexOf('stop'), greaterThan(methods.indexOf('speak')));
      expect(methods.last, 'speak');

      await tts.stop();
      expect(calls.last.method, 'stop');
      expect(tts.isSpeaking, isFalse);
    });

    test('turning voice replies off stops speech; dispose cleans up', () async {
      final tts = FlutterTextToSpeechService(tts: FlutterTts(), platform: TargetPlatform.android);
      tts.repliesEnabled = true;
      await tts.speak('Hello.');
      tts.repliesEnabled = false;
      await pumpEventQueue();
      expect(calls.last.method, 'stop');
      expect(tts.isSpeaking, isFalse);

      await tts.speak('Again.');
      calls.clear();
      tts.dispose();
      await pumpEventQueue();
      expect(calls.map((c) => c.method), contains('stop'));
    });

    test('unsupported platforms never call the engine', () async {
      final tts = FlutterTextToSpeechService(platform: TargetPlatform.linux);
      expect(tts.isAvailable, isFalse);
      await tts.speak('Hello.');
      await tts.stop();
      expect(calls, isEmpty);
    });

    test('secrets, ids and raw JSON are never read aloud', () {
      const jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1MSJ9.abc123def456';
      final out = speakableText(
        'Here you go. $jwt id 550e8400-e29b-41d4-a716-446655440000 key AIzaSyA1b2C3d4E5f6G7h8I9j0KlMnOp '
        '```{"a":1}``` `get_location_history` done.',
      );
      expect(out, 'Here you go. id key done.');
    });
  });

  group('Voice chat', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    late FakeBackend backend;
    late FakePermissionService os;
    late FakeVoiceInput voice;
    late FakeTextToSpeech tts;
    late AppServices services;

    Future<void> startApp(WidgetTester tester, {bool voiceAvailable = true, List<PhotoItem> photos = const []}) async {
      // The listening button pulses; with reduced motion it does not, so frames can settle.
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      backend = FakeBackend();
      os = FakePermissionService();
      voice = FakeVoiceInput(available: voiceAvailable);
      tts = FakeTextToSpeech();
      services = backend.services(os, voiceInput: voice, textToSpeech: tts, photoLibrary: FakePhotoLibrary(photos));
      await services.authService.restoreSession();
      await tester.pumpWidget(MyApp(services: services));
      await tester.pumpAndSettle();
      await logIn(tester, 'mansi@example.com');
      await openTab(tester, 'Chat');
      expect(find.byType(ChatScreen), findsOneWidget);
      os.calls.clear();
    }

    // Spinners run while waiting for permission or a transcript, so pump a few frames
    // instead of waiting for everything to settle.
    Future<void> frames(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> tapMic(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Voice input'));
      await frames(tester);
    }

    Future<void> startListening(WidgetTester tester) async {
      os.os[AppPermission.microphone] = PermissionState.granted;
      await tapMic(tester);
      expect(find.text('Listening...'), findsOneWidget);
    }

    testWidgets('first tap explains, then shows the real OS dialog, then listens', (tester) async {
      await startApp(tester);
      await tapMic(tester);

      expect(find.text('Talk to Child Assist?'), findsOneWidget);
      expect(os.dialogsShown, isEmpty, reason: 'the explanation comes before the OS dialog');
      expect(voice.calls, isEmpty);

      await tester.tap(find.text('Continue'));
      await frames(tester);

      expect(os.dialogsShown, [AppPermission.microphone]);
      expect(find.text('Listening...'), findsOneWidget);
      expect(find.text('Tap to stop when you are done.'), findsOneWidget);
      expect(find.byTooltip('Stop listening'), findsOneWidget);
      expect(voice.calls, ['listen']);
      expect(backend.permissions['u1']?['MICROPHONE'], 'GRANTED');
    });

    testWidgets('the OS permission is checked even when the account says granted', (tester) async {
      await startApp(tester);
      backend.permissions['u1'] = {'MICROPHONE': 'GRANTED'};

      await tapMic(tester);
      expect(os.calls, contains('status microphone'));
      expect(find.text('Talk to Child Assist?'), findsOneWidget);
    });

    testWidgets('an already granted microphone starts listening straight away', (tester) async {
      await startApp(tester);
      await startListening(tester);
      expect(find.text('Talk to Child Assist?'), findsNothing);
      expect(os.dialogsShown, isEmpty);
    });

    testWidgets('one spoken sentence becomes exactly one normal chat message', (tester) async {
      await startApp(tester);
      await startListening(tester);

      Finder heard(String words) => find.descendant(of: find.byType(InfoBanner), matching: find.text(words));
      voice.hear('What is');
      await frames(tester);
      expect(heard('What is'), findsOneWidget);
      voice.hear('What is your name?');
      await frames(tester);
      expect(heard('What is your name?'), findsOneWidget);

      voice.finish('What is your name?');
      await tester.pumpAndSettle();

      expect(backend.chatRequests, hasLength(1));
      expect(backend.chatRequests.single['message'], 'What is your name?');
      expect(backend.chatRequests.single.containsKey('audio'), isFalse);
      expect(find.text('My name is Child Assist.'), findsOneWidget);
      expect(find.text('Listening...'), findsNothing);
      // Voice replies are off by default.
      expect(tts.spoken, isEmpty);
    });

    testWidgets('tapping stop sends what was heard once', (tester) async {
      await startApp(tester);
      await startListening(tester);
      voice.hear('Where did I go today?');
      await frames(tester);

      await tester.tap(find.byTooltip('Stop listening'));
      await tester.pumpAndSettle();
      // A late final result from the recogniser must not send again.
      voice.finish('Where did I go today?');
      await tester.pumpAndSettle();

      expect(voice.calls, ['listen', 'stop']);
      expect(backend.chatRequests.map((r) => r['message']), ['Where did I go today?']);
      expect(find.text('You said: Where did I go today?'), findsOneWidget);
    });

    testWidgets('saying nothing sends nothing', (tester) async {
      await startApp(tester);
      await startListening(tester);
      voice.silence();
      await tester.pumpAndSettle();

      expect(find.text("I didn't hear anything. Try again."), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(backend.chatRequests, isEmpty);

      await tester.tap(find.text('Try again'));
      await frames(tester);
      expect(find.text('Listening...'), findsOneWidget);
    });

    testWidgets('denying the permission never starts listening', (tester) async {
      await startApp(tester);
      os.onRequest[AppPermission.microphone] = PermissionState.denied;
      await tapMic(tester);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(os.dialogsShown, [AppPermission.microphone]);
      expect(find.text('Microphone permission is needed for voice chat.'), findsOneWidget);
      expect(find.text('Open Permissions'), findsOneWidget);
      expect(voice.calls, isEmpty);
      expect(backend.chatRequests, isEmpty);
      expect(backend.permissions['u1']?['MICROPHONE'], 'DENIED');
    });

    testWidgets('"Not now" shows no OS dialog and does not listen', (tester) async {
      await startApp(tester);
      await tapMic(tester);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      expect(os.dialogsShown, isEmpty);
      expect(voice.calls, isEmpty);
      expect(find.text('Microphone permission is needed for voice chat.'), findsOneWidget);
    });

    testWidgets('a blocked permission offers Open Permissions instead of a dialog', (tester) async {
      await startApp(tester);
      os.os[AppPermission.microphone] = PermissionState.permanentlyDenied;
      await tapMic(tester);
      await tester.pumpAndSettle();

      expect(find.text('Talk to Child Assist?'), findsNothing);
      expect(os.dialogsShown, isEmpty);
      expect(voice.calls, isEmpty);
      expect(find.textContaining('turn it on in Permissions'), findsOneWidget);

      await tester.tap(find.text('Open Permissions'));
      await tester.pumpAndSettle();
      expect(find.byType(PermissionsScreen), findsOneWidget);
    });

    testWidgets('a device without speech recognition explains and asks for nothing', (tester) async {
      await startApp(tester, voiceAvailable: false);
      await tapMic(tester);
      await tester.pumpAndSettle();

      expect(find.textContaining("Speech recognition isn't available on this device"), findsOneWidget);
      expect(os.calls, isEmpty);
      expect(os.dialogsShown, isEmpty);
    });

    testWidgets('recognition errors are friendly and send nothing', (tester) async {
      await startApp(tester);
      await startListening(tester);
      voice.fail(VoiceErrorKind.network);
      await tester.pumpAndSettle();

      expect(find.text(VoiceErrorKind.network.message), findsOneWidget);
      expect(find.textContaining('error_'), findsNothing);
      expect(find.textContaining('Exception'), findsNothing);
      expect(backend.chatRequests, isEmpty);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text(VoiceErrorKind.network.message), findsNothing);
    });

    testWidgets('a recogniser that never started is not "I didn\'t hear anything"', (tester) async {
      await startApp(tester);
      await startListening(tester);
      voice.fail(VoiceErrorKind.notStarted);
      await tester.pumpAndSettle();

      expect(find.text(VoiceErrorKind.notStarted.message), findsOneWidget);
      expect(find.text(VoiceErrorKind.noSpeech.message), findsNothing);
      expect(backend.chatRequests, isEmpty);

      // Try again listens once more and the spoken words go through the normal chat.
      await tester.tap(find.text('Try again'));
      await frames(tester);
      expect(find.text('Listening...'), findsOneWidget);
      voice.finish('What is my name?');
      await tester.pumpAndSettle();
      expect(backend.chatRequests, hasLength(1));
      expect(backend.chatRequests.single['message'], 'What is my name?');
    });

    testWidgets('voice replies read the reply aloud and can be stopped', (tester) async {
      await startApp(tester);
      expect(find.byTooltip('Voice replies: off'), findsOneWidget);
      await tester.tap(find.byTooltip('Voice replies: off'));
      await tester.pumpAndSettle();
      expect(tts.repliesEnabled, isTrue);
      expect(find.byTooltip('Voice replies: on'), findsOneWidget);

      await startListening(tester);
      voice.finish('What is your name?');
      await tester.pumpAndSettle();

      expect(tts.spoken, ['My name is Child Assist.']);
      expect(find.byTooltip('Stop speaking'), findsOneWidget);

      await tester.tap(find.byTooltip('Stop speaking'));
      await tester.pumpAndSettle();
      expect(tts.isSpeaking, isFalse);
      expect(find.byTooltip('Read aloud'), findsOneWidget);
    });

    testWidgets('a spoken "show me today\'s photo and explain it" looks at the photo with no tap', (tester) async {
      final now = DateTime.now();
      final taken = now.subtract(const Duration(minutes: 20));
      await startApp(tester, photos: [
        PhotoItem(id: 'v1', name: 'IMG_3001.jpg', width: 4000, height: 3000, createdAt: taken, modifiedAt: taken, mimeType: 'image/jpeg'),
      ]);
      os.os[AppPermission.photos] = PermissionState.granted;
      tts.repliesEnabled = true;
      final start = DateTime(now.year, now.month, now.day);
      backend.chatResponder = (_) => FakeChatReply('Let me find that photo and look at it.', toolEvents: [
            {
              'kind': 'photos',
              'status': 'device_lookup',
              'data': {
                'requestId': 'voice-search',
                'query': {
                  'startDate': start.toUtc().toIso8601String(),
                  'endDate': start.add(const Duration(days: 1)).toUtc().toIso8601String(),
                  'locationContext': false,
                  'latest': false,
                  'analyze': true,
                },
                'visits': const [],
              },
            },
          ]);

      await startListening(tester);
      voice.finish("Show me today's photo and explain it");
      await tester.pumpAndSettle();

      expect(backend.chatRequests.single['message'], "Show me today's photo and explain it");
      expect(backend.analysedImages, hasLength(1), reason: 'the actual photo was looked at');
      expect(find.text('Analyze'), findsNothing);
      expect(find.text('Answered from this photo.'), findsOneWidget);
      // With voice replies on, the answer from the image is read aloud as well.
      expect(tts.spoken.last, 'This photo shows an image of ${backend.analysedImages.single.length} bytes.');
    });

    testWidgets('typed messages are also read aloud when voice replies are on', (tester) async {
      await startApp(tester);
      tts.repliesEnabled = true;
      await tester.enterText(find.byType(TextField), 'Hello');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(tts.spoken, ['You said: Hello']);
    });

    testWidgets('tapping the microphone stops a reply that is being read', (tester) async {
      await startApp(tester);
      tts.repliesEnabled = true;
      await startListening(tester);
      voice.finish('What is your name?');
      await tester.pumpAndSettle();
      expect(tts.isSpeaking, isTrue);

      await tapMic(tester);
      expect(tts.isSpeaking, isFalse, reason: 'never listen while speaking');
      expect(find.text('Listening...'), findsOneWidget);
    });

    testWidgets('Read aloud works with voice replies off', (tester) async {
      await startApp(tester);
      await tester.enterText(find.byType(TextField), 'What is your name?');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(tts.spoken, isEmpty);

      await tester.tap(find.byTooltip('Read aloud'));
      await tester.pumpAndSettle();
      expect(tts.spoken, ['My name is Child Assist.']);
    });

    testWidgets('leaving the chat tab stops listening and speaking', (tester) async {
      await startApp(tester);
      tts.speak('Something');
      await startListening(tester);

      await openTab(tester, 'Dashboard');

      expect(voice.calls, contains('cancel'));
      expect(voice.isListening, isFalse);
      expect(tts.isSpeaking, isFalse);
      expect(backend.chatRequests, isEmpty);
    });

    testWidgets('the app going to the background stops the microphone', (tester) async {
      await startApp(tester);
      await startListening(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pumpAndSettle();

      expect(voice.calls, contains('cancel'));
      expect(voice.isListening, isFalse);

      // Hidden apps draw no frames; check the screen once it is back.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Listening...'), findsNothing);
      expect(backend.chatRequests, isEmpty);
    });

    testWidgets('the microphone is disabled while a reply is on its way', (tester) async {
      await startApp(tester);
      final reply = backend.chatPending = Completer<void>();
      await tester.enterText(find.byType(TextField), 'Hello');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();

      final mic = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.mic_none_rounded));
      expect(mic.onPressed, isNull);

      reply.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('a voice conversation is in History as text', (tester) async {
      await startApp(tester);
      await startListening(tester);
      voice.finish('What is your name?');
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('New Chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('History'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('What is your name?').first);
      await tester.pumpAndSettle();

      expect(find.text('What is your name?'), findsOneWidget);
      expect(find.text('My name is Child Assist.'), findsOneWidget);
    });
  });
}
