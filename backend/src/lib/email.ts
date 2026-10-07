import nodemailer, { type Transporter } from "nodemailer";
import { smtpConfig, type SmtpConfig } from "../config/env";
import { HttpError } from "./http-error";

export interface EmailMessage {
  to: string;
  subject: string;
  text: string;
  html: string;
  /** Where the recipient's replies go, e.g. the Child Assist user who sent it. */
  replyTo?: string;
}

export type EmailSender = (message: EmailMessage) => Promise<void>;

// Shared by every flow that emails a code (verification and password reset).
const EMAIL_UNAVAILABLE = "Email is temporarily unavailable. Please try again later.";

let senderOverride: EmailSender | null = null;

/** Lets tests capture outgoing email instead of sending it. `null` restores SMTP. */
export function setEmailSender(sender: EmailSender | null): void {
  senderOverride = sender;
}

let cached: { key: string; transporter: Transporter } | undefined;

function transporterFor(config: SmtpConfig): Transporter {
  const key = JSON.stringify(config);
  if (cached?.key !== key) {
    cached = {
      key,
      transporter: nodemailer.createTransport({
        host: config.host,
        port: config.port,
        secure: config.secure,
        // Port 587 must upgrade to TLS: never send the password or the code in clear text.
        requireTLS: !config.secure,
        auth: config.user ? { user: config.user, pass: config.password } : undefined,
        connectionTimeout: 10_000,
        greetingTimeout: 10_000,
        socketTimeout: 20_000,
      }),
    };
  }
  return cached.transporter;
}

/** Whether email can be sent at all: SMTP is configured (or a test sender is installed). */
export function emailAvailable(): boolean {
  return senderOverride !== null || !smtpConfig().error;
}

/**
 * Throws a 503 unless email can be sent, so callers can refuse before changing anything.
 * The log names the missing setting, never a value.
 */
export function assertEmailConfigured(): void {
  if (senderOverride) return;
  const { error } = smtpConfig();
  if (error) {
    console.error(`Email is not configured: ${error}. Check your backend/.env file.`);
    throw new HttpError(503, EMAIL_UNAVAILABLE, "EMAIL_UNAVAILABLE");
  }
}

/** Sends one email. Throws a 503 HttpError if it could not be handed to the SMTP server. */
export async function sendEmail(message: EmailMessage): Promise<void> {
  if (senderOverride) return senderOverride(message);

  assertEmailConfigured();
  const config = smtpConfig().config!;
  try {
    await transporterFor(config).sendMail({ from: config.from, ...message });
  } catch (err) {
    // Only the error's code: SMTP replies can echo the recipient or message content.
    const e = err as { code?: unknown; responseCode?: unknown };
    console.error(`Email delivery failed (code=${String(e.code ?? "unknown")}, smtp=${String(e.responseCode ?? "-")})`);
    throw new HttpError(503, "We couldn't send the verification email. Please try again later.", "EMAIL_DELIVERY_FAILED");
  }
}

/** The verification code email. Contains only the code: no account details, IDs or tokens. */
export function verificationEmail(to: string, code: string, ttlMinutes: number): EmailMessage {
  const text = [
    "Your Child Assist verification code is:",
    "",
    code,
    "",
    `This code expires in ${ttlMinutes} minutes.`,
    "",
    "If you did not create this account, you can ignore this email.",
  ].join("\n");

  // `code` is always 6 digits, so nothing here needs HTML escaping.
  const html = `<!doctype html>
<html>
  <body style="margin:0;padding:24px;background:#f4f3fb;font-family:Arial,Helvetica,sans-serif;color:#1f1b2e;">
    <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:480px;margin:0 auto;background:#ffffff;border-radius:16px;overflow:hidden;">
      <tr><td style="background:linear-gradient(135deg,#6d5dfc,#4f46e5);background-color:#5b4ff0;padding:20px 24px;color:#ffffff;font-size:20px;font-weight:bold;">Child Assist</td></tr>
      <tr><td style="padding:24px;">
        <p style="margin:0 0 12px;font-size:15px;">Your Child Assist verification code is:</p>
        <p style="margin:0 0 16px;font-size:32px;font-weight:bold;letter-spacing:8px;color:#4f46e5;">${code}</p>
        <p style="margin:0 0 12px;font-size:14px;">This code expires in ${ttlMinutes} minutes.</p>
        <p style="margin:0;font-size:13px;color:#6b6880;">If you did not create this account, you can ignore this email.</p>
      </td></tr>
    </table>
  </body>
</html>`;

  return { to, subject: "Verify your Child Assist account", text, html };
}

/** Shared frame for the app's emails: a header bar and a white card. `body` must be safe HTML. */
export function emailLayout(body: string): string {
  return `<!doctype html>
<html>
  <body style="margin:0;padding:24px;background:#f4f3fb;font-family:Arial,Helvetica,sans-serif;color:#1f1b2e;">
    <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:480px;margin:0 auto;background:#ffffff;border-radius:16px;overflow:hidden;">
      <tr><td style="background:linear-gradient(135deg,#6d5dfc,#4f46e5);background-color:#5b4ff0;padding:20px 24px;color:#ffffff;font-size:20px;font-weight:bold;">Child Assist</td></tr>
      <tr><td style="padding:24px;">
${body}
      </td></tr>
    </table>
  </body>
</html>`;
}

/** The password reset code email. Contains only the code: no account details, IDs or tokens. */
export function passwordResetEmail(to: string, code: string, ttlMinutes: number): EmailMessage {
  const text = [
    "Child Assist",
    "",
    "Password Reset",
    "",
    "We received a request to reset your Child Assist password.",
    "",
    "Your verification code is:",
    "",
    code,
    "",
    `This code expires in ${ttlMinutes} minutes.`,
    "",
    "If you did not request this, you can safely ignore this email. Your password will not change.",
    "",
    "Child Assist",
  ].join("\n");

  // `code` is always 6 digits, so nothing here needs HTML escaping.
  const html = emailLayout(`        <p style="margin:0 0 8px;font-size:18px;font-weight:bold;">Password Reset</p>
        <p style="margin:0 0 12px;font-size:15px;">We received a request to reset your Child Assist password.</p>
        <p style="margin:0 0 12px;font-size:15px;">Your verification code is:</p>
        <p style="margin:0 0 16px;font-size:32px;font-weight:bold;letter-spacing:8px;color:#4f46e5;">${code}</p>
        <p style="margin:0 0 12px;font-size:14px;">This code expires in ${ttlMinutes} minutes.</p>
        <p style="margin:0;font-size:13px;color:#6b6880;">If you did not request this, you can safely ignore this email. Your password will not change.</p>`);

  return { to, subject: "Reset your Child Assist password", text, html };
}

/**
 * Sent instead of a code when "Forgot password" is used for an account that signs in with Google
 * and has no password. Only the address owner learns this, never the API caller.
 */
export function googleAccountResetEmail(to: string): EmailMessage {
  const text = [
    "Child Assist",
    "",
    "Password Reset",
    "",
    "We received a request to reset your Child Assist password, but your account signs in with Google and has no password to reset.",
    "",
    'Open Child Assist and tap "Continue with Google" to sign in.',
    "",
    "If you did not request this, you can safely ignore this email.",
    "",
    "Child Assist",
  ].join("\n");

  const html = emailLayout(`        <p style="margin:0 0 8px;font-size:18px;font-weight:bold;">Password Reset</p>
        <p style="margin:0 0 12px;font-size:15px;">We received a request to reset your Child Assist password, but your account signs in with Google and has no password to reset.</p>
        <p style="margin:0 0 12px;font-size:15px;">Open Child Assist and tap <b>Continue with Google</b> to sign in.</p>
        <p style="margin:0;font-size:13px;color:#6b6880;">If you did not request this, you can safely ignore this email.</p>`);

  return { to, subject: "Your Child Assist account uses Google Sign-In", text, html };
}
