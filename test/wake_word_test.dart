import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/app_services.dart';
import 'package:child_assist/core/permissions/permission_service.dart';
import 'package:child_assist/features/chat/screens/chat_screen.dart';
import 'package:child_assist/features/photos/services/photo_gallery_service.dart';
import 'package:child_assist/features/voice_assistant/data/wake_word_platform.dart';
import 'package:child_assist/features/voice_assistant/screens/voice_assistant_screen.dart';
import 'package:child_assist/features/voice_assistant/services/wake_phrase.dart';
import 'package:child_assist/features/voice_assistant/services/wake_word_service.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------------------------------
  group('wake word state machine', () {
    WakeWordStateMachine at(List<WakeWordEvent> events) {
      final machine = WakeWordStateMachine();
      for (final e in events) {
        machine.fire(e);
      }
      return machine;
    }

    const listening = [WakeWordEvent.enable, WakeWordEvent.listening];

    test('a full question: wake phrase, question, answer read aloud, back to listening', () {
      final machine = WakeWordStateMachine();
      final path = <WakeWordState>[machine.state];
      for (final e in [
        WakeWordEvent.enable,
        WakeWordEvent.listening,
        WakeWordEvent.detected,
        WakeWordEvent.commandListening,
        WakeWordEvent.commandHeard,
        WakeWordEvent.replySpeaking,
        WakeWordEvent.replyDone,
      ]) {
        expect(machine.fire(e), isTrue, reason: '$e from ${machine.state}');
        path.add(machine.state);
      }
      expect(path, [
        WakeWordState.disabled,
        WakeWordState.starting,
        WakeWordState.listeningForWakeWord,
        WakeWordState.wakeWordDetected,
        WakeWordState.listeningForCommand,
        WakeWordState.processing,
        WakeWordState.speaking,
        WakeWordState.listeningForWakeWord,
      ]);
    });

    test('an answer that is not read aloud goes straight back to listening', () {
      final machine = at([...listening, WakeWordEvent.detected, WakeWordEvent.commandListening, WakeWordEvent.commandHeard]);
      expect(machine.fire(WakeWordEvent.replyDone), isTrue);
      expect(machine.state, WakeWordState.listeningForWakeWord);
    });

    test('only the wake phrase, then silence or a timeout: back to listening, never stuck', () {
      for (final events in [
        [...listening, WakeWordEvent.detected],
        [...listening, WakeWordEvent.detected, WakeWordEvent.commandListening],
      ]) {
        final machine = at(events);
        expect(machine.fire(WakeWordEvent.commandEnded), isTrue);
        expect(machine.state, WakeWordState.listeningForWakeWord);
      }
    });

    test('hearing the phrase again during a question is ignored', () {
      for (final events in [
        [...listening, WakeWordEvent.detected],
        [...listening, WakeWordEvent.detected, WakeWordEvent.commandListening],
        [...listening, WakeWordEvent.detected, WakeWordEvent.commandListening, WakeWordEvent.commandHeard],
        [...listening, WakeWordEvent.detected, WakeWordEvent.commandListening, WakeWordEvent.commandHeard, WakeWordEvent.replySpeaking],
      ]) {
        final machine = at(events);
        final before = machine.state;
        expect(machine.fire(WakeWordEvent.detected), isFalse);
        expect(machine.state, before);
      }
    });

    test('the phone pausing or resuming does not interrupt a question; a failure does', () {
      final machine = at([...listening, WakeWordEvent.detected, WakeWordEvent.commandListening]);
      expect(machine.fire(WakeWordEvent.paused), isFalse);
      expect(machine.fire(WakeWordEvent.listening), isFalse);
      expect(machine.state, WakeWordState.listeningForCommand);
      expect(machine.fire(WakeWordEvent.failed), isTrue);
      expect(machine.state, WakeWordState.error);
    });

    test('paused (call, microphone busy) and back; no wake phrase while paused', () {
      final machine = at([...listening, WakeWordEvent.paused]);
      expect(machine.state, WakeWordState.paused);
      expect(machine.fire(WakeWordEvent.detected), isFalse);
      expect(machine.fire(WakeWordEvent.listening), isTrue);
      expect(machine.state, WakeWordState.listeningForWakeWord);
    });

    test('switching off works from every state; nothing but "enable" leaves disabled', () {
      for (final state in WakeWordState.values) {
        final next = WakeWordStateMachine.transition(state, WakeWordEvent.disable);
        expect(next, state == WakeWordState.disabled ? isNull : WakeWordState.disabled, reason: '$state');
      }
      for (final event in WakeWordEvent.values) {
        final next = WakeWordStateMachine.transition(WakeWordState.disabled, event);
        expect(next, event == WakeWordEvent.enable ? WakeWordState.starting : isNull, reason: '$event');
      }
    });

    test('transitions are deterministic', () {
      for (final state in WakeWordState.values) {
        for (final event in WakeWordEvent.values) {
          expect(WakeWordStateMachine.transition(state, event), WakeWordStateMachine.transition(state, event));
        }
      }
    });
  });

  // ---------------------------------------------------------------------------------------------
  group('stripWakePhrase', () {
    test('the wake phrase is never part of the question', () {
      expect(stripWakePhrase('Hey Child, where did I go today?'), 'where did I go today?');
      expect(stripWakePhrase('hi child what time is it'), 'what time is it');
      expect(stripWakePhrase('Hey Child show me today\'s photo'), 'show me today\'s photo');
      expect(stripWakePhrase('hey child, hey child, what color dress is in that photo'), 'what color dress is in that photo');
      expect(stripWakePhrase('Hay child. Find my math notes'), 'Find my math notes');
      expect(stripWakePhrase('Child, what is in this picture?'), 'what is in this picture?');
    });

    test('only the wake phrase is an empty question', () {
      for (final heard in ['Hey Child', 'hi child!', 'Child', '  ', '']) {
        expect(stripWakePhrase(heard), '', reason: heard);
      }
    });

    test('questions that merely mention a child are left alone', () {
      for (final heard in [
        'Where did I go today?',
        'Child safety tips',
        'What is the child wearing in the photo?',
        'Hey, what time is it?',
        'Highchair reviews',
      ]) {
        expect(stripWakePhrase(heard), heard);
      }
    });
  });

  // ---------------------------------------------------------------------------------------------
  group('Hey Child in the app', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    late FakeBackend backend;
    late FakePermissionService os;
    late FakeVoiceInput voice;
    late FakeTextToSpeech tts;
    late FakeWakeWordPlatform phone;
    late FakePhotoLibrary gallery;
    late AppServices services;

    WakeWordService wake() => services.wakeWordService;

    Future<void> startApp(WidgetTester tester, {bool micGranted = true, List<PhotoItem> photos = const []}) async {
      // The listening button pulses; with reduced motion it does not, so frames can settle.
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      backend = FakeBackend();
      os = FakePermissionService();
      if (micGranted) os.os[AppPermission.microphone] = PermissionState.granted;
      os.os[AppPermission.notifications] = PermissionState.granted;
      voice = FakeVoiceInput();
      tts = FakeTextToSpeech();
      phone = FakeWakeWordPlatform();
      gallery = FakePhotoLibrary([...photos]);
      services = backend.services(os, voiceInput: voice, textToSpeech: tts, wakeWordPlatform: phone, photoLibrary: gallery);
      await services.authService.restoreSession();
      await tester.pumpWidget(MyApp(services: services));
      await tester.pumpAndSettle();
      await logIn(tester, 'mansi@example.com');
    }

    // Spinners run while listening, so pump frames instead of waiting for everything to settle.
    Future<void> frames(WidgetTester tester, [int count = 5]) async {
      for (var i = 0; i < count; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    /// The user switched it on (with the microphone already allowed: no dialogs).
    Future<void> switchOn(WidgetTester tester) async {
      await wake().enable();
      await frames(tester);
      expect(phone.listening, isTrue);
      expect(wake().state, WakeWordState.listeningForWakeWord);
    }

    Future<void> openVoiceAssistant(WidgetTester tester) async {
      await openTab(tester, 'Profile');
      await tapVisible(tester, find.text('App Settings'));
      await tapVisible(tester, find.text('Voice Assistant'));
      expect(find.byType(VoiceAssistantScreen), findsOneWidget);
    }

    /// Settings is a long list: scrolls [finder] into view first.
    Future<Finder> seen(WidgetTester tester, Finder finder) async {
      await tester.scrollUntilVisible(finder, 100, scrollable: find.byType(Scrollable).last);
      return finder;
    }

    Finder wakeSwitch() => find.descendant(of: find.widgetWithText(ListTile, 'Wake Word').first, matching: find.byType(Switch));

    /// "Hey Child" is said and Child Assist opens Chat to listen.
    Future<void> sayHeyChild(WidgetTester tester) async {
      expect(phone.sayWakePhrase(), isTrue, reason: 'the phone was listening');
      await frames(tester);
    }

    // -- Settings -----------------------------------------------------------------------------

    testWidgets('Settings > Voice Assistant switches Hey Child on after the microphone dialog', (tester) async {
      await startApp(tester, micGranted: false);
      await openVoiceAssistant(tester);
      expect(find.text('Wake Word is off.'), findsOneWidget);
      expect(await seen(tester, find.text(VoiceAssistantScreen.privacyText)), findsOneWidget);
      await tester.drag(find.byType(Scrollable).last, const Offset(0, 2000));
      await tester.pumpAndSettle();
      expect(find.text('“Hey Child” or “Hi Child”'), findsOneWidget);
      expect(phone.calls, isEmpty, reason: 'nothing runs until the user switches it on');

      await tester.tap(wakeSwitch());
      await frames(tester);

      expect(os.dialogsShown, [AppPermission.microphone]);
      expect(phone.calls, ['start u1']);
      expect(phone.tuning?.threshold, const WakeWordTuning().threshold);
      expect(phone.listening, isTrue);
      expect(find.text('Hey Child is listening for the wake phrase.'), findsOneWidget);
      expect(find.text('Allowed'), findsOneWidget);
      expect(backend.permissions['u1']?['MICROPHONE'], 'GRANTED');

      await tester.tap(wakeSwitch());
      await frames(tester);
      expect(phone.calls.last, 'stop');
      expect(phone.running, isFalse);
      expect(find.text('Wake Word is off.'), findsOneWidget);
    });

    testWidgets('microphone denied: Wake Word stays off and says why; the dialog is asked once per tap', (tester) async {
      await startApp(tester, micGranted: false);
      os.onRequest[AppPermission.microphone] = PermissionState.denied;
      await openVoiceAssistant(tester);
      await tester.tap(wakeSwitch());
      await frames(tester);

      expect(os.dialogsShown, [AppPermission.microphone]);
      expect(phone.calls, isEmpty);
      expect(wake().enabled, isFalse);
      expect(await seen(tester, find.text('Microphone permission is required for Hey Child.')), findsOneWidget);
      expect(find.text('Microphone permission is required.'), findsOneWidget);
      expect(tester.widget<Switch>(wakeSwitch()).value, isFalse);
    });

    testWidgets('microphone blocked: no dialog, the user is sent to the phone settings', (tester) async {
      await startApp(tester, micGranted: false);
      os.os[AppPermission.microphone] = PermissionState.permanentlyDenied;
      await openVoiceAssistant(tester);
      await tester.tap(wakeSwitch());
      await frames(tester);

      expect(os.dialogsShown, isEmpty);
      expect(phone.calls, isEmpty);
      expect(await seen(tester, find.text('Microphone permission is required for Hey Child. Allow it in your phone settings.')), findsOneWidget);
      await tapVisible(tester, find.widgetWithText(FilledButton, 'Open Settings'));
      expect(os.settingsOpened, 1);
    });

    // -- The question -------------------------------------------------------------------------

    testWidgets('"Hey Child, where did I go today?" sends only the question and reads the answer aloud', (tester) async {
      await startApp(tester);
      await switchOn(tester);
      tts.repliesEnabled = true;
      expect(find.byType(ChatScreen), findsNothing, reason: 'on the Dashboard');

      await sayHeyChild(tester);
      expect(find.byType(ChatScreen), findsOneWidget, reason: 'Chat opens for the question');
      expect(voice.calls, ['listen']);
      expect(find.text('Listening...'), findsOneWidget);
      expect(wake().state, WakeWordState.listeningForCommand);
      expect(phone.listening, isFalse, reason: 'the wake word released the microphone for the question');
      expect(phone.screenKeptOn, isTrue);

      voice.finish('Hey Child, where did I go today?');
      await frames(tester);

      expect(backend.chatRequests.single['message'], 'where did I go today?');
      expect(find.text('You said: where did I go today?'), findsOneWidget);
      expect(tts.spoken, ['You said: where did I go today?']);
      expect(wake().state, WakeWordState.speaking);
      expect(phone.suspended, containsAll(['speaking', 'interaction']));
      expect(phone.sayWakePhrase(), isFalse, reason: "Child Assist's own voice cannot wake it");

      tts.finishSpeaking();
      await tester.pump(const Duration(milliseconds: 800));
      expect(phone.listening, isTrue);
      expect(wake().state, WakeWordState.listeningForWakeWord);
      expect(phone.screenKeptOn, isFalse);
    });

    testWidgets('the answer goes to the signed-in account only, with its own session', (tester) async {
      await startApp(tester);
      await switchOn(tester);
      await sayHeyChild(tester);
      voice.finish('what time is it');
      await frames(tester);

      final mine = backend.chats['u1']!.single['messages'] as List;
      expect(mine.first['content'], 'what time is it');
      expect(backend.chats['u2'] ?? const [], isEmpty);
      expect(backend.chatRequests.single.containsKey('userId'), isFalse, reason: 'the server decides who is asking');
    });

    testWidgets('only "Hey Child" and then silence: nothing is sent, listening resumes', (tester) async {
      await startApp(tester);
      await switchOn(tester);
      await sayHeyChild(tester);
      voice.finish('hey child');
      await frames(tester);

      expect(backend.chatRequests, isEmpty);
      expect(find.text('Listening...'), findsNothing);
      expect(phone.listening, isTrue);
      expect(wake().state, WakeWordState.listeningForWakeWord);

      await sayHeyChild(tester);
      voice.silence();
      await frames(tester);
      expect(backend.chatRequests, isEmpty);
      expect(phone.listening, isTrue);
    });

    testWidgets('no answer after the wake phrase times out instead of listening forever', (tester) async {
      await startApp(tester);
      await switchOn(tester);
      await sayHeyChild(tester);
      expect(voice.isListening, isTrue);

      await tester.pump(const Duration(seconds: 16));
      await frames(tester);
      expect(voice.calls, ['listen', 'cancel']);
      expect(backend.chatRequests, isEmpty);
      expect(wake().state, WakeWordState.listeningForWakeWord);
      expect(phone.listening, isTrue);
    });

    testWidgets('the same wake phrase reported twice starts one question', (tester) async {
      await startApp(tester);
      await switchOn(tester);
      await sayHeyChild(tester);
      phone.repeatDetection();
      phone.repeatDetection();
      await frames(tester);

      expect(voice.calls, ['listen']);
      voice.finish('what time is it');
      await frames(tester);
      expect(backend.chatRequests, hasLength(1));
    });

    testWidgets('switched off: saying "Hey Child" does nothing', (tester) async {
      await startApp(tester);
      await switchOn(tester);
      await wake().disable();
      await frames(tester);

      expect(phone.calls.last, 'stop');
      expect(phone.sayWakePhrase(), isFalse);
      phone.repeatDetection(); // even a stray event
      await frames(tester);
      expect(voice.calls, isEmpty);
      expect(find.byType(ChatScreen), findsNothing);
    });

    testWidgets('tap-to-talk still works and closes the wake word microphone while listening', (tester) async {
      await startApp(tester);
      await switchOn(tester);
      await openTab(tester, 'Chat');
      await tester.tap(find.byTooltip('Voice input'));
      await frames(tester);

      expect(find.text('Listening...'), findsOneWidget);
      expect(phone.suspended, contains('tapToTalk'));
      expect(phone.listening, isFalse);

      voice.finish('Hey Child is a nice name');
      await frames(tester);
      expect(backend.chatRequests.single['message'], 'Hey Child is a nice name', reason: 'tap-to-talk sends what was said');
      expect(phone.listening, isTrue);
    });

    // -- Account and permission -----------------------------------------------------------------

    testWidgets('logout stops Hey Child; another account does not inherit it', (tester) async {
      await startApp(tester);
      await switchOn(tester);
      await logOut(tester);

      expect(phone.calls, contains('stop'));
      expect(phone.running, isFalse);
      expect(wake().state, WakeWordState.disabled);

      await logIn(tester, 'ravi@example.com');
      await frames(tester);
      expect(phone.calls.where((c) => c.startsWith('start')), ['start u1']);
      expect(wake().enabled, isFalse);
      expect(phone.sayWakePhrase(), isFalse);

      await logOut(tester);
      await logIn(tester, 'mansi@example.com');
      await frames(tester);
      expect(wake().enabled, isFalse, reason: 'logging out switched it off; it needs a fresh choice');
      expect(phone.running, isFalse);
    });

    testWidgets('microphone permission removed: Hey Child stops when the app is back', (tester) async {
      await startApp(tester);
      await switchOn(tester);
      os.os[AppPermission.microphone] = PermissionState.denied;
      await wake().recheck();
      await frames(tester);

      expect(phone.calls.last, 'stop');
      expect(wake().enabled, isFalse);
      expect(wake().issue, WakeWordIssue.permissionRequired);
      expect(wake().statusMessage, 'Microphone permission is required.');
    });

    testWidgets('the phone service reporting the permission gone also stops it', (tester) async {
      await startApp(tester);
      await switchOn(tester);
      os.os[AppPermission.microphone] = PermissionState.permanentlyDenied;
      phone.report(const NativeWakeStatus(issue: 'permission'));
      await frames(tester);

      expect(wake().enabled, isFalse);
      expect(wake().issue, WakeWordIssue.permissionBlocked);
      expect(phone.calls.last, 'stop');
    });

    testWidgets('"Turn off" in the notification switches it off in the app too', (tester) async {
      await startApp(tester);
      await switchOn(tester);
      phone.report(const NativeWakeStatus());
      await frames(tester);
      expect(wake().enabled, isFalse);
      expect(wake().state, WakeWordState.disabled);
    });

    // -- Failures, calls, the lock screen ---------------------------------------------------

    testWidgets('a microphone failure shows an error, never "listening"', (tester) async {
      await startApp(tester);
      await switchOn(tester);
      phone.report(const NativeWakeStatus(enabled: true, owner: 'u1', issue: 'microphone'));
      await frames(tester);

      expect(wake().state, WakeWordState.error);
      expect(wake().statusMessage, "The microphone isn't available, so Wake Word stopped.");
      expect(wake().isListening, isFalse);
    });

    testWidgets('Android refusing a background start shows paused, and it restarts from the app', (tester) async {
      await startApp(tester);
      phone.startResult = WakeWordStartResult.startBlocked;
      await wake().enable();
      await frames(tester);
      expect(wake().state, WakeWordState.paused);
      expect(wake().issue, WakeWordIssue.startBlocked);

      phone.startResult = WakeWordStartResult.started;
      await wake().recheck();
      await frames(tester);
      expect(wake().state, WakeWordState.listeningForWakeWord);
    });

    testWidgets('a call pauses listening and it resumes afterwards', (tester) async {
      await startApp(tester);
      await switchOn(tester);
      phone.call(true);
      await frames(tester);
      expect(wake().state, WakeWordState.paused);
      expect(wake().statusMessage, 'Paused during the call.');
      expect(phone.sayWakePhrase(), isFalse);

      phone.call(false);
      await frames(tester);
      expect(wake().state, WakeWordState.listeningForWakeWord);
    });

    testWidgets('locked phone: by default the user unlocks before Child Assist listens', (tester) async {
      await startApp(tester);
      await switchOn(tester);
      phone.lock = const DeviceLockState(locked: true, secure: true);
      phone.unlockSucceeds = false;
      await sayHeyChild(tester);

      expect(phone.calls, contains('requestUnlock'));
      expect(voice.calls, isEmpty, reason: 'not unlocked: nothing is heard or answered');
      expect(phone.showingOverLockScreen, isFalse);
      expect(phone.listening, isTrue);

      phone.unlockSucceeds = true;
      await sayHeyChild(tester);
      expect(voice.calls, ['listen']);
    });

    testWidgets('"Answer while locked": only Chat shows above the lock screen, then the lock returns', (tester) async {
      await startApp(tester);
      await switchOn(tester);
      await wake().setLockScreenAnswers(true);
      phone.lock = const DeviceLockState(locked: true, secure: true);
      await sayHeyChild(tester);

      expect(phone.showingOverLockScreen, isTrue);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byTooltip('History'), findsNothing);
      expect(find.text('Your phone is locked. Unlock it to use the rest of Child Assist.'), findsOneWidget);

      voice.finish('what time is it');
      await frames(tester);
      expect(backend.chatRequests.single['message'], 'what time is it');
      await tester.pump(const Duration(seconds: 16));
      await frames(tester);
      expect(phone.showingOverLockScreen, isFalse);
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    // -- Existing tools after the wake phrase ------------------------------------------------

    testWidgets('"Hey Child, show me today\'s photo" and "what color is the dress" use the real photo', (tester) async {
      final now = DateTime.now();
      final photo = PhotoItem(
        id: 'device-1',
        name: 'IMG_2001.jpg',
        width: 4000,
        height: 3000,
        createdAt: now.subtract(const Duration(minutes: 30)),
        modifiedAt: now.subtract(const Duration(minutes: 30)),
        mimeType: 'image/jpeg',
      );
      await startApp(tester, photos: [photo]);
      os.os[AppPermission.photos] = PermissionState.granted;
      await switchOn(tester);
      final start = DateTime(now.year, now.month, now.day);
      backend.chatResponder = (_) => FakeChatReply('Here is your photo from today.', toolEvents: [
            {
              'kind': 'photos',
              'status': 'device_lookup',
              'data': {
                'requestId': 'search1',
                'query': {
                  'startDate': start.toUtc().toIso8601String(),
                  'endDate': start.add(const Duration(days: 1)).toUtc().toIso8601String(),
                  'locationContext': false,
                  'latest': false,
                  'visualHint': null,
                },
                'visits': const [],
              },
            },
          ]);

      await sayHeyChild(tester);
      voice.finish("Hey Child, show me today's photo");
      await tester.pumpAndSettle();
      expect(backend.chatRequests.last['message'], "show me today's photo");
      final photoId = backend.photoStore.keys.single;

      backend.chatResponder = (_) => FakeChatReply('Let me look at the photo.', toolEvents: [
            {
              'kind': 'photo_analysis',
              'status': 'device_lookup',
              'data': {'requestId': 'analysis1', 'photoId': photoId},
            },
          ]);
      await sayHeyChild(tester);
      voice.finish('what color is the dress in that photo');
      await tester.pumpAndSettle();

      expect(backend.chatRequests.last['message'], 'what color is the dress in that photo');
      expect(backend.analysedImages, hasLength(1), reason: 'the actual photo was sent for image recognition');
      expect(find.text('Answered from this photo.'), findsOneWidget);
    });

    testWidgets('a wake phrase that opened the app before it was running is answered after sign-in', (tester) async {
      FlutterSecureStorage.setMockInitialValues({'wake_word_enabled_u1': 'true'});
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      backend = FakeBackend();
      os = FakePermissionService()..os[AppPermission.microphone] = PermissionState.granted;
      voice = FakeVoiceInput();
      tts = FakeTextToSpeech();
      phone = FakeWakeWordPlatform()
        ..native = const NativeWakeStatus(enabled: true, owner: 'u1', running: true, suspendedBy: ['interaction'])
        ..suspended.add('interaction')
        ..pendingActivation = true;
      services = backend.services(os, voiceInput: voice, textToSpeech: tts, wakeWordPlatform: phone);
      await services.authService.restoreSession();
      await tester.pumpWidget(MyApp(services: services));
      await tester.pumpAndSettle();
      await logIn(tester, 'mansi@example.com');
      await frames(tester);

      expect(find.byType(ChatScreen), findsOneWidget);
      expect(voice.calls, ['listen']);
      voice.finish('where did I go today');
      await frames(tester);
      expect(backend.chatRequests.single['message'], 'where did I go today');
      expect(phone.listening, isTrue);
    });
  });
}
