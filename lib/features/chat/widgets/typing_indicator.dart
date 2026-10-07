import 'package:flutter/material.dart';

import '../models/chat_message.dart';
import 'chat_message_bubble.dart';
import 'tool_status_card.dart';

/// "Child Assist is thinking..." with three bouncing dots, shown while a reply is on its way.
/// When the server reports which tool is running, that step is shown instead.
class TypingIndicator extends StatefulWidget {
  const TypingIndicator({super.key, this.activeTool});

  final ChatToolKind? activeTool;

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tool = widget.activeTool;
    return Semantics(
      liveRegion: true,
      label: tool == null ? 'Child Assist is thinking' : toolProgressText(tool),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const AssistantAvatar(),
            const SizedBox(width: 8),
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: assistantBubbleColor(theme),
                  borderRadius: assistantBubbleRadius,
                ),
                child: ExcludeSemantics(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < 3; i++) _Dot(controller: _controller, index: i),
                      const SizedBox(width: 10),
                      Flexible(
                        child: tool == null
                            ? Text('Child Assist is thinking...', style: theme.textTheme.bodySmall)
                            : ToolStatusCard(kind: tool, inProgress: true),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.controller, required this.index});

  final AnimationController controller;
  final int index;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        // Each dot rises in turn, a third of a cycle apart.
        final t = (controller.value - index / 3) % 1.0;
        final lift = t < 0.5 ? Curves.easeOut.transform(t * 2) : Curves.easeIn.transform((1 - t) * 2);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Transform.translate(
            offset: Offset(0, -4 * lift),
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.45 + 0.55 * lift),
                shape: BoxShape.circle,
              ),
            ),
          ),
        );
      },
    );
  }
}
