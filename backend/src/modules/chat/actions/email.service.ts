import { z } from "zod";
import { emailAvailable, emailLayout, sendEmail, type EmailMessage } from "../../../lib/email";

// Emails the user asked Child Assist to send, after they confirmed them in the app. Uses the
// backend's existing SMTP settings; the credentials never reach the app or Gemini, and the log
// only ever names an outcome, never the recipient, the content or a setting's value.

export const MAX_SUBJECT_LENGTH = 200;
export const MAX_EMAIL_BODY_LENGTH = 10_000;

const emailSchema = z.email();

/** Whether [address] is a well-formed email address. It is never "fixed up" silently. */
export function isValidEmail(address: string): boolean {
  return address.length <= 254 && !/\s/.test(address) && emailSchema.safeParse(address).success;
}

/** One line of text: CR/LF in a subject could inject extra mail headers. */
export function isSafeSubject(subject: string): boolean {
  return subject.length > 0 && subject.length <= MAX_SUBJECT_LENGTH && !/[\r\n\0]/.test(subject);
}

/** Whether email can be sent at all (SMTP configured, or a test sender installed). */
export const emailConfigured = emailAvailable;

export interface UserEmail {
  to: string;
  toName: string | null;
  subject: string;
  message: string;
  /** The Child Assist user who asked for it, named in the footer so the recipient knows. */
  senderName: string | null;
  senderEmail: string | null;
}

function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

export function buildUserEmail(email: UserEmail): EmailMessage {
  const sender = email.senderName?.trim() || email.senderEmail || "A Child Assist user";
  const footer = `Sent by ${sender} using Child Assist.`;
  const text = `${email.message}\n\n--\n${footer}`;
  const paragraphs = escapeHtml(email.message)
    .split(/\n{2,}/)
    .map((p) => `        <p style="margin:0 0 12px;font-size:15px;line-height:1.5;">${p.replace(/\n/g, "<br>")}</p>`)
    .join("\n");
  const html = emailLayout(`${paragraphs}
        <p style="margin:16px 0 0;font-size:12px;color:#6b6880;">${escapeHtml(footer)}</p>`);
  const to = email.toName ? `"${email.toName.replace(/["\\\r\n]/g, "")}" <${email.to}>` : email.to;
  return {
    to,
    subject: email.subject,
    text,
    html,
    ...(email.senderEmail && isValidEmail(email.senderEmail) ? { replyTo: email.senderEmail } : {}),
  };
}

/**
 * Sends one confirmed email. Validates again right before sending (never trusting what was
 * stored) and reports only whether the SMTP server accepted it.
 */
export async function sendUserEmail(email: UserEmail): Promise<{ delivered: boolean }> {
  if (!isValidEmail(email.to) || !isSafeSubject(email.subject)) return { delivered: false };
  if (email.message.trim().length === 0 || email.message.length > MAX_EMAIL_BODY_LENGTH) return { delivered: false };
  try {
    await sendEmail(buildUserEmail(email));
    return { delivered: true };
  } catch {
    // lib/email has already logged the SMTP error code (never the address or the content).
    return { delivered: false };
  }
}
