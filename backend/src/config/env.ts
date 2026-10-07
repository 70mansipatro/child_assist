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
