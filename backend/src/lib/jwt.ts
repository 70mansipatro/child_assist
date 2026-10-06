import { randomUUID } from "node:crypto";
import jwt, { type SignOptions } from "jsonwebtoken";
import { env } from "../config/env";

const ALGORITHM = "HS256";

export interface AccessTokenClaims {
  /** User ID. */
  sub: string;
  /** Unique token ID, so individual tokens can be revoked later if needed. */
  jti: string;
}

const signOptions: SignOptions = {
  algorithm: ALGORITHM,
  expiresIn: env.jwtExpiresIn as SignOptions["expiresIn"],
};

// Validate JWT_EXPIRES_IN at startup: jsonwebtoken throws on an unparseable timespan.
jwt.sign({}, env.jwtSecret, signOptions);

/** Signs an access token. The payload holds only the user ID and a token ID, no personal data. */
export function signAccessToken(userId: string): string {
  return jwt.sign({}, env.jwtSecret, { ...signOptions, subject: userId, jwtid: randomUUID() });
}

/** Verifies signature, algorithm and expiry. Throws if the token is invalid. */
export function verifyAccessToken(token: string): AccessTokenClaims {
  const payload = jwt.verify(token, env.jwtSecret, { algorithms: [ALGORITHM] });
  if (typeof payload === "string" || typeof payload.sub !== "string" || !payload.sub) {
    throw new jwt.JsonWebTokenError("Token is missing a subject");
  }
  return { sub: payload.sub, jti: payload.jti ?? "" };
}
