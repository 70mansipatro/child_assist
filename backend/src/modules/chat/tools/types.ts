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
  | "PHOTO_NOT_FOUND"
  | "NO_PHOTO_SELECTED"
  | "PHOTO_SEARCH_REQUIRED"
  | "WEB_SEARCH_NOT_CONFIGURED"
  | "ACTION_NOT_CONFIGURED"
  | "INVALID_RECIPIENT"
  | "NOTHING_TO_SHARE"
  | "NOT_SUPPORTED"
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

/**
 * A side-effect action the assistant prepared; nothing happens until the user confirms it.
 * Everything here is written by the backend, not the model, so the confirmation the user sees
 * cannot be manipulated, and it is exactly what will be sent.
 */
export interface PendingActionView {
  id: string;
  /** The tool that prepared it, e.g. "prepare_email". */
  toolName: string;
  type: "SEND_EMAIL" | "SEND_WHATSAPP" | "SHARE_LOCATION" | "SHARE_TRAVEL_HISTORY" | "SHARE_DOCUMENT" | "SHARE_CONTACT" | "SHARE_PHOTO";
  channel: "EMAIL" | "WHATSAPP";
  status: "PENDING" | "CONFIRMED" | "CANCELLED" | "COMPLETED" | "FAILED" | "EXPIRED";
  summary: string;
  /**
   * The contact name to look up on the phone while [recipientAddress] is null. The app searches
   * its own contacts and sends back only the one address the user picks.
   */
  contactQuery: string | null;
  /** Which contact field the app must resolve: an email address or a phone number. */
  recipientField: "email" | "phone";
  recipientName: string | null;
  recipientAddress: string | null;
  subject: string | null;
  message: string | null;
  /** The kind of sensitive data included, e.g. "Today's travel history (3 saved locations)". */
  dataSummary: string | null;
  /** For a document share: the document name to match among the documents on the phone. */
  documentQuery: string | null;
  /**
   * For a document share: the one document the user picked on the phone (the app's opaque id for
   * it, its file name and type). Null until picked; the action cannot be confirmed before that.
   */
  documentId: string | null;
  documentName: string | null;
  documentType: string | null;
  /**
   * For SHARE_CONTACT: the contact whose number is shared (not the recipient). While
   * [sharedContactPhone] is null the app looks [sharedContactQuery] up on the phone and the user
   * picks the contact and number; the message is then built from exactly that.
   */
  sharedContactQuery: string | null;
  sharedContactName: string | null;
  sharedContactPhone: string | null;
  /**
   * For SHARE_PHOTO: the server's opaque id of the photo (photo_...), one this user was shown in
   * this conversation. The phone resolves it in its own gallery; no path or URI ever leaves it.
   */
  photoId: string | null;
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
    /** The photo search opened this turn, and what the user asked about the photo, if anything. */
    photoSearch?: { requestId: string; question: string | null };
    /** A question about "this photo" asked in the same turn as a search: it is about the photo being found. */
    photoQuestion?: string;
    /**
     * The user asked for their latest / most recent photo: only a fresh search of the gallery
     * answers that, never a photo already shown in this chat.
     */
    recentPhoto?: boolean;
  };
}

/** What the app shows for a tool: a friendly category, never the internal tool name. */
export type ToolEventKind =
  | "profile"
  | "permissions"
  | "location_history"
  | "current_location"
  | "photos"
  /** Gemini vision looking at the one photo being talked about. */
  | "photo_analysis"
  /** Sharing a photo from this phone, after the user confirms on the card. */
  | "photo_share"
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
