import "dotenv/config";
import express, { type Express, type Request, type Response } from "express";
import { authRouter } from "./modules/auth/auth.routes";
import { profileRouter } from "./modules/profile/profile.routes";
import { permissionsRouter } from "./modules/permissions/permissions.routes";
import { errorHandler, notFoundHandler } from "./middleware/error.middleware";
import { corsMiddleware } from "./middleware/cors.middleware";

// Builds the Express app without listening, so tests can start it on a random port.
export function createApp(): Express {
  const app = express();

  app.disable("x-powered-by");
  app.use(corsMiddleware);
  app.use(express.json({ limit: "100kb" }));

  app.get("/health", (_req: Request, res: Response) => {
    res.status(200).json({
      status: "ok",
      message: "Child Assist backend is running",
    });
  });

  app.use("/api/auth", authRouter);
  app.use("/api/profile", profileRouter);
  app.use("/api/permissions", permissionsRouter);

  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}
