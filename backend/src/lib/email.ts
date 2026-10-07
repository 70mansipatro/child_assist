import nodemailer, { type Transporter } from "nodemailer";
import { smtpConfig, type SmtpConfig } from "../config/env";
import { HttpError } from "./http-error";

export interface EmailMessage {
  to: string;
  subject: string;
  text: string;
  html: string;
}

export type EmailSender = (message: EmailMessage) => Promise<void>;

const EMAIL_UNAVAILABLE = "Email verification is temporarily unavailable. Please try again later.";

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
