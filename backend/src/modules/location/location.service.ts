import { LocationSource, Prisma } from "../../../generated/prisma/client";
import { automaticLocationConfig } from "../../config/env";
import { distanceMeters } from "../../lib/geo";
import { prisma } from "../../lib/prisma";
import { HttpError } from "../../lib/http-error";
import { notifyInBackground } from "../notifications/notification.service";
import { templates } from "../notifications/notification.types";
import type { CreateLocationInput } from "./location.validation";

export { LocationSource };

// Every query below is scoped by the userId passed in, which callers must take from the
// verified JWT. This module is also the entry point for later features (e.g. an assistant
// answering "where was I yesterday?"), so they get the same per-user scoping for free.

const locationSelect = {
  id: true,
  latitude: true,
  longitude: true,
  accuracy: true,
  placeName: true,
  address: true,
  street: true,
  locality: true,
  city: true,
  state: true,
  postalCode: true,
  country: true,
  capturedAt: true,
  source: true,
} as const;

type LocationRow = Prisma.LocationHistoryGetPayload<{ select: typeof locationSelect }>;

export interface LocationRecord {
  id: string;
  latitude: number;
  longitude: number;
  /** Accuracy radius in metres, or null if the device did not report one. */
  accuracy: number | null;
  /** Place details from the device's geocoder; any of them may be null. */
  placeName: string | null;
  address: string | null;
  street: string | null;
  locality: string | null;
  city: string | null;
  state: string | null;
  postalCode: string | null;
  country: string | null;
  capturedAt: Date;
  /** MANUAL ("Get Current Location") or AUTOMATIC (Automatic Location History). */
  source: LocationSource;
}

export interface HistoryOptions {
  limit: number;
  /** Only records captured strictly before this time. */
  before?: Date;
  /** Only records captured at or after this time. */
  since?: Date;
  /** "desc" (default) lists newest first; "asc" lists in the order the places were visited. */
  order?: "asc" | "desc";
  /** Only manual or only automatic locations; both when omitted. */
  source?: LocationSource;
}

function toRecord(row: LocationRow): LocationRecord {
  return {
    id: row.id,
    latitude: row.latitude.toNumber(),
    longitude: row.longitude.toNumber(),
    accuracy: row.accuracy?.toNumber() ?? null,
    placeName: row.placeName,
    address: row.address,
    street: row.street,
    locality: row.locality,
    city: row.city,
    state: row.state,
    postalCode: row.postalCode,
    country: row.country,
    capturedAt: row.capturedAt,
    source: row.source,
  };
}

function rowData(userId: string, input: CreateLocationInput) {
  return {
    userId,
    source: input.source,
    latitude: input.latitude,
    longitude: input.longitude,
    accuracy: input.accuracy ?? null,
    placeName: input.placeName ?? null,
    address: input.address ?? null,
    street: input.street ?? null,
    locality: input.locality ?? null,
    city: input.city ?? null,
    state: input.state ?? null,
    postalCode: input.postalCode ?? null,
    country: input.country ?? null,
    capturedAt: input.capturedAt,
  };
}

// Foreign key violation: the token is valid but the account no longer exists. Any other database
// error is replaced by one without its message, because Prisma messages can quote the query's
// arguments (the coordinates), and coordinates must never reach the server log.
function rethrowMissingUser(err: unknown): never {
  if (err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2003") {
    throw new HttpError(401, "Invalid or expired token");
  }
  if (err instanceof HttpError) throw err;
  const code = err instanceof Prisma.PrismaClientKnownRequestError ? ` ${err.code}` : "";
  throw new Error(`Saving a location failed (${err instanceof Error ? err.name : "unknown"}${code})`);
}

export type SaveResult = { saved: true; location: LocationRecord } | { saved: false; reason: "duplicate" };

/**
 * Saves a location for the user. A manual save is always stored. An automatic one is skipped as a
 * duplicate when the user already has a location (of either kind) captured within the configured
 * time of it and closer than the configured distance: a phone resending a point, or reporting the
 * same place again, never adds rows. Uploads for one user are serialised so two copies of the same
 * point arriving together cannot both pass the check.
 */
export async function saveLocation(userId: string, input: CreateLocationInput): Promise<SaveResult> {
  if (input.source !== LocationSource.AUTOMATIC) {
    try {
      const row = await prisma.locationHistory.create({ data: rowData(userId, input), select: locationSelect });
      return { saved: true, location: toRecord(row) };
    } catch (err) {
      rethrowMissingUser(err);
    }
  }

  const { duplicateDistanceMeters, duplicateIntervalMs } = automaticLocationConfig();
  const at = input.capturedAt.getTime();
  let result: SaveResult;
  try {
    result = await prisma.$transaction(async (tx) => {
      // Held until the transaction ends; keyed by the user so different users never wait on each other.
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtextextended(${`location:${userId}`}, 0))`;
      // Nearby in time on either side, so a point from an offline queue that arrives after newer
      // ones is still compared with its neighbours.
      const neighbours = await tx.locationHistory.findMany({
        where: {
          userId,
          capturedAt: { gte: new Date(at - duplicateIntervalMs + 1), lte: new Date(at + duplicateIntervalMs - 1) },
        },
        select: { latitude: true, longitude: true },
        take: 50,
      });
      const point = { latitude: input.latitude, longitude: input.longitude };
      const duplicate = neighbours.some(
        (n) => distanceMeters(point, { latitude: n.latitude.toNumber(), longitude: n.longitude.toNumber() }) < duplicateDistanceMeters,
      );
      if (duplicate) return { saved: false, reason: "duplicate" } as const;

      const row = await tx.locationHistory.create({ data: rowData(userId, input), select: locationSelect });
      return { saved: true, location: toRecord(row) } as const;
    });
  } catch (err) {
    rethrowMissingUser(err);
  }
  if (result.saved) notifyTravelHistoryUpdated(userId);
  return result;
}

/**
 * Automatic places are saved silently; at most one "Your travel history has new activity" a day
 * (server's UTC day) says so, never which place. Not one per reading.
 */
function notifyTravelHistoryUpdated(userId: string): void {
  const day = new Date().toISOString().slice(0, 10);
  notifyInBackground(userId, templates.travelHistoryUpdated(), { dedupeKey: `travel-history:${day}` });
}

/** The user's own locations, newest first unless asked otherwise. */
export async function listLocations(userId: string, options: HistoryOptions): Promise<LocationRecord[]> {
  const order = options.order ?? "desc";
  const rows = await prisma.locationHistory.findMany({
    where: {
      userId,
      capturedAt: { lt: options.before, gte: options.since },
      ...(options.source ? { source: options.source } : {}),
    },
    orderBy: [{ capturedAt: order }, { createdAt: order }],
    take: options.limit,
    select: locationSelect,
  });
  return rows.map(toRecord);
}

/**
 * Up to `limit` of the user's locations, and whether there were more. One extra row is read
 * to tell, so a capped answer is never mistaken for the whole history.
 */
export async function searchLocations(
  userId: string,
  options: HistoryOptions,
): Promise<{ locations: LocationRecord[]; hasMore: boolean }> {
  const rows = await listLocations(userId, { ...options, limit: options.limit + 1 });
  return { locations: rows.slice(0, options.limit), hasMore: rows.length > options.limit };
}

/** Deletes all of the user's locations and returns how many were removed. */
export async function deleteHistory(userId: string): Promise<number> {
  const { count } = await prisma.locationHistory.deleteMany({ where: { userId } });
  return count;
}

/**
 * Deletes one location if it belongs to the user. Someone else's location gives the same
 * 404 as a missing one, so IDs cannot be probed.
 */
export async function deleteLocation(userId: string, id: string): Promise<void> {
  const { count } = await prisma.locationHistory.deleteMany({ where: { id, userId } });
  if (count === 0) {
    throw new HttpError(404, "Location not found");
  }
}
