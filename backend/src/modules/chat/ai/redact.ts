// Removes credentials from text before it is stored in chat history or sent to Gemini.
// A user may paste a password or token into the chat by mistake; it must not be kept.

const REDACTED = "[REDACTED]";

const SECRET_PATTERNS: ReadonlyArray<[RegExp, string]> = [
  // PEM private keys (e.g. a pasted service-account key).
  [/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g, REDACTED],
  // JSON Web Tokens.
  [/\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}/g, REDACTED],
  // Bearer tokens in a pasted header.
  [/\bBearer\s+[A-Za-z0-9._~+/-]{16,}=*/gi, `Bearer ${REDACTED}`],
  // Google API keys.
  [/\bAIza[0-9A-Za-z_-]{35}\b/g, REDACTED],
  // Common secret-key formats (sk-..., ghp_..., xox...-).
  [/\b(?:sk|rk|pk)-[A-Za-z0-9_-]{20,}\b/g, REDACTED],
  [/\bgh[pousr]_[A-Za-z0-9]{30,}\b/g, REDACTED],
  [/\bxox[abprs]-[A-Za-z0-9-]{10,}\b/g, REDACTED],
  // "password is hunter2", "pin: 1234", "api key = abc".
  [
    /\b(password|passwd|pwd|passcode|pin|api[ _-]?key|secret|access[ _-]?token|auth[ _-]?token)(\s*(?:is|=|:)\s*)("[^"]*"|'[^']*'|\S+)/gi,
    `$1$2${REDACTED}`,
  ],
];

export function redactSecrets(text: string): string {
  let result = text;
  for (const [pattern, replacement] of SECRET_PATTERNS) {
    result = result.replace(pattern, replacement);
  }
  // The server's own signing secret must never appear anywhere, whatever its format.
  const jwtSecret = process.env.JWT_SECRET;
  if (jwtSecret && jwtSecret.length >= 8 && result.includes(jwtSecret)) {
    result = result.split(jwtSecret).join(REDACTED);
  }
  return result;
}
