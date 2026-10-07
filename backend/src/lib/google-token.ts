import { OAuth2Client } from "google-auth-library";
import { googleWebClientId } from "../config/env";
import { HttpError } from "./http-error";

// The two issuer spellings Google uses in ID tokens.
const GOOGLE_ISSUERS = ["accounts.google.com", "https://accounts.google.com"];

/** Identity taken only from a Google ID token whose signature, issuer, audience and expiry checked out. */
export interface VerifiedGoogleIdentity {
  /** Google's stable account ID (`sub`). Unlike the email, it never changes or gets reassigned. */
  subject: string;
  /** Lower-cased, and only present when Google says the address is verified. */
  email: string;
  name: string;
}

/** Maps a key ID (`kid`) to a PEM public key or certificate. */
export type GoogleSigningKeys = Record<string, string>;

const client = new OAuth2Client();

// Google's published signing certificates; the library caches them per their Cache-Control.
const googlePublishedKeys = async (): Promise<GoogleSigningKeys> =>
  (await client.getFederatedSignonCertsAsync()).certs as GoogleSigningKeys;

let signingKeysSource = googlePublishedKeys;

/** Lets tests sign tokens with their own key. `null` restores Google's published keys. */
export function setGoogleSigningKeysSource(source: (() => Promise<GoogleSigningKeys>) | null): void {
  signingKeysSource = source ?? googlePublishedKeys;
}

export const GOOGLE_AUTH_FAILED = "Google authentication failed.";

/**
 * Verifies a Google ID token: signature against Google's keys, issuer, audience (our web/server
 * OAuth client ID) and expiry. Throws a 401 HttpError for any bad token, and a 503 when the server
 * has no client ID configured. The token itself is never logged: the library's error messages
 * contain it, so they are discarded.
 */
export async function verifyGoogleIdToken(idToken: string): Promise<VerifiedGoogleIdentity> {
  const audience = googleWebClientId();
  if (!audience) {
    throw new HttpError(
      503,
      "Google Sign-In is not configured correctly. Please try again later.",
      "GOOGLE_SSO_UNAVAILABLE",
    );
  }

  let keys: GoogleSigningKeys;
  try {
    keys = await signingKeysSource();
  } catch {
    throw new HttpError(503, "Google Sign-In is temporarily unavailable. Please try again later.", "GOOGLE_SSO_UNAVAILABLE");
  }

  let payload;
  try {
    const ticket = await client.verifySignedJwtWithCertsAsync(idToken, keys, audience, GOOGLE_ISSUERS);
    payload = ticket.getPayload();
  } catch {
    throw new HttpError(401, GOOGLE_AUTH_FAILED, "GOOGLE_AUTH_FAILED");
  }

  // An unverified address could belong to someone else, so it is never used to name an account.
  const email = payload?.email_verified === true ? payload.email?.trim().toLowerCase() : undefined;
  if (!payload?.sub || !email) {
    throw new HttpError(401, GOOGLE_AUTH_FAILED, "GOOGLE_AUTH_FAILED");
  }

  const name = (payload.name?.trim() || payload.given_name?.trim() || email.split("@")[0]).slice(0, 100);
  return { subject: payload.sub, email, name };
}
