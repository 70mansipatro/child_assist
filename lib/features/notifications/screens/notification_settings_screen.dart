import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/notifications/notification_service.dart';
import '../../../core/permissions/permission_service.dart';
import '../../../core/widgets/widgets.dart';
import '../models/app_notification.dart';

/// Which kinds of notifications the account receives. Saved to the account (not the phone), so
/// the choice follows the user. Security alerts are always on.
class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({
    super.key,
    required this.notificationService,
    required this.permissionService,
    this.onOpenPermissions,
  });

  final NotificationService notificationService;
  final PermissionService permissionService;
  final VoidCallback? onOpenPermissions;

  @override
  State<NotificationSettingsScreen> createState() => _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState extends State<NotificationSettingsScreen> {
  NotificationPreferences? _prefs;
  String? _error;
  final Set<NotificationCategory> _saving = {};
  bool _osBlocked = false;

  @override
  void initState() {
    super.initState();
    _load();
    widget.permissionService.notificationStatus().then((state) {
      if (mounted) setState(() => _osBlocked = !state.isUsable && state != PermissionState.unavailable);
    });
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final prefs = await widget.notificationService.loadPreferences();
      if (mounted) setState(() => _prefs = prefs);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _set(NotificationCategory category, bool value) async {
    final before = _prefs;
    if (before == null || category.mandatory) return;
    setState(() {
      _prefs = before.copyWith(category, value);
      _saving.add(category);
    });
    try {
      final saved = await widget.notificationService.setPreference(category, value);
      if (mounted) setState(() => _prefs = saved);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _prefs = before);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _saving.remove(category));
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = _prefs;
    return Scaffold(
      appBar: AppBar(flexibleSpace: const AppBarGradient(), title: const Text('Notification settings')),
      body: SafeArea(
        child: prefs == null
            ? (_error == null
                  ? const Center(child: CircularProgressIndicator())
                  : StateMessage(
                      icon: Icons.cloud_off_rounded,
                      gradient: AppGradients.danger,
                      title: "Couldn't load your settings",
                      body: _error,
                      action: GradientButton(onPressed: _load, label: const Text('Retry')),
                    ))
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                children: [
                  if (_osBlocked) ...[
                    InfoBanner(
                      tone: BannerTone.warning,
                      icon: Icons.notifications_off_rounded,
                      title: 'Notifications are off on this phone',
                      message: const Text('Your choices are saved, but your phone will not alert you until you allow notifications.'),
                      actions: [
                        if (widget.onOpenPermissions != null)
                          TextButton(onPressed: widget.onOpenPermissions, child: const Text('Turn on')),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],
                  AppCard(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      children: [
                        for (final (i, c) in NotificationCategory.values.indexed) ...[
                          if (i > 0) Divider(indent: 72, endIndent: 16, color: Theme.of(context).colorScheme.outlineVariant),
                          MenuTile(
                            key: ValueKey('pref-${c.wireName}'),
                            icon: c.icon,
                            gradient: c.gradient,
                            title: c.label,
                            subtitle: c.description,
                            trailing: Switch(
                              value: prefs.isEnabled(c),
                              onChanged: c.mandatory || _saving.contains(c) ? null : (v) => _set(c, v),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  InfoBanner(
                    icon: Icons.lock_outline_rounded,
                    message: const Text(
                      'Notifications never show your location, contacts, messages or chat answers. '
                      'Open Child Assist to see the details.',
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
