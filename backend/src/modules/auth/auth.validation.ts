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

// Only the token is accepted: name, email and Google ID come from the verified token, never the body.
export const googleLoginSchema = z.strictObject(
  {
    idToken: z
      .string({ error: "idToken is required" })
      .min(1, "idToken is required")
      .max(4096, "idToken is too long"),
  },
  { error: "Request body must be a JSON object" },
);

// Strict: the account is named only by its email. Any other field (e.g. a userId) is refused.
export const verifyEmailSchema = z.strictObject(
  {
    email: emailSchema,
    code: z
      .string({ error: "Verification code is required" })
      .trim()
      .regex(/^\d{6}$/, "Enter the 6-digit code from your email"),
  },
  { error: "Request body must be a JSON object" },
);

export const resendVerificationSchema = z.strictObject(
  { email: emailSchema },
  { error: "Request body must be a JSON object" },
);

export type RegisterInput = z.infer<typeof registerSchema>;
export type LoginInput = z.infer<typeof loginSchema>;
export type GoogleLoginInput = z.infer<typeof googleLoginSchema>;
export type VerifyEmailInput = z.infer<typeof verifyEmailSchema>;
export type ResendVerificationInput = z.infer<typeof resendVerificationSchema>;
