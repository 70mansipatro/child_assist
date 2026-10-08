import { z } from "zod";
import { PermissionType, type PhotoReference } from "../../../../generated/prisma/client";
import {
  addDays,
  daysInRange,
  HISTORY_PERIODS,
  isLocalDate,
  localDateOf,
  MAX_RANGE_DAYS,
  rangeToInstants,
  resolvePeriod,
  type LocalDateRange,
} from "../../../lib/local-dates";
import { searchLocations } from "../../location/location.service";
import { currentPhoto, findUserPhoto, PHOTO_ID_PATTERN, toPhotoView, type PhotoView } from "../photos/photo-references";
import { preparePhotoAnalysis, preparePhotoSearch } from "../photos/photo-requests";
import { defineChatTool, hasPermission, permissionRequired } from "./define-tool";
import { fail, ok, type ToolContext, type ToolResult } from "./types";

// Photos stay on the phone. These tools never see an image, a file name, a path or a URI:
//
//   get_photo_candidates  the phone searches its own gallery against the date and, when asked,
//                         the user's own saved places (sent from LocationHistory), shows the strong
//                         matches and reports which it showed; each gets an opaque photo_ id.
//   get_photo             shows a photo already found in this chat again (owner checked).
//   analyze_photo         the phone sends that ONE photo, scaled down, for Gemini vision.
//   share_photo           the phone asks the user to confirm, then opens WhatsApp / the share sheet.
//
// Photo ids are checked against the user from the JWT: another user's id is simply not found.

/** Saved places sent to the phone for location matching (the user's own LocationHistory). */
const MAX_VISITS = 50;
/** "The place I visited" without a day: the last 30 days. */
const PLACE_LOOKBACK_DAYS = 30;

const localDate = (label: string) => z.string().refine(isLocalDate, `${label} must be a calendar date in YYYY-MM-DD format`);
// Words the user said; one line, nothing that could close a prompt block.
const words = (max: number) => z.string().trim().max(max).regex(/^[^\r\n\t<>"]*$/);
const photoId = z.string().regex(PHOTO_ID_PATTERN, "Invalid photo id");

const NO_PHOTO =
  "No photo has been shown in this chat yet. Ask the user which photo they mean, or search for it with " +
  "get_photo_candidates. Never describe a photo you have not been given.";
const CHOOSING =
  "Several photos were shown and the user has not picked one yet. Ask them to tap the photo they mean. " +
  "Never guess which one they mean.";

/** The photo a tool acts on: the one named (if it is the user's own), else the one being talked about. */
async function resolvePhoto(ctx: ToolContext, id: string | undefined): Promise<ToolResult<PhotoReference>> {
  if (id) {
    const photo = await findUserPhoto(ctx.userId, id);
    return photo ? ok(photo) : fail("PHOTO_NOT_FOUND", "No photo with that id was found for this user.");
  }
  const current = await currentPhoto(ctx.userId, ctx.conversationId);
  if (current.status === "selected") return ok(current.photo);
  return fail("NO_PHOTO_SELECTED", current.status === "choosing" ? CHOOSING : NO_PHOTO);
}

/** What the model may know about a photo: never a path, URI, file name or the image. */
function photoForModel(p: PhotoView) {
  return {
    photoId: p.id,
    capturedAt: p.capturedAt,
    ...(p.placeName ? { placeName: p.placeName, placeEvidence: p.placeEvidence } : {}),
  };
}

export function photoTools(ctx: ToolContext) {
  return {
    get_photo_candidates: defineChatTool(ctx, {
      name: "get_photo_candidates",
      kind: "photos",
      display: (data) => {
        const d = data as { requestId: string; query: Record<string, unknown>; visits: unknown[] };
        return { status: "device_lookup", data: { requestId: d.requestId, query: d.query, visits: d.visits } };
      },
      description:
        "Find photos on the user's phone and show them in the chat: 'show me today's photo', 'show pictures from " +
        "yesterday', 'the photo from where I went today', 'send me that pic', 'show the latest picture', 'find " +
        "IMG_2041'. The phone searches only the photos the user allowed Child Assist to access, by date, by the " +
        "user's own saved places (locationContext/place) and by file name. It shows one strong match, asks the " +
        "user to choose among several, or says none was found. You never see the photos.",
      inputSchema: z.strictObject({
        period: z.enum(HISTORY_PERIODS).optional().describe("When the photo was taken, relative to today"),
        startDate: localDate("startDate").optional().describe("First local day (YYYY-MM-DD), instead of period"),
        endDate: localDate("endDate").optional().describe("Last local day (inclusive)"),
        locationContext: z
          .boolean()
          .optional()
          .describe(
            "true when the user means the place(s) they went: 'from where I went today', 'at the place I " +
              "visited', 'from today's location'. Photos are matched to their saved locations.",
          ),
        place: words(80)
          .optional()
          .describe("A saved place the user named, e.g. 'school' or 'park' ('the photo from the park')"),
        fileName: words(80)
          .optional()
          .describe("Only words that would be in the photo's FILE NAME, e.g. 'IMG_2041' or 'screenshot'"),
        visualHint: words(80)
          .optional()
          .describe(
            "What the user says is IN the photo, e.g. 'dog', 'car', 'python class'. It cannot be searched by " +
              "content; the phone uses it to explain that and may show photos from the date or place instead.",
          ),
        latest: z.boolean().optional().describe("true for 'the latest / last / most recent photo'"),
      }),
      permission: PermissionType.PHOTOS,
      execute: async ({ period, startDate, endDate, locationContext, place, fileName, visualHint, latest }, toolCtx) => {
        const { userId, zone } = toolCtx;
        const useLocation = locationContext === true || !!place;
        if (useLocation && !(await hasPermission(userId, PermissionType.LOCATION))) {
          return permissionRequired(PermissionType.LOCATION);
        }

        const today = localDateOf(new Date(), zone);
        let range: LocalDateRange | null = null;
        if (period && (startDate || endDate)) return fail("INVALID_ARGUMENTS", "Pass either period or startDate/endDate, not both.");
        if (period) range = resolvePeriod(period, today);
        else if (startDate) range = { startDate, endDate: endDate ?? startDate };
        else if (useLocation) {
          // "Where I went" means today; a named place without a day, the last few weeks.
          range = place && !locationContext ? { startDate: addDays(today, 1 - PLACE_LOOKBACK_DAYS), endDate: today } : { startDate: today, endDate: today };
        }
        if (range) {
          const days = daysInRange(range.startDate, range.endDate);
          if (days < 1) return fail("INVALID_ARGUMENTS", "endDate must not be before startDate.");
          if (days > MAX_RANGE_DAYS) return fail("INVALID_ARGUMENTS", "The period can be at most one year.");
        }
        const instants = range ? rangeToInstants(range, zone) : null;

        let visits: Array<{ capturedAt: string; latitude: number; longitude: number; placeName: string | null }> = [];
        if (useLocation && instants) {
          const { locations } = await searchLocations(userId, { ...instants, limit: MAX_VISITS, order: "asc" });
          const wanted = place?.toLowerCase().split(/\s+/).filter((w) => w.length > 1) ?? [];
          visits = locations
            .filter((l) => {
              if (wanted.length === 0) return true;
              const text = [l.placeName, l.address, l.street, l.locality, l.city].filter(Boolean).join(" ").toLowerCase();
              return wanted.every((w) => text.includes(w));
            })
            .map((l) => ({
              capturedAt: l.capturedAt.toISOString(),
              latitude: l.latitude,
              longitude: l.longitude,
              placeName: l.placeName ?? l.locality ?? l.city ?? null,
            }));
        }

        const request = await preparePhotoSearch(toolCtx);
        return ok({
          handledOnDevice: true,
          requestId: request.id,
          query: {
            fileName: fileName || null,
            visualHint: visualHint || null,
            startDate: instants?.since.toISOString() ?? null,
            endDate: instants?.before.toISOString() ?? null,
            locationContext: useLocation,
            latest: latest === true,
          },
          visits,
          note:
            "The Child Assist app is searching the user's own photos on their phone and shows the result below your " +
            "reply: one strong match is shown as a photo card; several are shown for the user to choose from; if " +
            "none match it says so. You cannot see the photos or the result: never describe, count, name or guess " +
            "photos, never say a photo was found, and never say it was taken somewhere. Reply with one short " +
            "sentence such as \"Let me find that photo.\" in the user's language.",
        });
      },
    }),

    get_photo: defineChatTool(ctx, {
      name: "get_photo",
      kind: "photos",
      display: (data) => ({ data: { photo: (data as { photo: PhotoView }).photo } }),
      description:
        "Show again a photo that was already found in this chat ('show me that photo again'). Only takes a photoId " +
        "from this chat; to find a photo use get_photo_candidates.",
      inputSchema: z.strictObject({ photoId }),
      permission: PermissionType.PHOTOS,
      execute: async ({ photoId: id }, toolCtx) => {
        const photo = await resolvePhoto(toolCtx, id);
        if (!photo.success) return photo;
        const view = toPhotoView(photo.data);
        return ok({ photo: view, shown: photoForModel(view), note: "The app shows this photo below your reply." });
      },
    }),

    analyze_photo: defineChatTool(ctx, {
      name: "analyze_photo",
      kind: "photo_analysis",
      display: (data) => {
        const d = data as { requestId: string; photoId: string };
        return { status: "device_lookup", data: { requestId: d.requestId, photoId: d.photoId } };
      },
      description:
        "Look at the photo being talked about and answer a question about what is IN it: 'what is in this photo?', " +
        "'describe this image', 'is there a car in it?', 'what colour is the car?', 'what does this sign say?', " +
        "'read the text in this photo'. The phone sends that one photo to Gemini vision and the answer, written " +
        "from the real image, appears below your reply. Use it for every visual question, including follow-ups; " +
        "never answer about a photo's content yourself.",
      inputSchema: z.strictObject({
        photoId: photoId
          .optional()
          .describe("Leave out for 'this photo' / 'it' / 'that picture': the photo shown or picked in this chat"),
        // Quotes are fine here ('what does the "EXIT" sign say?'): it is sent as plain text, never in a block.
        question: z
          .string()
          .trim()
          .min(1)
          .max(500)
          .regex(/^[^\u0000-\u001f\u007f]+$/)
          .describe("The user's question in their own words and language"),
      }),
      permission: PermissionType.PHOTOS,
      execute: async ({ photoId: id, question }, toolCtx) => {
        const photo = await resolvePhoto(toolCtx, id);
        if (!photo.success) return photo;
        const request = await preparePhotoAnalysis(toolCtx, photo.data.id, question);
        return ok({
          handledOnDevice: true,
          requestId: request.id,
          photoId: photo.data.id,
          note:
            "The Child Assist app is sending this one photo from the user's phone to be looked at; the answer from " +
            "the real image appears below your reply. You cannot see the photo: never describe or guess what is in " +
            "it. Reply with one short sentence such as \"Let me look at the photo.\" in the user's language.",
        });
      },
    }),

    share_photo: defineChatTool(ctx, {
      name: "share_photo",
      kind: "photo_share",
      display: (data) => {
        const d = data as { photo: PhotoView; app: string };
        return { status: "confirmation_required", data: { photo: d.photo, app: d.app } };
      },
      description:
        "Share the photo being talked about from the phone, when the user did NOT name a person: 'share this photo', " +
        "'send this photo on WhatsApp'. Nothing is sent: the app asks the user to confirm, then opens WhatsApp (or " +
        "the share sheet) with the photo, and the user picks the chat and taps Send there. To send it to a named " +
        "person use prepare_whatsapp with sharePhoto true.",
      inputSchema: z.strictObject({
        photoId: photoId.optional().describe("Leave out for 'this photo' / 'that photo'"),
        app: z.enum(["whatsapp", "any"]).optional().describe("'whatsapp' when they said WhatsApp, otherwise 'any'"),
      }),
      permission: PermissionType.PHOTOS,
      execute: async ({ photoId: id, app }, toolCtx) => {
        const photo = await resolvePhoto(toolCtx, id);
        if (!photo.success) return photo;
        const view = toPhotoView(photo.data);
        return ok({
          status: "CONFIRMATION_REQUIRED",
          photo: view,
          app: app ?? "any",
          note:
            "Nothing has been shared. The app now asks the user to confirm sharing this photo. Ask them to check it " +
            "and confirm. Never say it was sent or shared.",
        });
      },
    }),
  };
}
