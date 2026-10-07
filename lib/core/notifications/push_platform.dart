import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_types.dart';

/// A notification as delivered by FCM (or re-shown locally). Only the fixed title and body and
/// the routing fields the server sends: never any personal data.
class PushMessage {
  const PushMessage({this.notificationId, this.title, this.body, this.type, this.category, this.deepLink});

  /// The history entry's ID, used to mark it read and to drop duplicates.
  final String? notificationId;
  final String? title;
  final String? body;
  final AppNotificationType? type;
  final NotificationCategory? category;
  final String? deepLink;

  NotificationRoute get route => NotificationRoute.parse(deepLink);

  static PushMessage fromData(Map<String, dynamic> data, {String? title, String? body}) {
    String? text(String key) => data[key] is String && (data[key] as String).isNotEmpty ? data[key] as String : null;
    final type = text('type');
    return PushMessage(
      notificationId: text('notificationId'),
      title: title ?? text('title'),
      body: body ?? text('body'),
      type: type == null ? null : AppNotificationType.fromWire(type),
      category: NotificationCategory.fromWire(text('category')),
      deepLink: text('deepLink'),
    );
  }

  /// What a locally shown notification carries, so a tap on it routes like a push.
  String toPayload() => jsonEncode({
    'notificationId': ?notificationId,
    'type': ?type?.wireName,
    'category': ?category?.wireName,
    'deepLink': ?deepLink,
  });

  static PushMessage? fromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map<String, dynamic> ? fromData(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() => 'PushMessage(${type?.wireName}, $notificationId)';
}

/// Android notification channels. Only security alerts are high importance; the existing
/// "Automatic Location History" foreground-service channel is geolocator's own and is not touched.
abstract final class NotificationChannels {
  static const security = AndroidNotificationChannel(
    'child_assist_security',
    'Security alerts',
    description: 'New sign-ins and password changes.',
    importance: Importance.high,
  );
  static const location = AndroidNotificationChannel(
    'child_assist_location',
    'Location & travel',
    description: 'Automatic Location History started, stopped or paused.',
  );
  static const chat = AndroidNotificationChannel(
    'child_assist_chat',
    'Chat',
    description: 'When Child Assist has an answer ready.',
  );
  static const actions = AndroidNotificationChannel(
    'child_assist_actions',
    'Communication actions',
    description: 'Emails sent and WhatsApp messages ready to send.',
  );
  static const general = AndroidNotificationChannel(
    'child_assist_general',
    'General',
    description: 'Account, permission and other notices.',
  );

  static const all = [security, location, chat, actions, general];

  static AndroidNotificationChannel forCategory(NotificationCategory? category) => switch (category) {
    NotificationCategory.security => security,
    NotificationCategory.location => location,
    NotificationCategory.chat => chat,
    NotificationCategory.communication => actions,
    _ => general,
  };
}

/// The device side of push notifications. Separated out so tests never need Firebase.
abstract class PushPlatform {
  /// Whether this platform can receive pushes at all (Android and iOS).
  bool get isSupported;

  /// Starts Firebase Messaging and local notifications and creates the Android channels. Never
  /// asks for a permission: the app's own permission flow does that.
  Future<void> initialize();

  Future<String?> getToken();

  /// Invalidates this phone's FCM token (logout): pushes for the previous account can no longer
  /// reach it, even if the server still had it.
  Future<void> deleteToken();

  Stream<String> get onTokenRefresh;

  /// Pushes that arrive while the app is open. Android and iOS do not show these themselves.
  Stream<PushMessage> get onForegroundMessage;

  /// Taps on a notification while the app was running (in the background or open).
  Stream<PushMessage> get onOpened;

  /// The notification whose tap launched the app from closed, once; null otherwise.
  Future<PushMessage?> takeLaunchMessage();

  /// Shows [message] in the notification shade (for pushes that arrived in the foreground).
  Future<void> show(PushMessage message);

  /// Removes Child Assist's notifications from the shade.
  Future<void> cancelAll();
}

/// Firebase Cloud Messaging for delivery, flutter_local_notifications for showing pushes that
/// arrive while the app is open. Firebase is used for nothing else.
class FirebasePushPlatform implements PushPlatform {
  final _local = FlutterLocalNotificationsPlugin();
  final _opened = StreamController<PushMessage>.broadcast();
  Future<void>? _initializing;
  PushMessage? _launchMessage;
  bool _launchTaken = false;

  static bool get _isMobile =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  @override
  bool get isSupported => _isMobile;

  @override
  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    // Reads android/app/google-services.json / ios/Runner/GoogleService-Info.plist.
    await Firebase.initializeApp();
    await _local.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_child_assist'),
        // Permission is asked by the app's permission flow, never on start-up.
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (response) {
        final message = PushMessage.fromPayload(response.payload);
        if (message != null) _opened.add(message);
      },
    );
    final android = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    for (final channel in NotificationChannels.all) {
      await android?.createNotificationChannel(channel);
    }
    FirebaseMessaging.onMessageOpenedApp.listen(
      (m) => _opened.add(PushMessage.fromData(m.data, title: m.notification?.title, body: m.notification?.body)),
    );

    // Launched from closed by a tap: either on a push shown by the system or on one we showed.
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) {
      _launchMessage = PushMessage.fromData(
        initial.data,
        title: initial.notification?.title,
        body: initial.notification?.body,
      );
    } else {
      final details = await _local.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp ?? false) {
        _launchMessage = PushMessage.fromPayload(details!.notificationResponse?.payload);
      }
    }
  }

  @override
  Future<String?> getToken() => FirebaseMessaging.instance.getToken();

  @override
  Future<void> deleteToken() => FirebaseMessaging.instance.deleteToken();

  @override
  Stream<String> get onTokenRefresh => FirebaseMessaging.instance.onTokenRefresh;

  @override
  Stream<PushMessage> get onForegroundMessage => FirebaseMessaging.onMessage.map(
    (m) => PushMessage.fromData(m.data, title: m.notification?.title, body: m.notification?.body),
  );

  @override
  Stream<PushMessage> get onOpened => _opened.stream;

  @override
  Future<PushMessage?> takeLaunchMessage() async {
    await initialize();
    if (_launchTaken) return null;
    _launchTaken = true;
    return _launchMessage;
  }

  @override
  Future<void> show(PushMessage message) {
    final channel = NotificationChannels.forCategory(message.category);
    final high = channel.importance == Importance.high;
    return _local.show(
      // Stable per notification, and the same tag FCM uses: never shown twice.
      id: (message.notificationId ?? message.toPayload()).hashCode & 0x7fffffff,
      title: message.title,
      body: message.body,
      payload: message.toPayload(),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: channel.importance,
          priority: high ? Priority.high : Priority.defaultPriority,
          icon: 'ic_stat_child_assist',
          tag: message.notificationId,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
    );
  }

  @override
  Future<void> cancelAll() => _local.cancelAll();
}
