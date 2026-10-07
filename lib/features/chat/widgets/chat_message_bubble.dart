import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';
import '../models/chat_message.dart';
import 'confirmation_card.dart';
import 'tool_result_cards.dart';
import 'tool_status_card.dart';

const assistantBubbleRadius = BorderRadius.only(
  topLeft: Radius.circular(18),
  topRight: Radius.circular(18),
  bottomRight: Radius.circular(18),
  bottomLeft: Radius.circular(6),
);

const _userBubbleRadius = BorderRadius.only(
  topLeft: Radius.circular(18),
  topRight: Radius.circular(18),
  bottomLeft: Radius.circular(18),
  bottomRight: Radius.circular(6),
);

Color assistantBubbleColor(ThemeData theme) =>
    theme.brightness == Brightness.dark ? AppColors.darkSurfaceHigh : theme.colorScheme.surface;

/// "10:42 AM" for today, otherwise "Oct 5, 10:42 AM", in the device's locale.
String chatTimeLabel(BuildContext context, DateTime time) {
  final l10n = MaterialLocalizations.of(context);
  final local = time.toLocal();
  final clock = l10n.formatTimeOfDay(TimeOfDay.fromDateTime(local));
  final now = DateTime.now();
  final today = local.year == now.year && local.month == now.month && local.day == now.day;
  return today ? clock : '${l10n.formatShortMonthDay(local)}, $clock';
}

/// The Child Assist avatar shown next to its messages.
class AssistantAvatar extends StatelessWidget {
  const AssistantAvatar({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Child Assist',
      child: IconBadge(icon: Icons.smart_toy_rounded, gradient: AppGradients.brand, size: size, iconSize: size * 0.55),
    );
  }
}

/// One message: the user's on the right, Child Assist's on the left with its avatar, followed by
/// what it checked and any results, permission notes or confirmations.
class ChatMessageBubble extends StatelessWidget {
  const ChatMessageBubble({
    super.key,
    required this.message,
    required this.results,
    this.onSpeak,
    this.speaking = false,
  });

  final ChatMessage message;
  final ChatResultContext results;

  /// Reads the reply aloud, or stops it while [speaking]. Null hides the speaker button.
  final VoidCallback? onSpeak;
  final bool speaking;

  @override
  Widget build(BuildContext context) {
    return message.isUser ? _buildUser(context) : _buildAssistant(context);
  }

  Widget _buildUser(BuildContext context) {
    final theme = Theme.of(context);
    final failed = message.state == ChatMessageState.failed;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: _maxBubbleWidth(context)),
              child: Opacity(
                opacity: message.state == ChatMessageState.sending ? 0.75 : 1,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    gradient: failed ? null : AppGradients.brand,
                    color: failed ? AppColors.danger.withValues(alpha: 0.12) : null,
                    borderRadius: _userBubbleRadius,
                  ),
                  child: SelectableText(
                    message.content,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: failed ? theme.colorScheme.onSurface : Colors.white,
                      height: 1.35,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            failed ? 'Not sent' : chatTimeLabel(context, message.createdAt),
            style: theme.textTheme.labelSmall?.copyWith(
              color: failed ? AppColors.danger : theme.textTheme.bodySmall?.color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAssistant(BuildContext context) {
    final theme = Theme.of(context);
    final cards = <Widget>[
      for (final event in message.toolEvents) ...[
        if (event.status != ChatToolStatus.confirmationRequired) ToolStatusCard(kind: event.kind),
        ?toolResultCard(event, results),
      ],
      for (final action in message.pendingActions)
        ConfirmationCard(
          action: action,
          onConfirm: () => results.onConfirmAction(action.id),
          onCancel: () => results.onCancelAction(action.id),
        ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AssistantAvatar(),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: _maxBubbleWidth(context)),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: assistantBubbleColor(theme),
                      borderRadius: assistantBubbleRadius,
                      border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
                    ),
                    child: SelectableText(
                      message.content,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface, height: 1.4),
                    ),
                  ),
                ),
                for (final card in cards) Padding(padding: const EdgeInsets.only(top: 8), child: card),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(chatTimeLabel(context, message.createdAt), style: theme.textTheme.labelSmall),
                    if (onSpeak != null && message.content.trim().isNotEmpty) ...[
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: speaking ? 'Stop speaking' : 'Read aloud',
                        onPressed: onSpeak,
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        color: speaking ? theme.colorScheme.primary : theme.textTheme.labelSmall?.color,
                        icon: Icon(speaking ? Icons.stop_circle_outlined : Icons.volume_up_rounded),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static double _maxBubbleWidth(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return (width * 0.8).clamp(200.0, 620.0);
  }
}
