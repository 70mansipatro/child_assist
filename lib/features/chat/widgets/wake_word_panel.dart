import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';
import '../../voice_assistant/models/wake_word_state.dart';
import 'chat_message_bubble.dart' show AssistantAvatar;

/// Shown in Chat during a "Hey Child" question: the assistant and what it is doing, from the wake
/// phrase to the spoken answer. It only reflects the real state; it never starts anything.
class WakeWordPanel extends StatelessWidget {
  const WakeWordPanel({super.key, required this.state, this.heard = ''});

  final WakeWordState state;

  /// The words recognised so far while listening to the question.
  final String heard;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (title, subtitle, icon) = switch (state) {
      WakeWordState.wakeWordDetected => ('Wake word detected!', 'Now listening for your question...', Icons.hearing_rounded),
      WakeWordState.listeningForCommand => ('Listening for your question...', 'Speak now', Icons.mic_rounded),
      WakeWordState.processing => ('Processing your question...', 'Please wait', Icons.settings_rounded),
      _ => ('Here is your answer...', 'Speaking', Icons.graphic_eq_rounded),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Semantics(
        liveRegion: true,
        label: '$title $subtitle',
        child: AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  const AssistantAvatar(size: 52),
                  Positioned(
                    right: -6,
                    bottom: -6,
                    child: IconBadge(icon: icon, gradient: AppGradients.microphone, size: 26, iconSize: 15),
                  ),
                ],
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      state == WakeWordState.listeningForCommand && heard.isNotEmpty ? heard : subtitle,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (state == WakeWordState.processing)
                const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
            ],
          ),
        ),
      ),
    );
  }
}
