import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/permissions/permission_service.dart';
import '../../../core/widgets/widgets.dart';
import '../../chat/services/text_to_speech_service.dart';
import '../services/wake_phrase.dart';
import '../services/wake_word_service.dart';

/// Settings > Voice Assistant: the "Hey Child" wake word, voice replies, and what they need.
/// Everything shown comes from the phone (permission, whether it is really listening); nothing
/// says "listening" unless the phone reports it.
class VoiceAssistantScreen extends StatefulWidget {
  const VoiceAssistantScreen({
    super.key,
    required this.wakeWordService,
    required this.textToSpeech,
    required this.permissionService,
  });

  final WakeWordService wakeWordService;
  final TextToSpeechService textToSpeech;
  final PermissionService permissionService;

  static const privacyText =
      'Wake Word detection runs on your device. Child Assist does not send your continuous microphone '
      'audio to the server. Audio is processed for your command only after the wake phrase is detected.';

  @override
  State<VoiceAssistantScreen> createState() => _VoiceAssistantScreenState();
}

class _VoiceAssistantScreenState extends State<VoiceAssistantScreen> {
  PermissionState? _microphone;
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(onResume: _refresh);

  WakeWordService get _wake => widget.wakeWordService;

  @override
  void initState() {
    super.initState();
    _lifecycle;
    _refresh();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// Back from the phone's Settings: show the permission as it is now. Status only, no dialog.
  Future<void> _refresh() async {
    final state = await widget.permissionService.microphoneStatus();
    if (mounted) setState(() => _microphone = state);
  }

  Future<void> _toggle(bool on) async {
    if (on) {
      await _wake.enable();
    } else {
      await _wake.disable();
    }
    await _refresh();
  }

  Future<void> _openSettings() async {
    final opened = await _wake.openAppSettings();
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Open your phone settings to allow the microphone for Child Assist.')),
      );
    }
  }

  static String _microphoneLabel(PermissionState? state) => switch (state) {
        null => 'Checking...',
        PermissionState.granted || PermissionState.limited => 'Allowed',
        PermissionState.permanentlyDenied || PermissionState.restricted => 'Blocked in phone settings',
        PermissionState.unavailable => 'Not available',
        PermissionState.denied => 'Not allowed',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final divider = Divider(height: 1, indent: 72, endIndent: 16, color: theme.colorScheme.outlineVariant);
    return Scaffold(
      appBar: AppBar(flexibleSpace: const AppBarGradient(), title: const Text('Voice Assistant')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListenableBuilder(
              listenable: Listenable.merge([_wake, widget.textToSpeech]),
              builder: (context, _) => ListView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
                children: [
                  const SectionTitle('Wake Word'),
                  const SizedBox(height: 10),
                  FadeSlideIn(
                    child: AppCard(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        children: [
                          MenuTile(
                            icon: Icons.record_voice_over_rounded,
                            gradient: AppGradients.microphone,
                            title: 'Wake Word',
                            subtitle: _wake.isSupported
                                ? 'Talk to Child Assist hands-free'
                                : 'Not available on this device',
                            onTap: _wake.isSupported && !_wake.busy ? () => _toggle(!_wake.enabled) : null,
                            trailing: Switch(
                              value: _wake.enabled,
                              onChanged: _wake.isSupported && !_wake.busy ? _toggle : null,
                            ),
                          ),
                          divider,
                          MenuTile(
                            icon: Icons.campaign_rounded,
                            gradient: AppGradients.brand,
                            title: 'Wake phrase',
                            subtitle: wakePhrases.map((p) => '“$p”').join(' or '),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(72, 0, 16, 12),
                            child: Wrap(
                              spacing: 8,
                              children: [
                                for (final phrase in wakePhrases)
                                  Chip(avatar: const Icon(Icons.mic_none_rounded, size: 18), label: Text(phrase)),
                              ],
                            ),
                          ),
                          divider,
                          MenuTile(
                            icon: Icons.mic_rounded,
                            gradient: AppGradients.location,
                            title: 'Microphone',
                            subtitle: _microphoneLabel(_microphone),
                            onTap: _microphone == PermissionState.permanentlyDenied ? _openSettings : null,
                          ),
                          divider,
                          MenuTile(
                            icon: Icons.volume_up_rounded,
                            gradient: AppGradients.profile,
                            title: 'Voice responses',
                            subtitle: widget.textToSpeech.isAvailable
                                ? 'Read answers aloud'
                                : 'Not available on this device',
                            onTap: widget.textToSpeech.isAvailable
                                ? () => widget.textToSpeech.repliesEnabled = !widget.textToSpeech.repliesEnabled
                                : null,
                            trailing: Switch(
                              value: widget.textToSpeech.isAvailable && widget.textToSpeech.repliesEnabled,
                              onChanged: widget.textToSpeech.isAvailable
                                  ? (on) => widget.textToSpeech.repliesEnabled = on
                                  : null,
                            ),
                          ),
                          divider,
                          MenuTile(
                            icon: Icons.lock_open_rounded,
                            gradient: AppGradients.notifications,
                            title: 'Answer while locked',
                            subtitle: _wake.lockScreenAnswers
                                ? 'Answers show on the lock screen. Anyone near your phone can see and hear them.'
                                : 'Unlock your phone first (PIN or fingerprint) before Child Assist answers.',
                            onTap: () => _wake.setLockScreenAnswers(!_wake.lockScreenAnswers),
                            trailing: Switch(value: _wake.lockScreenAnswers, onChanged: _wake.setLockScreenAnswers),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  FadeSlideIn(index: 1, child: _status(context)),
                  ..._problems(),
                  const SizedBox(height: 22),
                  const SectionTitle('Privacy'),
                  const SizedBox(height: 10),
                  FadeSlideIn(
                    index: 2,
                    child: const InfoBanner(
                      icon: Icons.privacy_tip_rounded,
                      message: Text(VoiceAssistantScreen.privacyText),
                    ),
                  ),
                  const SizedBox(height: 22),
                  const SectionTitle('When it works'),
                  const SizedBox(height: 10),
                  FadeSlideIn(
                    index: 3,
                    child: const InfoBanner(
                      icon: Icons.battery_alert_rounded,
                      message: Text(
                        'Hey Child works while Child Assist is open, in the background, and with the screen '
                        'off or locked, as long as Android keeps it running (you will see its notification). '
                        'It stops if you force-stop Child Assist or swipe it away on some phones, and does not '
                        'work when the phone is off. After restarting your phone, open Child Assist once to '
                        'turn it back on. Some phones close background apps to save battery: allow Child '
                        'Assist to run in the background in your battery settings. Listening uses some extra '
                        'battery.',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _status(BuildContext context) {
    final listening = _wake.isListening;
    return Semantics(
      liveRegion: true,
      child: InfoBanner(
        tone: switch (_wake.state) {
          WakeWordState.error => BannerTone.danger,
          WakeWordState.paused => BannerTone.warning,
          WakeWordState.disabled when _wake.issue != null => BannerTone.warning,
          _ when listening => BannerTone.success,
          _ => BannerTone.info,
        },
        icon: listening ? Icons.hearing_rounded : Icons.info_outline_rounded,
        title: 'Status',
        message: Text(_wake.busy && _wake.state == WakeWordState.disabled ? 'One moment...' : _wake.statusMessage),
        actions: [
          if (_wake.state == WakeWordState.error && _wake.issue != WakeWordIssue.unsupported)
            FilledButton(onPressed: _wake.enable, child: const Text('Try again')),
        ],
      ),
    );
  }

  /// What stops it from working fully, each with the way to fix it.
  List<Widget> _problems() {
    final issue = _wake.issue;
    final banners = <Widget>[
      if (issue == WakeWordIssue.permissionRequired || issue == WakeWordIssue.permissionBlocked)
        InfoBanner(
          tone: BannerTone.warning,
          icon: Icons.mic_off_rounded,
          message: Text(
            issue == WakeWordIssue.permissionBlocked
                ? 'Microphone permission is required for Hey Child. Allow it in your phone settings.'
                : 'Microphone permission is required for Hey Child.',
          ),
          actions: [
            if (issue == WakeWordIssue.permissionBlocked)
              FilledButton(onPressed: _openSettings, child: const Text('Open Settings')),
          ],
        ),
      if (_wake.enabled && _wake.notificationsBlocked)
        InfoBanner(
          tone: BannerTone.warning,
          icon: Icons.notifications_off_rounded,
          message: const Text(
            'Notifications are off for Child Assist, so Hey Child cannot open it while the screen is off or '
            'locked, and its notification is hidden.',
          ),
          actions: [FilledButton(onPressed: _openSettings, child: const Text('Open Settings'))],
        ),
      if (_wake.enabled && !_wake.notificationsBlocked && _wake.fullScreenBlocked)
        InfoBanner(
          tone: BannerTone.warning,
          icon: Icons.screen_lock_portrait_rounded,
          message: const Text(
            'Allow full-screen notifications for Child Assist so Hey Child can open it while the screen is '
            'off or locked.',
          ),
          actions: [
            FilledButton(onPressed: () => unawaited(_wake.openFullScreenSettings()), child: const Text('Allow')),
          ],
        ),
      if (_wake.enabled && _wake.backgroundOpenBlocked)
        InfoBanner(
          icon: Icons.open_in_new_rounded,
          message: const Text(
            'Optional: allow "Display over other apps" so Hey Child can open Child Assist by itself while you '
            'use another app. Without it, tap the notification that appears.',
          ),
          actions: [
            FilledButton(onPressed: () => unawaited(_wake.openBackgroundOpenSettings()), child: const Text('Allow')),
          ],
        ),
    ];
    return [
      for (final banner in banners) ...[const SizedBox(height: 10), banner],
    ];
  }
}
