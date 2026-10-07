import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';

/// Where Child Assist's notifications will appear. The app does not send notifications yet,
/// so this shows an honest empty state rather than pretending anything is delivered.
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key, this.onOpenPermissions});

  /// Opens Permissions, where the notification permission can be turned on or off.
  final VoidCallback? onOpenPermissions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(flexibleSpace: const AppBarGradient(), title: const Text('Notifications')),
      body: SafeArea(
        child: StateMessage(
          icon: Icons.notifications_none_rounded,
          gradient: AppGradients.notifications,
          title: 'No notifications yet',
          body: "Child Assist doesn't send notifications yet. When it does, they'll show up here.",
          action: onOpenPermissions == null
              ? null
              : OutlinedButton.icon(
                  onPressed: onOpenPermissions,
                  icon: const Icon(Icons.shield_outlined),
                  label: const Text('Notification permission'),
                ),
        ),
      ),
    );
  }
}
