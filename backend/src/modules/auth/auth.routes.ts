import { Router } from "express";
import { requireAuth } from "../../middleware/auth.middleware";
import * as authController from "./auth.controller";

export const authRouter = Router();

authRouter.post("/register", authController.register);
authRouter.post("/verify-email", authController.verifyEmail);
authRouter.post("/resend-verification", authController.resendVerification);
authRouter.post("/login", authController.login);
authRouter.post("/google", authController.google);
authRouter.get("/me", requireAuth, authController.me);
authRouter.post("/logout", requireAuth, authController.logout);
