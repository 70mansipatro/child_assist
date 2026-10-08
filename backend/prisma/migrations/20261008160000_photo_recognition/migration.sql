-- Additive only: photo references and requests for AI photo search/recognition, a SHARE_PHOTO
-- action type and chat_actions.photo_id. No existing data is changed or removed. No image bytes,
-- paths or URIs are stored.

-- CreateEnum
CREATE TYPE "PhotoRequestKind" AS ENUM ('SEARCH', 'ANALYZE');

-- CreateEnum
CREATE TYPE "PhotoRequestStatus" AS ENUM ('PENDING', 'COMPLETED', 'FAILED', 'CANCELLED', 'EXPIRED');

-- AlterEnum
ALTER TYPE "ChatActionType" ADD VALUE 'SHARE_PHOTO';

-- AlterTable
ALTER TABLE "chat_actions" ADD COLUMN     "photo_id" VARCHAR(40);

-- CreateTable
CREATE TABLE "photo_references" (
    "id" VARCHAR(40) NOT NULL,
    "user_id" UUID NOT NULL,
    "conversation_id" TEXT NOT NULL,
    "captured_at" TIMESTAMP(3) NOT NULL,
    "width" INTEGER,
    "height" INTEGER,
    "place_name" VARCHAR(255),
    "place_evidence" VARCHAR(8),
    "selected_at" TIMESTAMP(3),
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "photo_references_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "photo_requests" (
    "id" TEXT NOT NULL,
    "user_id" UUID NOT NULL,
    "conversation_id" TEXT NOT NULL,
    "kind" "PhotoRequestKind" NOT NULL,
    "status" "PhotoRequestStatus" NOT NULL DEFAULT 'PENDING',
    "question" VARCHAR(500),
    "photo_id" VARCHAR(40),
    "expires_at" TIMESTAMP(3) NOT NULL,
    "completed_at" TIMESTAMP(3),
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "photo_requests_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "photo_references_user_id_conversation_id_selected_at_idx" ON "photo_references"("user_id", "conversation_id", "selected_at");

-- CreateIndex
CREATE INDEX "photo_requests_user_id_status_idx" ON "photo_requests"("user_id", "status");

-- CreateIndex
CREATE INDEX "photo_requests_expires_at_idx" ON "photo_requests"("expires_at");

-- AddForeignKey
ALTER TABLE "photo_references" ADD CONSTRAINT "photo_references_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "photo_references" ADD CONSTRAINT "photo_references_conversation_id_fkey" FOREIGN KEY ("conversation_id") REFERENCES "chat_conversations"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "photo_requests" ADD CONSTRAINT "photo_requests_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "photo_requests" ADD CONSTRAINT "photo_requests_conversation_id_fkey" FOREIGN KEY ("conversation_id") REFERENCES "chat_conversations"("id") ON DELETE CASCADE ON UPDATE CASCADE;

