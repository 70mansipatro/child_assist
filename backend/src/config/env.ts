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
