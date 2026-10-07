import 'package:flutter/material.dart';

import '../navigation/app_menu.dart';
import '../theme/app_theme.dart';

/// Every kind of notification the backend sends. Mirrors the server's `NotificationType` enum
/// (backend/prisma/schema.prisma); unknown values from a newer server read as [general].
enum AppNotificationType {
  accountLogin('ACCOUNT_LOGIN'),
  accountSecurity('ACCOUNT_SECURITY'),
  emailVerification('EMAIL_VERIFICATION'),
  passwordReset('PASSWORD_RESET'),
  passwordChanged('PASSWORD_CHANGED'),
  permissionChanged('PERMISSION_CHANGED'),
  trackingStarted('TRACKING_STARTED'),
  trackingStopped('TRACKING_STOPPED'),
  trackingPaused('TRACKING_PAUSED'),
  locationUpdated('LOCATION_UPDATED'),
  travelHistoryUpdated('TRAVEL_HISTORY_UPDATED'),
  chatReplyReady('CHAT_REPLY_READY'),
  emailAction('EMAIL_ACTION'),
  whatsappAction('WHATSAPP_ACTION'),
  documentUpdated('DOCUMENT_UPDATED'),
  photoUpdated('PHOTO_UPDATED'),
  system('SYSTEM'),
  general('GENERAL');

  const AppNotificationType(this.wireName);

  final String wireName;

  static AppNotificationType fromWire(String? value) =>
      values.firstWhere((t) => t.wireName == value, orElse: () => general);

  NotificationCategory get category => switch (this) {
    accountLogin || accountSecurity || passwordReset || passwordChanged => NotificationCategory.security,
    emailVerification => NotificationCategory.account,
    permissionChanged => NotificationCategory.permission,
    trackingStarted || trackingStopped || trackingPaused || locationUpdated || travelHistoryUpdated =>
      NotificationCategory.location,
    chatReplyReady => NotificationCategory.chat,
    emailAction || whatsappAction => NotificationCategory.communication,
    documentUpdated || photoUpdated || system || general => NotificationCategory.system,
  };
}

/// The switches in Notification settings. Same as the server's categories.
enum NotificationCategory {
  security('SECURITY', 'Security', 'New sign-ins and password changes. Always on to protect your account.',
      Icons.shield_rounded, AppGradients.danger, 'securityEnabled'),
  account('ACCOUNT', 'Email & Account', 'Reminders about your account and email address.',
      Icons.manage_accounts_rounded, AppGradients.profile, 'accountEnabled'),
  permission('PERMISSION', 'Permissions', 'When a permission Child Assist uses is turned off.',
      Icons.verified_user_rounded, AppGradients.permissions, 'permissionEnabled'),
  location('LOCATION', 'Location & Travel', 'Automatic Location History started, stopped or paused.',
      Icons.location_on_rounded, AppGradients.location, 'locationEnabled'),
  chat('CHAT', 'Chat', 'When Child Assist has an answer ready for you.',
      Icons.chat_bubble_rounded, AppGradients.brand, 'chatEnabled'),
  communication('COMMUNICATION', 'Communication Actions', 'Emails sent and WhatsApp messages ready to send.',
      Icons.forward_to_inbox_rounded, AppGradients.documents, 'communicationEnabled'),
  system('SYSTEM', 'System', 'App updates and other notices from Child Assist.',
      Icons.notifications_rounded, AppGradients.notifications, 'systemEnabled');

  const NotificationCategory(this.wireName, this.label, this.description, this.icon, this.gradient, this.preferenceKey);

  final String wireName;
  final String label;
  final String description;
  final IconData icon;
  final LinearGradient gradient;

  /// The field in the preferences API.
  final String preferenceKey;

  /// Security alerts cannot be switched off.
  bool get mandatory => this == security;

  static NotificationCategory? fromWire(String? value) {
    for (final c in values) {
      if (c.wireName == value) return c;
    }
    return null;
  }
}

/// Where a notification leads inside the app. Pushes carry it as a `childassist://` link; links
/// this app version does not know open the Notifications screen.
enum NotificationRoute {
  notifications('childassist://notifications', AppDestination.notifications),
  // There is no separate security page: the account lives in Profile.
  security('childassist://profile/security', AppDestination.profile),
  // Only verified accounts can sign in, so there is nothing to verify once inside the app.
  verifyEmail('childassist://verify-email', AppDestination.notifications),
  permissions('childassist://permissions', AppDestination.permissions),
  locationPermission('childassist://permissions/location', AppDestination.permissions),
  location('childassist://location', AppDestination.location),
  chat('childassist://chat', AppDestination.chat),
  documents('childassist://documents', AppDestination.documents),
  photos('childassist://photos', AppDestination.photos);

  const NotificationRoute(this.link, this.destination);

  final String link;

  /// The page it opens, through the app's existing navigation.
  final AppDestination destination;

  static NotificationRoute parse(String? link) {
    for (final r in values) {
      if (r.link == link) return r;
    }
    return notifications;
  }
}
