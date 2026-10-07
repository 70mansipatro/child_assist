-- Automatic Location History and chat memory. Additive only: existing location rows were all
-- saved with "Get Current Location", so they become MANUAL through the column default.

-- CreateEnum
CREATE TYPE "LocationSource" AS ENUM ('MANUAL', 'AUTOMATIC');

-- AlterTable
ALTER TABLE "chat_conversations" ADD COLUMN     "summarized_until" TIMESTAMP(3),
ADD COLUMN     "summary" TEXT;

-- AlterTable
ALTER TABLE "location_history" ADD COLUMN     "source" "LocationSource" NOT NULL DEFAULT 'MANUAL';

-- CreateIndex
CREATE INDEX "location_history_user_id_source_captured_at_idx" ON "location_history"("user_id", "source", "captured_at");
