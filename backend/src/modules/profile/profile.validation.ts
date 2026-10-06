import { z } from "zod";

const MAX_URL_LENGTH = 2048;

// Strict: unknown keys (email, id, passwordHash, ...) are rejected rather than silently ignored,
// so protected fields can never be changed through this endpoint.
export const updateProfileSchema = z
  .strictObject(
    {
      name: z
        .string({ error: "Name must be a string" })
        .trim()
        .min(1, "Name cannot be empty")
        .max(100, "Name must be at most 100 characters")
        .optional(),
      // A link to an externally hosted image (HTTPS only), or null to remove it.
      profileImageUrl: z
        .string({ error: "Profile image URL must be a string or null" })
        .trim()
        .max(MAX_URL_LENGTH, `Profile image URL must be at most ${MAX_URL_LENGTH} characters`)
        .pipe(z.url({ protocol: /^https$/, error: "Profile image URL must be a valid https:// URL" }))
        .nullable()
        .optional(),
    },
    { error: "Request body must be a JSON object" },
  )
  .refine((body) => body.name !== undefined || body.profileImageUrl !== undefined, {
    message: "Provide at least one field to update: name or profileImageUrl",
  });

export type UpdateProfileInput = z.infer<typeof updateProfileSchema>;
