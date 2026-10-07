import type { Request, Response } from "express";
import { getAuth } from "../../middleware/auth.middleware";
import * as authService from "./auth.service";
import {
  googleLoginSchema,
  loginSchema,
  registerSchema,
  resendVerificationSchema,
  verifyEmailSchema,
} from "./auth.validation";

// The same answer whether the email was new, unverified or already taken; no session or user data.
export async function register(req: Request, res: Response): Promise<void> {
  const input = registerSchema.parse(req.body);
  await authService.register(input);
  res.status(201).json({ requiresEmailVerification: true, message: "Verification code sent to your email." });
}

export async function verifyEmail(req: Request, res: Response): Promise<void> {
  const input = verifyEmailSchema.parse(req.body);
  await authService.verifyEmail(input);
  res.status(200).json({ verified: true, message: "Email verified successfully." });
}

export async function resendVerification(req: Request, res: Response): Promise<void> {
  const input = resendVerificationSchema.parse(req.body);
  await authService.resendVerification(input);
  res.status(200).json({ message: "If verification is required, a new code has been sent." });
}

export async function login(req: Request, res: Response): Promise<void> {
  const input = loginSchema.parse(req.body);
  const result = await authService.login(input);
  if ("requiresEmailVerification" in result) {
    res.status(403).json({
      requiresEmailVerification: true,
      code: "EMAIL_NOT_VERIFIED",
      message: "Please verify your email before logging in.",
    });
    return;
  }
  res.status(200).json({ message: "Login successful", user: result.user, token: result.token });
}

export async function google(req: Request, res: Response): Promise<void> {
  const input = googleLoginSchema.parse(req.body);
  const { user, token } = await authService.googleLogin(input);
  res.status(200).json({ message: "Login successful", user, token });
}

export async function me(req: Request, res: Response): Promise<void> {
  const user = await authService.getUserById(getAuth(req).userId);
  res.status(200).json({ user });
}

/**
 * JWTs are stateless: the server keeps no session, so this does NOT invalidate the token.
 * The client must delete its stored token. Server-side revocation can be added later by
 * recording getAuth(req).tokenId in a denylist and checking it in requireAuth.
 */
export function logout(_req: Request, res: Response): void {
  res.status(200).json({ message: "Logout successful" });
}
