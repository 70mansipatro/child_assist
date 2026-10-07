import { applicationDefault, cert, deleteApp, initializeApp, type App, type Credential } from "firebase-admin/app";
import { getMessaging, type Message } from "firebase-admin/messaging";
import { GoogleAuth, Impersonated } from "google-auth-library";
import { pushConfig, type PushConfig } from "../../config/env";

// Firebase Cloud Messaging delivery, and nothing else from Firebase. The server credential never
// leaves the backend: it comes from a key file outside the repo, from impersonating the Firebase
// Admin service account with Application Default Credentials, or from ADC itself.

export interface PushMessage {
  token: string;
  title: string;
  body: string;
  /** Delivered to the app with the notification; strings only, and never sensitive. */
  data: Record<string, string>;
  androidChannelId: string;
  highPriority: boolean;
}

export type PushResult = { ok: true } | { ok: false; invalidToken: boolean; errorCode: string };

/** Sends one message per entry and reports each outcome in the same order. */
export type PushSender = (messages: PushMessage[]) => Promise<PushResult[]>;

let senderOverride: PushSender | null = null;

/** Lets tests capture pushes instead of sending them. `null` restores FCM. */
export function setPushSender(sender: PushSender | null): void {
  senderOverride = sender;
}

/** Whether pushes can be sent: FCM is configured (or a test sender is installed). */
export function pushAvailable(): boolean {
  return senderOverride !== null || !pushConfig().error;
}

// FCM's answers for a token that will never work again: the app was uninstalled, the token was
// rotated, or it is not an FCM token at all. Such devices are removed.
const INVALID_TOKEN_CODES = new Set([
  "messaging/registration-token-not-registered",
  "messaging/invalid-registration-token",
]);

export function isInvalidTokenError(code: string): boolean {
  return INVALID_TOKEN_CODES.has(code);
}

const CLOUD_SCOPE = "https://www.googleapis.com/auth/cloud-platform";
/** All the impersonated token can do: send FCM messages. */
export const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

/** Development-only diagnostics: error codes and messages, never tokens or keys. */
function diag(message: string): void {
  if (process.env.NODE_ENV === "development") console.log(`[fcm] ${message}`);
}

/** Removes anything token-like (long opaque strings) from an error message before logging it. */
export function redact(message: string): string {
  return message.replace(/[A-Za-z0-9_\-:.]{40,}/g, "[redacted]").slice(0, 500);
}

/** The impersonation client, for the credential below and the self-test script. */
export async function impersonatedClient(serviceAccount: string, projectId: string): Promise<Impersonated> {
  const sourceClient = await new GoogleAuth({ scopes: [CLOUD_SCOPE] }).getClient();
  // A user ADC login carries its own quota project (whichever project `gcloud auth
  // application-default login` picked), and the IAM Credentials call is checked and billed there.
  // Bill it to the Firebase project instead, where the API is enabled. Set after loading: the ADC
  // file's quota_project_id overrides any constructor option.
  sourceClient.quotaProjectId = projectId;
  return new Impersonated({
    sourceClient,
    targetPrincipal: serviceAccount,
    targetScopes: [FCM_SCOPE],
    lifetime: 3600,
    delegates: [],
  });
}

/** Short-lived tokens for [serviceAccount], minted from the ADC identity. No key file. */
function impersonatedCredential(serviceAccount: string, projectId: string): Credential {
  let client: Impersonated | undefined;
  return {
    async getAccessToken() {
      if (!client) client = await impersonatedClient(serviceAccount, projectId);
      const { token } = await client.getAccessToken();
      if (!token) throw new Error("Impersonation returned no access token");
      const expiresAt = client.credentials.expiry_date ?? Date.now() + 3_000_000;
      return { access_token: token, expires_in: Math.max(60, Math.floor((expiresAt - Date.now()) / 1000)) };
    },
  };
}

function credentialFor(config: PushConfig): Credential {
  if (config.serviceAccountPath) return cert(config.serviceAccountPath);
  if (config.impersonateServiceAccount) return impersonatedCredential(config.impersonateServiceAccount, config.projectId);
  return applicationDefault();
}

let cached: { key: string; app: App } | undefined;

function appFor(config: PushConfig): App {
  const key = JSON.stringify(config);
  if (cached?.key !== key) {
    if (cached) void deleteApp(cached.app).catch(() => undefined);
    cached = { key, app: initializeApp({ credential: credentialFor(config), projectId: config.projectId }, `fcm-${Date.now()}`) };
  }
  return cached.app;
}

function toFcm(message: PushMessage): Message {
  return {
    token: message.token,
    notification: { title: message.title, body: message.body },
    data: message.data,
    android: {
      priority: message.highPriority ? "high" : "normal",
      notification: {
        channelId: message.androidChannelId,
        // The same notification never shows twice in the tray, even if delivered twice.
        tag: message.data.notificationId,
        icon: "ic_stat_child_assist",
        color: "#5B4BFF",
      },
    },
    apns: {
      headers: { "apns-priority": message.highPriority ? "10" : "5" },
      payload: { aps: { sound: "default" } },
    },
  };
}

async function sendWithFcm(messages: PushMessage[]): Promise<PushResult[]> {
  const { config, error } = pushConfig();
  if (!config) throw new Error(`Push is not configured: ${error}`);
  const batch = await getMessaging(appFor(config)).sendEach(messages.map(toFcm));
  return batch.responses.map((r) => {
    if (r.success) return { ok: true } as const;
    const errorCode = r.error?.code ?? "unknown";
    diag(`send failed: ${errorCode}: ${redact(r.error?.message ?? "")}`);
    return { ok: false, invalidToken: isInvalidTokenError(errorCode), errorCode } as const;
  });
}

/** Sends [messages]; an empty list sends nothing. Throws only if FCM could not be reached at all. */
export async function sendPush(messages: PushMessage[]): Promise<PushResult[]> {
  if (messages.length === 0) return [];
  return (senderOverride ?? sendWithFcm)(messages);
}
