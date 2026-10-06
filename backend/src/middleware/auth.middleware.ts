import type { NextFunction, Request, Response } from "express";
import { verifyAccessToken, type AccessTokenClaims } from "../lib/jwt";
import { HttpError } from "../lib/http-error";

export interface AuthContext {
  userId: string;
  tokenId: string;
}

declare global {
  namespace Express {
    interface Request {
      /** Set by requireAuth once the bearer token has been verified. */
      auth?: AuthContext;
    }
  }
}

/**
 * Requires a valid `Authorization: Bearer <token>` header.
 * On success attaches `req.auth`; otherwise responds 401.
 */
export function requireAuth(req: Request, _res: Response, next: NextFunction): void {
  const match = req.headers.authorization?.match(/^Bearer\s+(\S+)$/i);
  if (!match) {
    throw new HttpError(401, "Authentication required");
  }

  let claims: AccessTokenClaims;
  try {
    claims = verifyAccessToken(match[1]);
  } catch {
    // Covers bad signatures, malformed tokens and expiry alike.
    throw new HttpError(401, "Invalid or expired token");
  }

  // Token revocation (e.g. a denylist keyed by claims.jti) can be checked here later.
  req.auth = { userId: claims.sub, tokenId: claims.jti };
  next();
}

/** Returns the authenticated context; only valid on routes behind requireAuth. */
export function getAuth(req: Request): AuthContext {
  if (!req.auth) {
    throw new HttpError(401, "Authentication required");
  }
  return req.auth;
}
