import { Prisma } from "../../../generated/prisma/client";
import { prisma } from "../../lib/prisma";
import { HttpError } from "../../lib/http-error";
import type { CreateLocationInput } from "./location.validation";

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
}

export interface HistoryOptions {
  limit: number;
  /** Only records captured strictly before this time. */
  before?: Date;
  /** Only records captured at or after this time. */
  since?: Date;
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
  };
}

export async function saveLocation(userId: string, input: CreateLocationInput): Promise<LocationRecord> {
  try {
    const row = await prisma.locationHistory.create({
      data: {
        userId,
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
      },
      select: locationSelect,
    });
    return toRecord(row);
  } catch (err) {
    // Foreign key violation: the token is valid but the account no longer exists.
    if (err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2003") {
      throw new HttpError(401, "Invalid or expired token");
    }
    throw err;
  }
}

/** The user's own locations, newest first. */
export async function listLocations(userId: string, options: HistoryOptions): Promise<LocationRecord[]> {
  const rows = await prisma.locationHistory.findMany({
    where: {
      userId,
      capturedAt: { lt: options.before, gte: options.since },
    },
    orderBy: [{ capturedAt: "desc" }, { createdAt: "desc" }],
    take: options.limit,
    select: locationSelect,
  });
  return rows.map(toRecord);
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
