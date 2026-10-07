import type { NextFunction, Request, Response } from "express";
import { ZodError } from "zod";
import { HttpError } from "../lib/http-error";

export function notFoundHandler(_req: Request, res: Response): void {
  res.status(404).json({ message: "Not found" });
}

export function errorHandler(err: unknown, _req: Request, res: Response, _next: NextFunction): void {
  if (err instanceof HttpError) {
    res.status(err.status).json(err.code ? { message: err.message, code: err.code } : { message: err.message });
    return;
  }

  if (err instanceof ZodError) {
    res.status(400).json({
      message: "Validation failed",
      errors: err.issues.map((issue) => ({
        field: issue.path.join(".") || null,
        message: issue.message,
      })),
    });
    return;
  }

  // Malformed/oversized body from express.json(). Not logged: the raw body may contain a password.
  if (isBodyParserError(err)) {
    res.status(err.status === 413 ? 413 : 400).json({ message: "Invalid request body" });
    return;
  }

  // Log only name/message/stack, never the whole error object, which may carry request data.
  const e = err instanceof Error ? err : new Error(String(err));
  console.error(`Unhandled error: ${e.name}: ${e.message}\n${e.stack ?? ""}`);
  res.status(500).json({ message: "Internal server error" });
}

function isBodyParserError(err: unknown): err is { status: number; type: string } {
  return (
    typeof err === "object" &&
    err !== null &&
    typeof (err as { type?: unknown }).type === "string" &&
    typeof (err as { status?: unknown }).status === "number"
  );
}
