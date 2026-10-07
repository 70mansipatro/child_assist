import type { PermissionType } from "../../../../generated/prisma/client";
import type { UserZone } from "../../../lib/local-dates";

// Results every tool returns to Gemini. Failures are structured so the model can explain them
// in friendly words ("Please allow location access in Settings") instead of guessing.

export type ToolErrorCode =
  | "PERMISSION_REQUIRED"
  | "CURRENT_LOCATION_UNAVAILABLE"
  | "DEVICE_DATA_UNAVAILABLE"
  | "DOCUMENT_NOT_FOUND"
  | "DOCUMENT_UNAVAILABLE"
  | "TEXT_EXTRACTION_UNAVAILABLE"
  | "WEB_SEARCH_NOT_CONFIGURED"
  | "CONTACTS_NOT_CONFIGURED"
  | "ACTION_NOT_CONFIGURED"
  | "INVALID_ARGUMENTS"
  | "TOOL_FAILED";

export type ToolSuccess<T> = { success: true; data: T };
export type ToolFailure = {
  success: false;
  code: ToolErrorCode;
  message: string;
  permission?: PermissionType;
};
export type ToolResult<T> = ToolSuccess<T> | ToolFailure;

export function ok<T>(data: T): ToolSuccess<T> {
  return { success: true, data };
}

export function fail(code: ToolErrorCode, message: string, extra: { permission?: PermissionType } = {}): ToolFailure {
  return { success: false, code, message, ...extra };
}

/** A side-effect action the assistant prepared; nothing happens until the user confirms it. */
export interface PendingActionView {
  id: string;
  toolName: string;
  /** Built by the backend, not the model, so the confirmation text cannot be manipulated. */
  summary: string;
  expiresAt: string;
}

/**
 * Everything a tool knows about the caller. Built by the backend from the verified JWT: tools
 * have no userId argument, so the model can never choose whose data a tool reads.
 */
export interface ToolContext {
  readonly userId: string;
  readonly conversationId: string;
  /** The device's time zone, so "today" and "5 October" mean the user's local days. */
  readonly zone: UserZone;
  /** Collects what happened during one chat turn, for the response and for rollback. */
  readonly run: {
    toolsUsed: string[];
    pendingActions: PendingActionView[];
    events: ToolEvent[];
  };
}

/** What the app shows for a tool: a friendly category, never the internal tool name. */
export type ToolEventKind =
  | "profile"
  | "permissions"
  | "location_history"
  | "current_location"
  | "photos"
  | "documents"
  | "document_text"
  | "web_search"
  | "contacts"
  | "send_action";

export type ToolEventStatus =
  | "success"
  /** The app should search the phone itself (photos/documents never leave the device). */
  | "device_lookup"
  | "permission_required"
  | "confirmation_required"
  | "unavailable"
  | "not_configured"
  | "invalid"
  | "failed";

/** A UI-safe summary of one tool call, returned to the app alongside the reply. */
export interface ToolEvent {
  kind: ToolEventKind;
  status: ToolEventStatus;
  permission?: PermissionType;
  /** Only the signed-in user's own data, shaped for display. */
  data?: Record<string, unknown>;
}
