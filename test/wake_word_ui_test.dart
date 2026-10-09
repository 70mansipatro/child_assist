import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:child_assist/app_services.dart';
import 'package:child_assist/core/permissions/permission_service.dart';
import 'package:child_assist/features/chat/services/voice_chat_controller.dart';
import 'package:child_assist/features/chat/services/voice_input.dart';
import 'package:child_assist/features/voice_assistant/data/wake_word_platform.dart';
import 'package:child_assist/features/voice_assistant/models/wake_word_ui_state.dart';
import 'package:child_assist/features/voice_assistant/services/wake_word_service.dart';
import 'package:child_assist/features/voice_assistant/widgets/siri_waveform.dart';
import 'package:child_assist/features/voice_assistant/widgets/wake_word_overlay.dart';
import 'package:child_assist/main.dart';

import 'support/app_driver.dart';
import 'support/fakes.dart';

void main() {
  group('wake word UI phase', () {
    test('every wake word state maps to what the waveform shows', () {
      expect(WakeWordUiPhase.forState(WakeWordState.listeningForWakeWord), WakeWordUiPhase.idle);
      expect(WakeWordUiPhase.forState(WakeWordState.wakeWordDetected), WakeWordUiPhase.wakeWordDetected);
      expect(WakeWordUiPhase.forState(WakeWordState.listeningForCommand), WakeWordUiPhase.listening);
      expect(WakeWordUiPhase.forState(WakeWordState.processing), WakeWordUiPhase.processing);
      expect(WakeWordUiPhase.forState(WakeWordState.speaking), WakeWordUiPhase.speaking);
      expect(WakeWordUiPhase.forState(WakeWordState.error), WakeWordUiPhase.error);
      for (final hidden in [WakeWordState.disabled, WakeWordState.starting, WakeWordState.paused]) {
        expect(WakeWordUiPhase.forState(hidden), isNull, reason: '$hidden shows nothing');
      }
    });

    test('labels', () {
      expect(WakeWordUiPhase.idle.label, 'Say “Hey Child”');
      expect(WakeWordUiPhase.listening.label, "I'm listening…");
      expect(WakeWordUiPhase.processing.label, 'Thinking…');
    });

    test('the wave follows real loudness only while listening; otherwise a fixed resting height', () {
      expect(SiriWaveform.targetAmplitude(WakeWordUiPhase.listening, 0), closeTo(0.1, 1e-9));
      expect(SiriWaveform.targetAmplitude(WakeWordUiPhase.listening, 1), closeTo(1.0, 1e-9));
      expect(SiriWaveform.targetAmplitude(WakeWordUiPhase.listening, null),
          SiriWaveform.restingAmplitude(WakeWordUiPhase.listening));
      expect(SiriWaveform.targetAmplitude(WakeWordUiPhase.speaking, 1), SiriWaveform.restingAmplitude(WakeWordUiPhase.speaking),
          reason: 'speech output has no amplitude data; the level is never borrowed for it');
      expect(SiriWaveform.restingAmplitude(WakeWordUiPhase.wakeWordDetected),
          greaterThan(SiriWaveform.restingAmplitude(WakeWordUiPhase.idle)), reason: 'it expands when the phrase is heard');
    });

    test("Android's recogniser levels are scaled to 0..1", () {
      expect(SpeechToTextVoiceInput.normalizeSoundLevel(-2), 0);
      expect(SpeechToTextVoiceInput.normalizeSoundLevel(10), 1);
      expect(SpeechToTextVoiceInput.normalizeSoundLevel(4), closeTo(0.5, 1e-9));
      expect(SpeechToTextVoiceInput.normalizeSoundLevel(40), 1);
    });
  });

  group('notch anchor', () {
    MediaQueryData media({List<ui.DisplayFeature> features = const [], double top = 32, Size size = const Size(400, 880)}) =>
        MediaQueryData(size: size, viewPadding: EdgeInsets.only(top: top), displayFeatures: features);

    ui.DisplayFeature cutout(Rect bounds) =>
        ui.DisplayFeature(bounds: bounds, type: ui.DisplayFeatureType.cutout, state: ui.DisplayFeatureState.unknown);

    test('centred on a punch-hole camera', () {
      final anchor = NotchAnchor.of(media(features: [cutout(const Rect.fromLTWH(188, 6, 24, 24))]));
      expect(anchor.fromCutout, isTrue);
      expect(anchor.center, const Offset(200, 18));
      expect(anchor.cutout, const Size(24, 24));
    });

    test('an off-centre camera is followed', () {
      final anchor = NotchAnchor.of(media(features: [cutout(const Rect.fromLTWH(20, 4, 26, 26))]));
      expect(anchor.center.dx, 33);
    });

    test('no cutout: the middle of the status bar', () {
      final anchor = NotchAnchor.of(media());
      expect(anchor.fromCutout, isFalse);
      expect(anchor.center, const Offset(200, 16));
    });

    test('a side cutout (landscape) and hinges are ignored', () {
      final anchor = NotchAnchor.of(media(
        size: const Size(880, 400),
        top: 0,
        features: [
          cutout(const Rect.fromLTWH(0, 180, 30, 40)),
          const ui.DisplayFeature(
              bounds: Rect.fromLTWH(430, 0, 20, 400), type: ui.DisplayFeatureType.hinge, state: ui.DisplayFeatureState.postureFlat),
        ],
      ));
      expect(anchor.fromCutout, isFalse);
      expect(anchor.center, const Offset(440, 18));
    });
  });

  group('the waveform follows the real wake word', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    late FakeBackend backend;
    late FakeVoiceInput voice;
    late FakeTextToSpeech tts;
    late FakeWakeWordPlatform phone;
    late AppServices services;

    WakeWordService wake() => services.wakeWordService;

    Future<void> startApp(WidgetTester tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      backend = FakeBackend();
      final os = FakePermissionService()
        ..os[AppPermission.microphone] = PermissionState.granted
        ..os[AppPermission.notifications] = PermissionState.granted;
      voice = FakeVoiceInput();
      tts = FakeTextToSpeech();
      phone = FakeWakeWordPlatform();
      services = backend.services(os, voiceInput: voice, textToSpeech: tts, wakeWordPlatform: phone);
      await services.authService.restoreSession();
      await tester.pumpWidget(MyApp(services: services));
      await tester.pumpAndSettle();
      await logIn(tester, 'mansi@example.com');
    }

    Future<void> frames(WidgetTester tester, [int count = 5]) async {
      for (var i = 0; i < count; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Finder island() => find.descendant(of: find.byType(WakeWordNotchOverlay), matching: find.byType(SiriWaveform));
    Finder idleHint() => find.descendant(of: find.byType(WakeWordIdleHint), matching: find.byType(SiriWaveform));

    testWidgets('off: no waveform anywhere', (tester) async {
      await startApp(tester);
      await openTab(tester, 'Chat');
      expect(island(), findsNothing);
      expect(idleHint(), findsNothing);
    });

    testWidgets('idle → detected → listening (real levels) → thinking → answering → idle', (tester) async {
      await startApp(tester);
      await wake().enable();
      await frames(tester);
      tts.repliesEnabled = true;
      await openTab(tester, 'Chat');

      // Idle: only the calm "Say Hey Child" pill in Chat, nothing at the camera.
      expect(find.text('Say “Hey Child”'), findsOneWidget);
      expect(idleHint(), findsOneWidget);
      expect(island(), findsNothing);

      // The question: the chat takes it at once, so detected moves straight on to listening.
      voice.readyOnListen = false;
      phone.sayWakePhrase();
      await tester.pump();
      await tester.pump();
      expect(wake().state, anyOf(WakeWordState.wakeWordDetected, WakeWordState.listeningForCommand));
      expect(island(), findsOneWidget, reason: 'the waveform expands at the camera');
      await frames(tester);
      expect(wake().state, WakeWordState.listeningForCommand);
      expect(find.text("I'm listening…"), findsOneWidget);
      expect(idleHint(), findsNothing, reason: 'not waiting for the phrase any more');
      expect(phone.cues, 0, reason: 'the existing beep still waits for the recogniser');

      // Real microphone levels from the recogniser drive the wave; none before they arrive.
      expect(wake().questionLevel.value, isNull);
      voice.soundLevel(0.7);
      await tester.pump();
      expect(phone.cues, 1);
      expect(wake().questionLevel.value, 0.7);

      final answer = backend.chatPending = Completer<void>();
      voice.finish('what time is it');
      await frames(tester);
      expect(find.text('Thinking…'), findsOneWidget);
      expect(wake().questionLevel.value, isNull, reason: 'the level is only known while listening');

      answer.complete();
      await frames(tester);
      expect(find.text('Answering…'), findsOneWidget);

      tts.finishSpeaking();
      await tester.pump(const Duration(milliseconds: 800));
      await frames(tester);
      expect(island(), findsNothing);
      expect(find.text('Say “Hey Child”'), findsOneWidget, reason: 'back to listening for the phrase');
    });

    testWidgets('a recogniser error is explained, then listening for the phrase resumes', (tester) async {
      await startApp(tester);
      await wake().enable();
      await frames(tester);
      await openTab(tester, 'Chat');

      phone.sayWakePhrase();
      await frames(tester);
      voice.fail(VoiceErrorKind.network);
      await frames(tester);

      expect(wake().state, WakeWordState.listeningForWakeWord);
      expect(find.text('Oops!'), findsOneWidget);
      expect(find.descendant(of: find.byType(WakeWordNotchOverlay), matching: find.text(VoiceErrorKind.network.message)),
          findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      await frames(tester);
      expect(find.text('Oops!'), findsNothing);
      expect(island(), findsNothing);
      expect(phone.listening, isTrue);
    });

    testWidgets('no answer (offline): a friendly message, and a new question replaces it', (tester) async {
      await startApp(tester);
      await wake().enable();
      await frames(tester);
      await openTab(tester, 'Chat');
      backend.offline = true;

      phone.sayWakePhrase();
      await frames(tester);
      voice.finish('what is my name');
      await frames(tester);
      expect(find.text(VoiceChatController.noAnswerMessage), findsOneWidget);

      backend.offline = false;
      phone.sayWakePhrase();
      await frames(tester);
      expect(find.text('Oops!'), findsNothing);
      expect(find.text("I'm listening…"), findsOneWidget);
      voice.finish('what is my name');
      await frames(tester);
    });

    testWidgets('the service failing shows an error briefly; switching off hides everything', (tester) async {
      await startApp(tester);
      await wake().enable();
      await frames(tester);

      phone.report(const NativeWakeStatus(issue: 'microphone'));
      await frames(tester);
      expect(wake().state, WakeWordState.error);
      expect(find.text('Oops!'), findsOneWidget);
      expect(find.text("The microphone isn't available, so Wake Word stopped."), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      await frames(tester);
      expect(island(), findsNothing, reason: 'Settings keeps explaining a lasting problem');

      await wake().disable();
      await frames(tester);
      expect(island(), findsNothing);
      expect(idleHint(), findsNothing);
    });

    testWidgets('Home screen: the waveform shows outside the app with the real state, and hides in the app',
        (tester) async {
      await startApp(tester);
      await wake().enable();
      await frames(tester);
      tts.repliesEnabled = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await frames(tester);
      expect(phone.systemOverlay, isNull, reason: 'nothing outside the app while only waiting for the phrase');

      phone.sayWakePhrase();
      await frames(tester);
      expect(wake().state, WakeWordState.listeningForCommand);
      expect(phone.systemOverlay, "listening I'm listening…");

      final answer = backend.chatPending = Completer<void>();
      voice.finish('what time is it');
      await frames(tester);
      expect(phone.systemOverlay, 'processing Thinking…');
      answer.complete();
      await frames(tester);
      expect(phone.systemOverlay, 'speaking Answering…');

      tts.finishSpeaking();
      await tester.pump(const Duration(milliseconds: 800));
      await frames(tester);
      expect(phone.systemOverlay, isNull, reason: 'back to waiting for the phrase');

      // A question in progress when the app comes back: drawn inside the app, not twice.
      phone.sayWakePhrase();
      await frames(tester);
      expect(phone.systemOverlay, isNotNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await frames(tester);
      expect(phone.systemOverlay, isNull);
      expect(island(), findsOneWidget);
      voice.silence();
      await frames(tester);
    });

    testWidgets('without "Display over other apps" nothing is drawn outside the app', (tester) async {
      await startApp(tester);
      phone.backgroundOpenAllowed = false;
      await wake().enable();
      await frames(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      phone.sayWakePhrase();
      await frames(tester);
      expect(wake().state, WakeWordState.listeningForCommand, reason: 'the question still works');
      expect(phone.systemOverlay, isNull);
      voice.silence();
      await frames(tester);
    });

    testWidgets('paused for a call: nothing claims to listen', (tester) async {
      await startApp(tester);
      await wake().enable();
      await frames(tester);
      await openTab(tester, 'Chat');
      expect(idleHint(), findsOneWidget);

      phone.call(true);
      await frames(tester);
      expect(wake().state, WakeWordState.paused);
      expect(idleHint(), findsNothing);
      expect(island(), findsNothing);

      phone.call(false);
      await frames(tester);
      expect(idleHint(), findsOneWidget);
    });
  });
}
