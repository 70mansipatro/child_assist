import type { Request, Response } from "express";
import { getAuth } from "../../middleware/auth.middleware";
import * as authService from "./auth.service";
import { loginSchema, registerSchema } from "./auth.validation";

export async function register(req: Request, res: Response): Promise<void> {
  const input = registerSchema.parse(req.body);
  const { user, token } = await authService.register(input);
  res.status(201).json({ message: "Registration successful", user, token });
}

export async function login(req: Request, res: Response): Promise<void> {
  const input = loginSchema.parse(req.body);
  const { user, token } = await authService.login(input);
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
