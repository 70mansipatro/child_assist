import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/navigation/app_menu.dart';
import '../../../core/notifications/notification_service.dart';
import '../../../core/permissions/permission_service.dart';
import '../../../core/widgets/widgets.dart';
import '../models/app_notification.dart';
import 'notification_settings_screen.dart';

/// The signed-in account's notification history: unread ones highlighted, grouped into Today,
/// Yesterday and Earlier. Tapping one marks it read and opens what it is about.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({
    super.key,
    required this.notificationService,
    required this.permissionService,
    this.onOpenRoute,
    this.onOpenPermissions,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  final NotificationService notificationService;

  /// Only to show whether notifications are allowed on this phone (no dialog is shown here).
  final PermissionService permissionService;

  /// Opens the screen a notification is about.
  final ValueChanged<NotificationRoute>? onOpenRoute;

  /// Opens Permissions, where the notification permission can be turned on or off.
  final VoidCallback? onOpenPermissions;

  /// Device local time, for the Today / Yesterday grouping. Replaceable in tests.
  final DateTime Function() now;

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final List<AppNotification> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;
  bool _osBlocked = false;

  NotificationService get _service => widget.notificationService;

  @override
  void initState() {
    super.initState();
    _load();
    _checkPermission();
  }

  Future<void> _checkPermission() async {
    final state = await widget.permissionService.notificationStatus();
    if (mounted) setState(() => _osBlocked = !state.isUsable && state != PermissionState.unavailable);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _service.loadPage();
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.notifications);
        _hasMore = page.hasMore;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _items.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _service.loadPage(before: _items.last.id);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.notifications);
        _hasMore = page.hasMore;
      });
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _open(AppNotification n) async {
    if (!n.read) {
      setState(() {
        final i = _items.indexWhere((x) => x.id == n.id);
        if (i >= 0) _items[i] = n.markedRead(DateTime.now());
      });
      await _service.markRead(n.id);
    }
    widget.onOpenRoute?.call(n.route);
  }

  Future<void> _markAllRead() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _service.markAllRead();
      if (!mounted) return;
      final now = DateTime.now();
      setState(() {
        for (var i = 0; i < _items.length; i++) {
          _items[i] = _items[i].markedRead(now);
        }
      });
      messenger.showSnackBar(const SnackBar(content: Text('All notifications marked as read')));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  void _openSettings() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => NotificationSettingsScreen(
        notificationService: _service,
        permissionService: widget.permissionService,
        onOpenPermissions: widget.onOpenPermissions,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final hasUnread = _items.any((n) => !n.read);
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: const AppBarGradient(),
        title: const Text('Notifications'),
        actions: [
          if (hasUnread)
            IconButton(tooltip: 'Mark all as read', onPressed: _markAllRead, icon: const Icon(Icons.done_all_rounded)),
          IconButton(tooltip: 'Notification settings', onPressed: _openSettings, icon: const Icon(Icons.tune_rounded)),
          const AppMenuButton(current: AppDestination.notifications),
        ],
      ),
      body: SafeArea(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading && _items.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_error != null && _items.isEmpty) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        gradient: AppGradients.danger,
        title: "Couldn't load notifications",
        body: _error,
        action: GradientButton(onPressed: _load, label: const Text('Retry')),
      );
    }
    final banner = _osBlocked ? _BlockedBanner(onOpenPermissions: widget.onOpenPermissions) : null;
    if (_items.isEmpty) {
      return Column(
        children: [
          if (banner != null) Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 0), child: banner),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: constraints.maxHeight),
                    child: StateMessage(
                      icon: Icons.notifications_none_rounded,
                      gradient: AppGradients.notifications,
                      title: 'No notifications yet',
                      body: "When Child Assist has something for you, it'll show up here.",
                      action: OutlinedButton.icon(
                        onPressed: _openSettings,
                        icon: const Icon(Icons.tune_rounded),
                        label: const Text('Notification settings'),
                      ),
                      secondaryAction: widget.onOpenPermissions == null
                          ? null
                          : TextButton.icon(
                              onPressed: widget.onOpenPermissions,
                              icon: const Icon(Icons.shield_outlined),
                              label: const Text('Notification permission'),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    final groups = _group(_items, widget.now());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        children: [
          if (banner != null) ...[banner, const SizedBox(height: 16)],
          for (final group in groups) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 10, top: 4),
              child: SectionTitle(group.label),
            ),
            for (final n in group.items) ...[
              _NotificationCard(notification: n, now: widget.now(), onTap: () => _open(n)),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 8),
          ],
          if (_hasMore)
            Center(
              child: _loadingMore
                  ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator())
                  : TextButton(onPressed: _loadMore, child: const Text('Show older notifications')),
            ),
        ],
      ),
    );
  }

  static List<({String label, List<AppNotification> items})> _group(List<AppNotification> items, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final buckets = <String, List<AppNotification>>{'Today': [], 'Yesterday': [], 'Earlier': []};
    for (final n in items) {
      final at = n.createdAt.toLocal();
      final day = DateTime(at.year, at.month, at.day);
      final key = !day.isBefore(today) ? 'Today' : (day == yesterday ? 'Yesterday' : 'Earlier');
      buckets[key]!.add(n);
    }
    return [
      for (final e in buckets.entries)
        if (e.value.isNotEmpty) (label: e.key, items: e.value),
    ];
  }
}

class _BlockedBanner extends StatelessWidget {
  const _BlockedBanner({this.onOpenPermissions});

  final VoidCallback? onOpenPermissions;

  @override
  Widget build(BuildContext context) {
    return InfoBanner(
      tone: BannerTone.warning,
      icon: Icons.notifications_off_rounded,
      title: 'Notifications are off on this phone',
      message: const Text("You'll still find them here, but your phone won't alert you."),
      actions: [
        if (onOpenPermissions != null) TextButton(onPressed: onOpenPermissions, child: const Text('Turn on')),
      ],
    );
  }
}

class _NotificationCard extends StatelessWidget {
  const _NotificationCard({required this.notification, required this.now, required this.onTap});

  final AppNotification notification;
  final DateTime now;
  final VoidCallback onTap;

  static String _time(BuildContext context, DateTime at, DateTime now) {
    final local = at.toLocal();
    final time = TimeOfDay.fromDateTime(local).format(context);
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    if (!day.isBefore(today.subtract(const Duration(days: 1)))) return time;
    return '${MaterialLocalizations.of(context).formatShortDate(local)}, $time';
  }

  static IconData _icon(AppNotification n) => switch (n.type) {
    AppNotificationType.accountLogin => Icons.login_rounded,
    AppNotificationType.passwordChanged || AppNotificationType.passwordReset => Icons.key_rounded,
    AppNotificationType.trackingPaused => Icons.location_disabled_rounded,
    AppNotificationType.trackingStopped => Icons.location_off_rounded,
    AppNotificationType.travelHistoryUpdated => Icons.route_rounded,
    AppNotificationType.emailAction => Icons.email_rounded,
    AppNotificationType.whatsappAction => Icons.chat_rounded,
    AppNotificationType.documentUpdated => Icons.description_rounded,
    AppNotificationType.photoUpdated => Icons.photo_library_rounded,
    _ => n.category.icon,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = notification;
    final unread = !n.read;
    final accent = theme.colorScheme.primary;
    return Semantics(
      label: unread ? 'Unread' : null,
      child: AppCard(
        key: ValueKey('notification-${n.id}'),
        onTap: onTap,
        padding: const EdgeInsets.all(14),
        color: unread ? Color.alphaBlend(accent.withValues(alpha: 0.07), theme.colorScheme.surface) : null,
        borderColor: unread ? accent.withValues(alpha: 0.35) : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconBadge(icon: _icon(n), gradient: n.category.gradient, size: 42, glow: unread),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          n.title,
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: unread ? FontWeight.w700 : FontWeight.w500),
                        ),
                      ),
                      if (unread) ...[const SizedBox(width: 8), StatusDot(color: accent)],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(n.body, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 6),
                  Text(_time(context, n.createdAt, now), style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
