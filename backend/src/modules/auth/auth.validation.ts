import { z } from "zod";

// bcrypt only uses the first 72 bytes of a password, so reject anything longer.
const BCRYPT_MAX_BYTES = 72;

const emailSchema = z
  .string({ error: "Email is required" })
  .trim()
  .toLowerCase()
  .pipe(z.email({ error: "Email must be a valid email address" }).max(254, "Email is too long"));

export const registerSchema = z.object(
  {
    name: z
      .string({ error: "Name is required" })
      .trim()
      .min(1, "Name is required")
      .max(100, "Name must be at most 100 characters"),
    email: emailSchema,
    password: z
      .string({ error: "Password is required" })
      .min(8, "Password must be at least 8 characters")
      .refine((p) => Buffer.byteLength(p, "utf8") <= BCRYPT_MAX_BYTES, {
        message: `Password must be at most ${BCRYPT_MAX_BYTES} bytes`,
      }),
  },
  { error: "Request body must be a JSON object" },
);

export const loginSchema = z.object(
  {
    email: emailSchema,
    password: z.string({ error: "Password is required" }).min(1, "Password is required"),
  },
  { error: "Request body must be a JSON object" },
);

export type RegisterInput = z.infer<typeof registerSchema>;
export type LoginInput = z.infer<typeof loginSchema>;
