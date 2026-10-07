import { Router } from "express";
import { requireAuth } from "../../middleware/auth.middleware";
import { rateLimit } from "../../middleware/rate-limit.middleware";
import * as authController from "./auth.controller";

export const authRouter = Router();

authRouter.post("/register", authController.register);
authRouter.post("/verify-email", authController.verifyEmail);
authRouter.post("/resend-verification", authController.resendVerification);
authRouter.post("/login", authController.login);
authRouter.post("/google", authController.google);

// Password reset. Per-IP limits on top of the per-account cooldown and caps in the service.
const WINDOW_MS = 15 * 60_000;
const resetRequestLimit = rateLimit({ bucket: "reset-request", max: 10, windowMs: WINDOW_MS });
authRouter.post("/forgot-password", resetRequestLimit, authController.forgotPassword);
authRouter.post("/resend-reset-code", resetRequestLimit, authController.resendResetCode);
authRouter.post(
  "/verify-reset-code",
  rateLimit({ bucket: "reset-verify", max: 20, windowMs: WINDOW_MS }),
  authController.verifyResetCode,
);
authRouter.post(
  "/reset-password",
  rateLimit({ bucket: "reset-password", max: 10, windowMs: WINDOW_MS }),
  authController.resetPassword,
);
authRouter.get("/me", requireAuth, authController.me);
authRouter.post("/logout", requireAuth, authController.logout);
