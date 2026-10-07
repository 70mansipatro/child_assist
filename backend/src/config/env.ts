// Centralised access to required environment variables.
// Fails fast at startup so the server never runs with a missing or default secret.

function requireEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`${name} is not set. Check your backend/.env file.`);
  }
  return value;
}

const jwtSecret = requireEnv("JWT_SECRET");
if (jwtSecret.length < 32) {
  throw new Error("JWT_SECRET must be at least 32 characters long.");
}

export const env = {
  jwtSecret,
  jwtExpiresIn: requireEnv("JWT_EXPIRES_IN"),
} as const;

/**
 * The Google OAuth *web/server* client ID that Google ID tokens must be issued to (their `aud`).
 * Read on demand: without it the rest of the API keeps working and POST /api/auth/google answers
 * 503. This is an ID, not a secret; no OAuth client secret is needed to verify ID tokens.
 */
export function googleWebClientId(): string | undefined {
  return process.env.GOOGLE_WEB_CLIENT_ID?.trim() || undefined;
}

export interface SmtpConfig {
  host: string;
  port: number;
  /** true: TLS from the start (usually port 465). false: STARTTLS upgrade (usually port 587). */
  secure: boolean;
  user: string | undefined;
  password: string | undefined;
  /** The From header, e.g. `Child Assist <no-reply@example.com>`. */
  from: string;
}

/**
 * SMTP settings for sending verification codes. Read on demand: without them the rest of the API
 * keeps working, and the endpoints that must send email answer 503. Returns undefined when SMTP is
 * not configured or a value is invalid; the error names the setting but never echoes its value.
 */
export function smtpConfig(): { config?: SmtpConfig; error?: string } {
  const optional = (name: string) => process.env[name]?.trim() || undefined;
  const host = optional("SMTP_HOST");
  const from = optional("SMTP_FROM");
  if (!host || !from) return { error: "SMTP_HOST and SMTP_FROM must be set" };

  const port = Number(optional("SMTP_PORT") ?? "587");
  if (!Number.isInteger(port) || port < 1 || port > 65535) return { error: "SMTP_PORT must be a port number" };

  const secureRaw = (optional("SMTP_SECURE") ?? "false").toLowerCase();
  if (secureRaw !== "true" && secureRaw !== "false") return { error: "SMTP_SECURE must be true or false" };

  const user = optional("SMTP_USER");
  // Not trimmed: a password may legitimately start or end with a space.
  const password = process.env.SMTP_PASSWORD || undefined;
  if (Boolean(user) !== Boolean(password)) return { error: "SMTP_USER and SMTP_PASSWORD must be set together" };

  return { config: { host, port, secure: secureRaw === "true", user, password, from } };
}

/** A whole number from the environment within [min, max], or the default when unset or invalid. */
function intSetting(name: string, fallback: number, min: number, max: number): number {
  const raw = process.env[name]?.trim();
  if (!raw) return fallback;
  const value = Number(raw);
  return Number.isInteger(value) && value >= min && value <= max ? value : fallback;
}

export interface AutomaticLocationConfig {
  /** An automatic point closer than this to an existing one... */
  duplicateDistanceMeters: number;
  /** ...and captured less than this apart is a duplicate and is not stored. */
  duplicateIntervalMs: number;
  /** Automatic points older than this are refused (a stale offline queue, or a bad clock). */
  maxAgeMs: number;
  /** POST /api/location requests allowed per user per window, manual and automatic together. */
  rateLimitMax: number;
  rateLimitWindowMs: number;
}

/**
 * Server-side rules for Automatic Location History. The app applies the same distance and time
 * thresholds before uploading; the server repeats them so a retried or repeated upload never
 * creates duplicate rows. Read on demand so tests and operators can tune them.
 */
export function automaticLocationConfig(): AutomaticLocationConfig {
  return {
    duplicateDistanceMeters: intSetting("AUTO_LOCATION_MIN_DISTANCE_METERS", 100, 1, 10_000),
    duplicateIntervalMs: intSetting("AUTO_LOCATION_MIN_INTERVAL_SECONDS", 300, 1, 86_400) * 1000,
    maxAgeMs: intSetting("AUTO_LOCATION_MAX_AGE_DAYS", 7, 1, 30) * 86_400_000,
    rateLimitMax: intSetting("LOCATION_RATE_LIMIT_MAX", 120, 1, 10_000),
    rateLimitWindowMs: intSetting("LOCATION_RATE_LIMIT_WINDOW_SECONDS", 600, 1, 86_400) * 1000,
  };
}

export interface ChatMemoryConfig {
  /** Most recent messages sent to the model word for word. */
  historyMessageLimit: number;
  /**
   * Older messages wait until this many have built up before being folded into the summary, so
   * the summary is rewritten every few turns rather than on every message.
   */
  summaryBatch: number;
}

export function chatMemoryConfig(): ChatMemoryConfig {
  return {
    historyMessageLimit: intSetting("CHAT_HISTORY_MESSAGE_LIMIT", 30, 2, 200),
    summaryBatch: intSetting("CHAT_SUMMARY_BATCH", 10, 2, 100),
  };
}

export interface ChatAiConfig {
  vertexProject: string | undefined;
  vertexLocation: string;
  chatModel: string | undefined;
  fallbackModel: string | undefined;
  guardrailModel: string | undefined;
}

/**
 * AI settings for the Phase 7 assistant. Read on demand rather than at startup: the rest of the
 * API must keep working when Vertex AI is not configured, and /api/chat then answers 503.
 * Google credentials come from Application Default Credentials (GOOGLE_APPLICATION_CREDENTIALS
 * or `gcloud auth application-default login`), never from this file or the app.
 */
export function chatAiConfig(): ChatAiConfig {
  const optional = (name: string) => process.env[name]?.trim() || undefined;
  return {
    vertexProject: optional("GOOGLE_VERTEX_PROJECT"),
    vertexLocation: optional("GOOGLE_VERTEX_LOCATION") ?? "global",
    chatModel: optional("CHAT_MODEL"),
    fallbackModel: optional("CHAT_FALLBACK_MODEL"),
    guardrailModel: optional("GUARDRAIL_MODEL"),
  };
}
