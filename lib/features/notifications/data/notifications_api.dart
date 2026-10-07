import '../../../core/api/api_client.dart';
import '../../../core/notifications/notification_types.dart';
import '../models/app_notification.dart';

/// The push registration the server stored for this phone.
class RegisteredDevice {
  const RegisteredDevice(this.id);

  final String id;
}

/// Raw calls to the backend's /api/notifications endpoints. The server identifies the user from
/// the token, so no user ID is ever sent.
class NotificationsApi {
  NotificationsApi(this._client);

  final ApiClient _client;

  /// Registers this phone's FCM token for the signed-in account. [platform] is ANDROID or IOS.
  Future<RegisteredDevice> registerDevice(String token, {required String fcmToken, required String platform, String? appVersion}) async {
    final json = await _client.post(
      '/api/notifications/devices',
      token: token,
      body: {'token': fcmToken, 'platform': platform, 'appVersion': ?appVersion},
    );
    final device = json['device'];
    final id = device is Map ? device['id'] : null;
    if (id is! String) throw ApiException('Unexpected response from the server.');
    return RegisteredDevice(id);
  }

  Future<void> unregisterDevice(String token, String deviceId) =>
      _client.delete('/api/notifications/devices/${Uri.encodeComponent(deviceId)}', token: token);

  Future<NotificationPage> list(String token, {String? before, int limit = 30}) async {
    final query = {'limit': '$limit', 'before': ?before};
    final json = await _client.get('/api/notifications?${Uri(queryParameters: query).query}', token: token);
    final items = json['notifications'];
    return NotificationPage(
      notifications: [
        if (items is List)
          for (final item in items) ?AppNotification.fromJson(item),
      ],
      hasMore: json['hasMore'] == true,
      unreadCount: (json['unreadCount'] as num?)?.toInt() ?? 0,
    );
  }

  Future<int> unreadCount(String token) async {
    final json = await _client.get('/api/notifications/unread-count', token: token);
    return (json['unreadCount'] as num?)?.toInt() ?? 0;
  }

  Future<void> markRead(String token, String id) =>
      _client.patch('/api/notifications/${Uri.encodeComponent(id)}/read', token: token);

  Future<void> markAllRead(String token) => _client.patch('/api/notifications/read-all', token: token);

  Future<NotificationPreferences> preferences(String token) async {
    final json = await _client.get('/api/notifications/preferences', token: token);
    return NotificationPreferences.fromJson(json['preferences']);
  }

  Future<NotificationPreferences> updatePreference(String token, NotificationCategory category, bool enabled) async {
    final json = await _client.patch(
      '/api/notifications/preferences',
      token: token,
      body: {category.preferenceKey: enabled},
    );
    return NotificationPreferences.fromJson(json['preferences']);
  }
}
