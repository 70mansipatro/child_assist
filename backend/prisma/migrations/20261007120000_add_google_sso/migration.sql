-- Google SSO: Google's stable account ID for users who sign in with Google. Additive only;
-- existing rows keep their data and get NULL.

-- AlterTable
ALTER TABLE "users" ADD COLUMN     "google_subject" TEXT;

-- CreateIndex
CREATE UNIQUE INDEX "users_google_subject_key" ON "users"("google_subject");