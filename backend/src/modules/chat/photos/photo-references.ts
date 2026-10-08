import { randomBytes } from "node:crypto";
import type { PhotoReference } from "../../../../generated/prisma/client";
import { HttpError } from "../../../lib/http-error";
import { prisma } from "../../../lib/prisma";

// Photos the assistant showed in a conversation. Photos never leave the phone: when the phone
// shows one in chat, the server mints an opaque id for it (photo_ + 20 random hex characters) and
// keeps only when it was taken, its size and the user's own saved place it was matched to. No
// image bytes, file name, path, content URI or device asset id are ever stored or seen here; the
// phone keeps the mapping from this id to its own gallery entry.
//
// Every lookup is scoped by the userId from the verified JWT. Another user's photo id looks exactly
// like a missing one, so ids cannot be probed.

export const PHOTO_ID_PATTERN = /^photo_[a-f0-9]{20}$/;

/** At most this many photos are shown (and minted) for one search. */
export const MAX_PHOTOS_PER_SEARCH = 12;

export type PlaceEvidence = "gps" | "time";

export interface PhotoView {
  id: string;
  capturedAt: string;
  width: number | null;
  height: number | null;
  placeName: string | null;
  /** How the photo was matched to the place: its own GPS metadata, or the time it was taken. */
  placeEvidence: PlaceEvidence | null;
  selected: boolean;
}

export function newPhotoId(): string {
  return `photo_${randomBytes(10).toString("hex")}`;
}

export function toPhotoView(p: PhotoReference): PhotoView {
  const evidence = p.placeEvidence === "GPS" ? "gps" : p.placeEvidence === "TIME" ? "time" : null;
  return {
    id: p.id,
    capturedAt: p.capturedAt.toISOString(),
    width: p.width,
    height: p.height,
    placeName: evidence ? p.placeName : null,
    placeEvidence: evidence,
    selected: p.selectedAt !== null,
  };
}

/** The user's own photo reference, or null. Never another user's, whatever the id. */
export async function findUserPhoto(userId: string, id: string): Promise<PhotoReference | null> {
  if (!PHOTO_ID_PATTERN.test(id)) return null;
  return prisma.photoReference.findFirst({ where: { id, userId } });
}

export type CurrentPhoto =
  | { status: "selected"; photo: PhotoReference }
  /** Several photos were shown and the user has not picked one yet. */
  | { status: "choosing" }
  | { status: "none" };

/**
 * The photo being talked about in the user's conversation: the one they last picked (or the only
 * match of a search). If a newer search showed several photos that the user has not chosen from,
 * there is no current photo: they must pick one first, so the assistant never guesses.
 */
export async function currentPhoto(userId: string, conversationId: string): Promise<CurrentPhoto> {
  const selected = await prisma.photoReference.findFirst({
    where: { userId, conversationId, selectedAt: { not: null } },
    orderBy: [{ selectedAt: "desc" }, { id: "desc" }],
  });
  const newerChoice = await prisma.photoReference.findFirst({
    where: {
      userId,
      conversationId,
      selectedAt: null,
      ...(selected ? { createdAt: { gt: selected.selectedAt! } } : {}),
    },
    select: { id: true },
  });
  if (newerChoice) return { status: "choosing" };
  return selected ? { status: "selected", photo: selected } : { status: "none" };
}

export interface PhotoScope {
  conversationId?: string;
}

/** The user picked [id] among the photos shown: it becomes the photo being talked about. */
export async function selectPhoto(userId: string, id: string, scope: PhotoScope = {}): Promise<PhotoView> {
  const photo = await findUserPhoto(userId, id);
  if (!photo || (scope.conversationId && photo.conversationId !== scope.conversationId)) {
    throw new HttpError(404, "Photo not found", "PHOTO_NOT_FOUND");
  }
  const updated = await prisma.photoReference.update({ where: { id: photo.id }, data: { selectedAt: new Date() } });
  return toPhotoView(updated);
}
