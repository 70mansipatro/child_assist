import {
  ChatMessageRole,
  PhotoRequestKind,
  PhotoRequestStatus,
  type PhotoRequest,
} from "../../../../generated/prisma/client";
import { HttpError } from "../../../lib/http-error";
import { prisma } from "../../../lib/prisma";
import { getChatModels } from "../ai/models";
import { addMessage, type MessageRecord } from "../chat.service";
import { guardReply } from "../guardrails/guardrails";
import type { ToolContext } from "../tools/types";
import { answerFromImage, detectImageType, MAX_IMAGE_BYTES, MIN_IMAGE_BYTES } from "./photo-answer";
import {
  findUserPhoto,
  MAX_PHOTOS_PER_SEARCH,
  newPhotoId,
  toPhotoView,
  type PhotoView,
  type PlaceEvidence,
} from "./photo-references";

// The assistant's requests to the phone about photos. Like document reads, nothing about the
// gallery reaches the server unless a request asks for it, and then only the minimum:
//
//   SEARCH:  the phone searches its own gallery (date, the user's saved places, file name) and
//            reports the photos it SHOWED (when taken, size, matched place). The server mints an
//            opaque id for each; the phone keeps the mapping to its gallery entry.
//   ANALYZE: the phone sends the ONE photo being talked about, scaled down, and Gemini vision
//            answers the question from the image. The image is never stored or logged; only the
//            answer is kept, as the assistant's chat message.
//
//   PENDING ──results/answer──▶ COMPLETED | FAILED      PENDING ──fail──▶ FAILED | CANCELLED
//   PENDING ──10 minutes──▶ EXPIRED
//
// Every request belongs to the user from the JWT and one conversation, and is answered once.

export const PHOTO_REQUEST_TTL_MS = 10 * 60 * 1000;

export interface PhotoRequestView {
  id: string;
  kind: PhotoRequestKind;
  status: PhotoRequestStatus;
  photoId: string | null;
  expiresAt: string;
}

function toView(r: PhotoRequest): PhotoRequestView {
  return { id: r.id, kind: r.kind, status: r.status, photoId: r.photoId, expiresAt: r.expiresAt.toISOString() };
}

export async function expireStalePhotoRequests(now = new Date()): Promise<void> {
  await prisma.photoRequest.updateMany({
    where: { status: PhotoRequestStatus.PENDING, expiresAt: { lte: now }, completedAt: null },
    data: { status: PhotoRequestStatus.EXPIRED, question: null },
  });
}

async function open(
  ctx: ToolContext,
  kind: PhotoRequestKind,
  extra: { photoId?: string; question?: string } = {},
): Promise<PhotoRequestView> {
  await expireStalePhotoRequests();
  const request = await prisma.photoRequest.create({
    data: {
      userId: ctx.userId,
      conversationId: ctx.conversationId,
      kind,
      photoId: extra.photoId ?? null,
      question: extra.question ?? null,
      expiresAt: new Date(Date.now() + PHOTO_REQUEST_TTL_MS),
    },
  });
  return toView(request);
}

/** Opens a request for the phone to search its gallery (chat turn). Reads nothing itself. */
export const preparePhotoSearch = (ctx: ToolContext) => open(ctx, PhotoRequestKind.SEARCH);

/** Opens a request for the phone to send the one photo [photoId] for a question (chat turn). */
export const preparePhotoAnalysis = (ctx: ToolContext, photoId: string, question: string) =>
  open(ctx, PhotoRequestKind.ANALYZE, { photoId, question });

export interface RequestScope {
  conversationId?: string;
}

/** The user's own request of [kind], or 404: someone else's looks exactly like a missing one. */
async function load(userId: string, id: string, kind: PhotoRequestKind, scope: RequestScope): Promise<PhotoRequest> {
  const request = await prisma.photoRequest.findFirst({
    where: { id, userId, kind, ...(scope.conversationId ? { conversationId: scope.conversationId } : {}) },
  });
  if (!request) throw new HttpError(404, "Request not found");
  return request;
}

/** Claims a PENDING request so it is answered (or failed) exactly once. */
async function claim(userId: string, id: string, kind: PhotoRequestKind, scope: RequestScope): Promise<PhotoRequest> {
  const request = await load(userId, id, kind, scope);
  const { count } = await prisma.photoRequest.updateMany({
    where: { id, userId, kind, status: PhotoRequestStatus.PENDING, completedAt: null, expiresAt: { gt: new Date() } },
    data: { completedAt: new Date() },
  });
  if (count === 1) return request;
  if (
    request.status === PhotoRequestStatus.EXPIRED ||
    (request.status === PhotoRequestStatus.PENDING && request.expiresAt <= new Date())
  ) {
    await expireStalePhotoRequests();
    throw new HttpError(410, "This request has expired. Please ask Child Assist again.", "REQUEST_EXPIRED");
  }
  throw new HttpError(409, "This request has already been handled.", "REQUEST_ALREADY_HANDLED");
}

async function finish(userId: string, id: string, status: PhotoRequestStatus): Promise<void> {
  await prisma.photoRequest.updateMany({ where: { id, userId }, data: { status, completedAt: new Date(), question: null } });
}

async function note(userId: string, conversationId: string, content: string): Promise<MessageRecord | null> {
  try {
    return await addMessage(userId, conversationId, { role: ChatMessageRole.CHAT_ASSISTANT, content });
  } catch {
    // The conversation may have been deleted meanwhile.
    return null;
  }
}

// ---------------------------------------------------------------------------------------------
// SEARCH

export type PhotoSearchOutcome = "found" | "none" | "permission_denied" | "failed";
/** Why nothing strong was found, so the user is told something useful (never a made-up photo). */
export type PhotoSearchReason = "no_visits" | "content_only" | "no_name_match";

export interface ShownPhoto {
  capturedAt: Date;
  width?: number;
  height?: number;
  place?: { name: string; evidence: PlaceEvidence };
}

export interface PhotoSearchReport {
  outcome: PhotoSearchOutcome;
  /** The photos the phone shows, strongest first (only for "found"). */
  photos: ShownPhoto[];
  /** How many strong matches there were in all (more than shown when capped). */
  total?: number;
  reason?: PhotoSearchReason;
  /** The OS only lets the app see photos the user selected. */
  limited?: boolean;
}

const NOT_FOUND = "I couldn't find a matching photo in your available photos.";
const REASON_TEXT: Record<PhotoSearchReason, string> = {
  no_visits: "There are no saved locations for that time, so I couldn't match a photo to where you went.",
  content_only:
    "I can search your photos by date, by the places you saved, or by file name, but I can't look inside every photo. Open a photo and ask me what's in it.",
  no_name_match: "None of the photo names match that.",
};

/** What the chat history says about a search: written here, never by the model. */
export function searchNote(report: PhotoSearchReport): string {
  switch (report.outcome) {
    case "permission_denied":
      return "I can't access your photos because Photos permission is turned off. You can allow it from Permissions.";
    case "failed":
      return "I couldn't read the photos on your phone right now. Please try again.";
    case "none": {
      const parts = [NOT_FOUND];
      if (report.reason) parts.push(REASON_TEXT[report.reason]);
      if (report.limited) parts.push("Child Assist can only see the photos you allowed it to access.");
      return parts.join(" ");
    }
    case "found": {
      const shown = report.photos.length;
      const total = Math.max(report.total ?? shown, shown);
      if (shown === 1) {
        const place = report.photos[0].place;
        if (place?.evidence === "gps") return `I found a matching photo, taken near ${place.name}.`;
        if (place?.evidence === "time") return `I found a matching photo, taken around the time you were at ${place.name}.`;
        return "I found a matching photo.";
      }
      return total > shown
        ? `I found ${total} matching photos and I'm showing the ${shown} best ones. Which one would you like?`
        : `I found ${shown} matching photos. Which one would you like?`;
    }
  }
}

/**
 * The phone reports what its search showed. Each shown photo gets an opaque id; a single match is
 * the photo being talked about straight away, several wait for the user to pick one.
 */
export async function recordPhotoSearch(
  userId: string,
  id: string,
  report: PhotoSearchReport,
  scope: RequestScope = {},
): Promise<{ request: PhotoRequestView; photos: PhotoView[]; message: MessageRecord | null }> {
  const found = report.outcome === "found";
  if (found && report.photos.length === 0) throw new HttpError(400, "A found result needs at least one photo.");
  if (!found && report.photos.length > 0) throw new HttpError(400, "Only a found result can list photos.");
  if (report.photos.length > MAX_PHOTOS_PER_SEARCH) {
    throw new HttpError(400, `At most ${MAX_PHOTOS_PER_SEARCH} photos can be shown.`);
  }

  const request = await claim(userId, id, PhotoRequestKind.SEARCH, scope);
  const now = new Date();
  const single = report.photos.length === 1;
  const rows = found
    ? await prisma.$transaction(
        report.photos.map((p) =>
          prisma.photoReference.create({
            data: {
              id: newPhotoId(),
              userId,
              conversationId: request.conversationId,
              capturedAt: p.capturedAt,
              width: p.width ?? null,
              height: p.height ?? null,
              placeName: p.place?.name ?? null,
              placeEvidence: p.place ? p.place.evidence.toUpperCase() : null,
              selectedAt: single ? now : null,
            },
          }),
        ),
      )
    : [];
  await finish(userId, id, report.outcome === "failed" ? PhotoRequestStatus.FAILED : PhotoRequestStatus.COMPLETED);
  const message = await note(userId, request.conversationId, searchNote(report));
  return { request: toView(await load(userId, id, PhotoRequestKind.SEARCH, scope)), photos: rows.map(toPhotoView), message };
}

// ---------------------------------------------------------------------------------------------
// ANALYZE

export type PhotoAnalysisFailure = "not_found" | "unavailable" | "permission" | "unsupported" | "too_large" | "cancelled";

/** What the user is told, written here rather than by the model so it can never invent content. */
export const ANALYSIS_FAILURES: Record<PhotoAnalysisFailure, string> = {
  not_found: "I couldn't find that photo on your phone, so I couldn't look at it.",
  unavailable: "This photo is no longer available on your device.",
  permission: "I can't access your photos because Photos permission is turned off. You can allow it from Permissions.",
  unsupported: "I can't read this type of image.",
  too_large: "This image is too large for me to look at.",
  cancelled: "Okay, I didn't look at the photo.",
};

export const ANALYSIS_FAILED_MESSAGE = "Sorry, I couldn't look at the photo right now. Please try again in a moment.";

export interface PhotoAnswerInput {
  photoId: string;
  /** The image as base64, exactly as the phone encoded it. */
  image: string;
}

/**
 * The phone sends the one photo this request is about; Gemini vision answers the question from
 * the image and the answer is saved as the assistant's reply. The image itself is not kept.
 */
export async function answerPhotoAnalysis(
  userId: string,
  id: string,
  input: PhotoAnswerInput,
  scope: RequestScope = {},
): Promise<{ request: PhotoRequestView; message: MessageRecord }> {
  const pending = await load(userId, id, PhotoRequestKind.ANALYZE, scope);
  // Only the photo this request was opened for, and only one of this user's own.
  if (input.photoId !== pending.photoId || !(await findUserPhoto(userId, input.photoId))) {
    throw new HttpError(404, "Photo not found", "PHOTO_NOT_FOUND");
  }
  const request = await claim(userId, id, PhotoRequestKind.ANALYZE, scope);

  const image = Buffer.from(input.image, "base64");
  if (image.length > MAX_IMAGE_BYTES) {
    await finish(userId, id, PhotoRequestStatus.FAILED);
    await note(userId, request.conversationId, ANALYSIS_FAILURES.too_large);
    throw new HttpError(413, ANALYSIS_FAILURES.too_large, "IMAGE_TOO_LARGE");
  }
  const mediaType = image.length >= MIN_IMAGE_BYTES ? detectImageType(image) : null;
  if (!mediaType) {
    await finish(userId, id, PhotoRequestStatus.FAILED);
    await note(userId, request.conversationId, ANALYSIS_FAILURES.unsupported);
    throw new HttpError(415, ANALYSIS_FAILURES.unsupported, "UNSUPPORTED_IMAGE");
  }

  const models = getChatModels();
  const candidates = [models.chat, models.fallback].filter((m) => m !== undefined);
  let answer: string | null = null;
  if (candidates.length > 0) {
    try {
      answer = await answerFromImage(candidates, {
        question: request.question ?? "What is in this photo?",
        image,
        mediaType,
      });
    } catch {
      // Already logged by name only; the image never reaches the log.
      answer = null;
    }
  }
  image.fill(0);

  if (!answer) {
    await finish(userId, id, PhotoRequestStatus.FAILED);
    await note(userId, request.conversationId, ANALYSIS_FAILED_MESSAGE);
    throw new HttpError(503, ANALYSIS_FAILED_MESSAGE, "AI_UNAVAILABLE");
  }

  await finish(userId, id, PhotoRequestStatus.COMPLETED);
  const message = await addMessage(userId, request.conversationId, {
    role: ChatMessageRole.CHAT_ASSISTANT,
    content: guardReply(answer, false),
  });
  return { request: toView(await load(userId, id, PhotoRequestKind.ANALYZE, scope)), message };
}

/** The phone could not send the photo for this request (or the user cancelled). */
export async function failPhotoRequest(
  userId: string,
  id: string,
  reason: PhotoAnalysisFailure,
  scope: RequestScope = {},
): Promise<{ request: PhotoRequestView; message: MessageRecord | null }> {
  const request = await claim(userId, id, PhotoRequestKind.ANALYZE, scope);
  await finish(userId, id, reason === "cancelled" ? PhotoRequestStatus.CANCELLED : PhotoRequestStatus.FAILED);
  const message = await note(userId, request.conversationId, ANALYSIS_FAILURES[reason]);
  return { request: toView(await load(userId, id, PhotoRequestKind.ANALYZE, scope)), message };
}
