import type { NextFunction, Request, Response } from "express";
import { HttpError } from "../lib/http-error";

interface Window {
  count: number;
  resetAt: number;
}

// Per process and in memory: enough for a single server. Several instances would each keep their
// own counts, so a shared store (e.g. Redis) is needed before scaling out.
const windows = new Map<string, Window>();

// Bounds memory if many addresses send requests: expired windows are dropped once it grows.
const PRUNE_ABOVE = 10_000;

/**
 * Allows [max] requests per client IP per [windowMs] for the routes it guards, then answers 429.
 * The limit depends only on the caller, never on the account named in the body, so it reveals
 * nothing about which emails are registered. Routes sharing a [bucket] share one count.
 */
export function rateLimit({ bucket, max, windowMs }: { bucket: string; max: number; windowMs: number }) {
  return (req: Request, _res: Response, next: NextFunction): void => {
    const now = Date.now();
    if (windows.size > PRUNE_ABOVE) {
      for (const [key, w] of windows) if (w.resetAt <= now) windows.delete(key);
    }

    const key = `${bucket}:${req.ip ?? "unknown"}`;
    let w = windows.get(key);
    if (!w || w.resetAt <= now) {
      w = { count: 0, resetAt: now + windowMs };
      windows.set(key, w);
    }
    w.count++;
    if (w.count > max) {
      throw new HttpError(429, "Too many requests. Please wait a few minutes and try again.", "RATE_LIMITED");
    }
    next();
  };
}

/** Forgets every count. For tests. */
export function resetRateLimits(): void {
  windows.clear();
}
