import { NotificationType, PermissionType } from "../../../generated/prisma/client";

export { NotificationType };

// The single source of truth for what Child Assist notifications say and where they lead.
// Business code never writes notification text: it picks a template below. Every title and body
// is fixed product copy, so a push can never carry coordinates, an address, a contact's details,
// chat content, a code or a token. The app loads any details itself, authenticated, once opened.

/** The preference switches the user controls (Profile > Notifications > Settings). */
export const NotificationCategory = {
  SECURITY: "SECURITY",
  ACCOUNT: "ACCOUNT",
  PERMISSION: "PERMISSION",
  LOCATION: "LOCATION",
  CHAT: "CHAT",
  COMMUNICATION: "COMMUNICATION",
  SYSTEM: "SYSTEM",
} as const;
export type NotificationCategory = (typeof NotificationCategory)[keyof typeof NotificationCategory];

export const CATEGORY_OF: Record<NotificationType, NotificationCategory> = {
  ACCOUNT_LOGIN: "SECURITY",
  ACCOUNT_SECURITY: "SECURITY",
  PASSWORD_RESET: "SECURITY",
  PASSWORD_CHANGED: "SECURITY",
  EMAIL_VERIFICATION: "ACCOUNT",
  PERMISSION_CHANGED: "PERMISSION",
  TRACKING_STARTED: "LOCATION",
  TRACKING_STOPPED: "LOCATION",
  TRACKING_PAUSED: "LOCATION",
  LOCATION_UPDATED: "LOCATION",
  TRAVEL_HISTORY_UPDATED: "LOCATION",
  CHAT_REPLY_READY: "CHAT",
  EMAIL_ACTION: "COMMUNICATION",
  WHATSAPP_ACTION: "COMMUNICATION",
  // Documents and photos stay on the phone; these are optional and grouped with system notices.
  DOCUMENT_UPDATED: "SYSTEM",
  PHOTO_UPDATED: "SYSTEM",
  SYSTEM: "SYSTEM",
  GENERAL: "SYSTEM",
};

/** Always delivered: the user cannot switch off alerts about their account's security. */
export const MANDATORY_CATEGORIES: ReadonlySet<NotificationCategory> = new Set(["SECURITY"]);

/** Android notification channels, created by the app with the same IDs. */
export const ANDROID_CHANNEL: Record<NotificationCategory, string> = {
  SECURITY: "child_assist_security",
  ACCOUNT: "child_assist_general",
  PERMISSION: "child_assist_general",
  LOCATION: "child_assist_location",
  CHAT: "child_assist_chat",
  COMMUNICATION: "child_assist_actions",
  SYSTEM: "child_assist_general",
};

/** Only security alerts are sent at high priority; everything else waits for the normal slot. */
export function isHighPriority(type: NotificationType): boolean {
  return CATEGORY_OF[type] === "SECURITY";
}

/** In-app routes. The app maps each to one of its screens; unknown links open Notifications. */
export const DeepLink = {
  notifications: "childassist://notifications",
  security: "childassist://profile/security",
  verifyEmail: "childassist://verify-email",
  permissions: "childassist://permissions",
  locationPermission: "childassist://permissions/location",
  location: "childassist://location",
  chat: "childassist://chat",
  documents: "childassist://documents",
  photos: "childassist://photos",
} as const;
export type DeepLink = (typeof DeepLink)[keyof typeof DeepLink];

export interface NotificationContent {
  type: NotificationType;
  title: string;
  body: string;
  deepLink: DeepLink;
  /** Non-sensitive extras only (e.g. which permission changed). */
  metadata?: Record<string, string>;
}

const PERMISSION_LABEL: Record<PermissionType, string> = {
  LOCATION: "Location",
  MICROPHONE: "Microphone",
  CAMERA: "Camera",
  PHOTOS: "Photos",
  NOTIFICATIONS: "Notifications",
  DOCUMENTS: "Documents",
  CONTACTS: "Contacts",
};

export const templates = {
  newLogin: (): NotificationContent => ({
    type: NotificationType.ACCOUNT_LOGIN,
    title: "New login to Child Assist",
    body: "A new device signed in to your account.",
    deepLink: DeepLink.security,
  }),
  passwordChanged: (): NotificationContent => ({
    type: NotificationType.PASSWORD_CHANGED,
    title: "Password changed",
    body: "Your Child Assist password was changed successfully.",
    deepLink: DeepLink.security,
  }),
  passwordReset: (): NotificationContent => ({
    type: NotificationType.PASSWORD_RESET,
    title: "Password reset complete",
    body: "Your Child Assist password has been changed.",
    deepLink: DeepLink.security,
  }),
  emailVerificationPending: (): NotificationContent => ({
    type: NotificationType.EMAIL_VERIFICATION,
    title: "Verify your email address",
    body: "Your email verification is still pending.",
    deepLink: DeepLink.verifyEmail,
  }),
  /** A permission the app relies on is no longer allowed on the phone. */
  permissionDisabled: (permission: PermissionType): NotificationContent => {
    const label = PERMISSION_LABEL[permission];
    return {
      type: NotificationType.PERMISSION_CHANGED,
      title: `${label} permission changed`,
      body:
        permission === PermissionType.LOCATION
          ? "Location access is currently disabled."
          : `Your ${label.toLowerCase()} permission is currently disabled.`,
      deepLink: permission === PermissionType.LOCATION ? DeepLink.locationPermission : DeepLink.permissions,
      metadata: { permission },
    };
  },
  trackingStarted: (): NotificationContent => ({
    type: NotificationType.TRACKING_STARTED,
    title: "Location tracking started",
    body: "Child Assist is now updating your travel history.",
    deepLink: DeepLink.location,
  }),
  trackingStopped: (): NotificationContent => ({
    type: NotificationType.TRACKING_STOPPED,
    title: "Location tracking stopped",
    body: "Automatic travel history updates have stopped.",
    deepLink: DeepLink.location,
  }),
  trackingPaused: (): NotificationContent => ({
    type: NotificationType.TRACKING_PAUSED,
    title: "Location tracking paused",
    body: "Location access is required to continue automatic travel history.",
    deepLink: DeepLink.locationPermission,
  }),
  travelHistoryUpdated: (): NotificationContent => ({
    type: NotificationType.TRAVEL_HISTORY_UPDATED,
    title: "Travel history updated",
    body: "Your travel history has new activity.",
    deepLink: DeepLink.location,
  }),
  chatReplyReady: (): NotificationContent => ({
    type: NotificationType.CHAT_REPLY_READY,
    title: "Child Assist",
    body: "Your requested information is ready.",
    deepLink: DeepLink.chat,
  }),
  emailSent: (): NotificationContent => ({
    type: NotificationType.EMAIL_ACTION,
    title: "Email sent",
    body: "Your email was sent successfully.",
    deepLink: DeepLink.chat,
  }),
  emailFailed: (): NotificationContent => ({
    type: NotificationType.EMAIL_ACTION,
    title: "Email could not be sent",
    body: "Please try again.",
    deepLink: DeepLink.chat,
  }),
  /** Opening WhatsApp is not sending: the user still taps Send there, so never claim it was sent. */
  whatsappOpened: (): NotificationContent => ({
    type: NotificationType.WHATSAPP_ACTION,
    title: "WhatsApp opened",
    body: "Review the message and tap Send in WhatsApp.",
    deepLink: DeepLink.chat,
  }),
  documentAdded: (): NotificationContent => ({
    type: NotificationType.DOCUMENT_UPDATED,
    title: "Document added",
    body: "A document was added to Child Assist.",
    deepLink: DeepLink.documents,
  }),
  documentRemoved: (): NotificationContent => ({
    type: NotificationType.DOCUMENT_UPDATED,
    title: "Document removed",
    body: "A document was removed from Child Assist.",
    deepLink: DeepLink.documents,
  }),
  photosRefreshed: (): NotificationContent => ({
    type: NotificationType.PHOTO_UPDATED,
    title: "Photos refreshed",
    body: "Your photos are up to date.",
    deepLink: DeepLink.photos,
  }),
  appUpdate: (): NotificationContent => ({
    type: NotificationType.SYSTEM,
    title: "Child Assist update",
    body: "A new version of Child Assist is available.",
    deepLink: DeepLink.notifications,
  }),
  reviewSettings: (): NotificationContent => ({
    type: NotificationType.SYSTEM,
    title: "Child Assist",
    body: "Please review your notification settings.",
    deepLink: DeepLink.notifications,
  }),
  /** For checking delivery end to end (see scripts/send-notification.ts). */
  test: (deepLink: DeepLink = DeepLink.notifications): NotificationContent => ({
    type: NotificationType.GENERAL,
    title: "Child Assist test notification",
    body: "Notifications are working on this device.",
    deepLink,
  }),
} as const;

// Defence in depth for future templates: content that looks like an email address, a phone
// number, coordinates or a long code is refused before it is stored or pushed.
const UNSAFE_PATTERNS: RegExp[] = [
  /[^\s@]+@[^\s@]+\.[^\s@]+/, // email address
  /\d[\d\s().+-]{4,}\d/, // phone number, verification code or other long number
  /-?\d{1,3}\.\d{3,}/, // coordinate-like decimal
];

export function isSafeContent(content: Pick<NotificationContent, "title" | "body">): boolean {
  return !UNSAFE_PATTERNS.some((p) => p.test(content.title) || p.test(content.body));
}
