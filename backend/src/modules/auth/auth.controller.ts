import type { Request, Response } from "express";
import { getAuth } from "../../middleware/auth.middleware";
import * as authService from "./auth.service";
import * as passwordResetService from "./password-reset.service";
import {
  forgotPasswordSchema,
  googleLoginSchema,
  loginSchema,
  registerSchema,
  resendResetCodeSchema,
  resendVerificationSchema,
  resetPasswordSchema,
  verifyEmailSchema,
  verifyResetCodeSchema,
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

// The same answer for every email (registered, unknown or Google-only): never reveals an account.
const RESET_REQUESTED = "If an account exists for this email, a password reset code has been sent.";

export async function forgotPassword(req: Request, res: Response): Promise<void> {
  const input = forgotPasswordSchema.parse(req.body);
  await passwordResetService.requestPasswordReset(input.email);
  res.status(200).json({ message: RESET_REQUESTED });
}

export async function resendResetCode(req: Request, res: Response): Promise<void> {
  const input = resendResetCodeSchema.parse(req.body);
  await passwordResetService.requestPasswordReset(input.email);
  res.status(200).json({ message: RESET_REQUESTED });
}

// Returns a single-use reset token, not a session: no JWT and no user data.
export async function verifyResetCode(req: Request, res: Response): Promise<void> {
  const input = verifyResetCodeSchema.parse(req.body);
  const resetToken = await passwordResetService.verifyResetCode(input.email, input.code);
  res.status(200).json({
    message: "Code verified. You can now create a new password.",
    resetToken,
    expiresInSeconds: passwordResetService.RESET_TOKEN_TTL_MINUTES * 60,
  });
}

// Does not sign in: the user logs in with the new password afterwards.
export async function resetPassword(req: Request, res: Response): Promise<void> {
  const input = resetPasswordSchema.parse(req.body);
  await passwordResetService.resetPassword(input.resetToken, input.newPassword);
  res.status(200).json({ message: "Password reset successfully." });
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
