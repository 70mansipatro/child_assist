import type { NextFunction, Request, Response } from "express";

// Browsers (e.g. the Flutter web build) block cross-origin calls unless the API
// answers with CORS headers. Allowed origins come from CORS_ORIGINS (comma-separated);
// outside production, any localhost origin is also allowed since `flutter run -d chrome`
// picks a random port.

const allowedOrigins = new Set(
  (process.env.CORS_ORIGINS ?? "")
    .split(",")
    .map((o) => o.trim())
    .filter(Boolean),
);

const isProduction = process.env.NODE_ENV === "production";
const localhostPattern = /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/;

function isAllowed(origin: string): boolean {
  return allowedOrigins.has(origin) || (!isProduction && localhostPattern.test(origin));
}

export function corsMiddleware(req: Request, res: Response, next: NextFunction): void {
  const origin = req.headers.origin;

  if (origin && isAllowed(origin)) {
    res.setHeader("Access-Control-Allow-Origin", origin);
    res.setHeader("Vary", "Origin");
    res.setHeader("Access-Control-Allow-Methods", "GET,POST,PUT,PATCH,DELETE,OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization, Accept");
    res.setHeader("Access-Control-Max-Age", "600");
  }

  if (req.method === "OPTIONS") {
    res.sendStatus(204);
    return;
  }

  next();
}
