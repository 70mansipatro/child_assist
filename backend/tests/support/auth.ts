// Shared by the integration tests: outgoing email is captured here instead of being sent, and
// test accounts are created through the real register -> verify -> login flow.
import assert from "node:assert/strict";
import { setEmailSender, type EmailMessage } from "../../src/lib/email";

/** Every email the app "sent" in this test process, oldest first. */
export const sentEmails: EmailMessage[] = [];

setEmailSender(async (message) => {
  sentEmails.push(message);
});

export const TEST_PASSWORD = "password123";

export type Call = (
  method: string,
  path: string,
  options?: { token?: string; body?: unknown },
) => Promise<{ status: number; json: any; raw: string }>;

export function emailsTo(email: string): EmailMessage[] {
  return sentEmails.filter((m) => m.to === email);
}

/** The code in the most recent verification email to [email]. */
export function latestCodeFor(email: string): string {
  const message = emailsTo(email).at(-1);
  assert.ok(message, `no email was sent to ${email}`);
  const code = message.text.match(/^(\d{6})$/m)?.[1];
  assert.ok(code, "the email has no 6-digit code");
  return code;
}

/** Registers, verifies with the emailed code and logs in. */
export async function registerVerifiedUser(
  call: Call,
  name: string,
  email: string,
  password = TEST_PASSWORD,
): Promise<{ id: string; email: string; token: string }> {
  const reg = await call("POST", "/api/auth/register", { body: { name, email, password } });
  assert.equal(reg.status, 201, reg.raw);
  const verify = await call("POST", "/api/auth/verify-email", { body: { email, code: latestCodeFor(email) } });
  assert.equal(verify.status, 200, verify.raw);
  const login = await call("POST", "/api/auth/login", { body: { email, password } });
  assert.equal(login.status, 200, login.raw);
  return { id: login.json.user.id, email, token: login.json.token };
}
