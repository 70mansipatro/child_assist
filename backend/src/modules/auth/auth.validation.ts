import { z } from "zod";

// bcrypt only uses the first 72 bytes of a password, so reject anything longer.
const BCRYPT_MAX_BYTES = 72;

const emailSchema = z
  .string({ error: "Email is required" })
  .trim()
  .toLowerCase()
  .pipe(z.email({ error: "Email must be a valid email address" }).max(254, "Email is too long"));

// The rules for every new password: registration and password reset alike.
const passwordSchema = z
  .string({ error: "Password is required" })
  .min(8, "Password must be at least 8 characters")
  .refine((p) => Buffer.byteLength(p, "utf8") <= BCRYPT_MAX_BYTES, {
    message: `Password must be at most ${BCRYPT_MAX_BYTES} bytes`,
  });

const sixDigitCode = (required: string) =>
  z
    .string({ error: required })
    .trim()
    .regex(/^\d{6}$/, "Enter the 6-digit code from your email");

export const registerSchema = z.object(
  {
    name: z
      .string({ error: "Name is required" })
      .trim()
      .min(1, "Name is required")
      .max(100, "Name must be at most 100 characters"),
    email: emailSchema,
    password: passwordSchema,
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
    code: sixDigitCode("Verification code is required"),
  },
  { error: "Request body must be a JSON object" },
);

export const resendVerificationSchema = z.strictObject(
  { email: emailSchema },
  { error: "Request body must be a JSON object" },
);

// Forgot password: strict, like verification. The account is named only by its email.
export const forgotPasswordSchema = z.strictObject(
  { email: emailSchema },
  { error: "Request body must be a JSON object" },
);

export const resendResetCodeSchema = forgotPasswordSchema;

export const verifyResetCodeSchema = z.strictObject(
  {
    email: emailSchema,
    code: sixDigitCode("Reset code is required"),
  },
  { error: "Request body must be a JSON object" },
);

export const resetPasswordSchema = z
  .strictObject(
    {
      // 32 random bytes, base64url: 43 characters. Anything else cannot be a token we issued.
      resetToken: z
        .string({ error: "Reset token is required" })
        .regex(/^[A-Za-z0-9_-]{43}$/, "Reset token is invalid"),
      newPassword: passwordSchema,
      // Optional: when the client sends it, it must match.
      confirmPassword: z.string().optional(),
    },
    { error: "Request body must be a JSON object" },
  )
  .refine((b) => b.confirmPassword === undefined || b.confirmPassword === b.newPassword, {
    message: "Passwords do not match",
    path: ["confirmPassword"],
  });

export type RegisterInput = z.infer<typeof registerSchema>;
export type LoginInput = z.infer<typeof loginSchema>;
export type GoogleLoginInput = z.infer<typeof googleLoginSchema>;
export type VerifyEmailInput = z.infer<typeof verifyEmailSchema>;
export type ResendVerificationInput = z.infer<typeof resendVerificationSchema>;
export type ForgotPasswordInput = z.infer<typeof forgotPasswordSchema>;
export type VerifyResetCodeInput = z.infer<typeof verifyResetCodeSchema>;
export type ResetPasswordInput = z.infer<typeof resetPasswordSchema>;
