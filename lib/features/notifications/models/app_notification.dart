import '../../../core/notifications/notification_types.dart';

/// One entry in the user's notification history, as the server returns it.
class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.route,
    required this.createdAt,
    this.readAt,
  });

  final String id;
  final AppNotificationType type;
  final String title;
  final String body;
  final NotificationRoute route;
  final DateTime createdAt;
  final DateTime? readAt;

  bool get read => readAt != null;

  NotificationCategory get category => type.category;

  AppNotification markedRead(DateTime at) => AppNotification(
    id: id,
    type: type,
    title: title,
    body: body,
    route: route,
    createdAt: createdAt,
    readAt: readAt ?? at,
  );

  static AppNotification? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], title = json['title'], body = json['body'];
    final createdAt = json['createdAt'] is String ? DateTime.tryParse(json['createdAt'] as String) : null;
    if (id is! String || title is! String || body is! String || createdAt == null) return null;
    final readAt = json['readAt'] is String ? DateTime.tryParse(json['readAt'] as String) : null;
    return AppNotification(
      id: id,
      type: AppNotificationType.fromWire(json['type'] as String?),
      title: title,
      body: body,
      route: NotificationRoute.parse(json['deepLink'] as String?),
      createdAt: createdAt.toLocal(),
      readAt: readAt?.toLocal(),
    );
  }
}

class NotificationPage {
  const NotificationPage({required this.notifications, required this.hasMore, required this.unreadCount});

  final List<AppNotification> notifications;
  final bool hasMore;
  final int unreadCount;
}

/// Which categories the user wants. Security is always on.
class NotificationPreferences {
  const NotificationPreferences(this.enabled);

  final Map<NotificationCategory, bool> enabled;

  bool isEnabled(NotificationCategory category) => category.mandatory || (enabled[category] ?? true);

  NotificationPreferences copyWith(NotificationCategory category, bool value) =>
      NotificationPreferences({...enabled, category: value});

  static NotificationPreferences fromJson(Object? json) {
    final map = json is Map ? json : const {};
    return NotificationPreferences({
      for (final c in NotificationCategory.values) c: c.mandatory || map[c.preferenceKey] != false,
    });
  }
}
