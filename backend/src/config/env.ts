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
