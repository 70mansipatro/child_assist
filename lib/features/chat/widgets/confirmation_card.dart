import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';
import '../models/chat_message.dart';

/// Asks before anything leaves the app ("Send your location details to Mansi?"). The summary
/// comes from the server, not the AI. Nothing is sent unless the user taps Confirm.
class ConfirmationCard extends StatelessWidget {
  const ConfirmationCard({super.key, required this.action, required this.onConfirm, required this.onCancel});

  final PendingAction action;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = action.state == PendingActionState.confirming || action.state == PendingActionState.cancelling;
    final (tone, icon) = switch (action.state) {
      PendingActionState.done => (BannerTone.success, Icons.check_circle_outline_rounded),
      PendingActionState.failed => (BannerTone.danger, Icons.error_outline_rounded),
      PendingActionState.cancelled => (BannerTone.info, Icons.block_rounded),
      _ => (BannerTone.warning, Icons.outgoing_mail),
    };

    return InfoBanner(
      tone: tone,
      icon: icon,
      title: action.summary,
      message: Text(switch (action.state) {
        PendingActionState.awaiting => 'Nothing is sent until you confirm.',
        PendingActionState.confirming => 'Sending...',
        PendingActionState.cancelling => 'Cancelling...',
        _ => action.resultMessage ?? '',
      }),
      actions: action.isOpen || busy
          ? [
              OutlinedButton(onPressed: busy ? null : onCancel, child: const Text('Cancel')),
              FilledButton(
                onPressed: busy ? null : onConfirm,
                child: action.state == PendingActionState.confirming
                    ? ButtonSpinner(size: 16, color: theme.colorScheme.onPrimary)
                    : const Text('Confirm'),
              ),
            ]
          : const [],
    );
  }
}
