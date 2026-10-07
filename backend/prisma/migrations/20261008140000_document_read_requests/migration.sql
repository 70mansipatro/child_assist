-- Additive only: a new table for on-device document reads. No existing table is changed.

-- CreateEnum
CREATE TYPE "DocumentReadStatus" AS ENUM ('PENDING', 'COMPLETED', 'FAILED', 'CANCELLED', 'EXPIRED');

-- CreateTable
CREATE TABLE "document_read_requests" (
    "id" TEXT NOT NULL,
    "user_id" UUID NOT NULL,
    "conversation_id" TEXT NOT NULL,
    "status" "DocumentReadStatus" NOT NULL DEFAULT 'PENDING',
    "document_query" VARCHAR(120),
    "document_type" VARCHAR(8),
    "question" VARCHAR(500),
    "document_id" VARCHAR(64),
    "expires_at" TIMESTAMP(3) NOT NULL,
    "completed_at" TIMESTAMP(3),
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "document_read_requests_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "document_read_requests_user_id_status_idx" ON "document_read_requests"("user_id", "status");

-- CreateIndex
CREATE INDEX "document_read_requests_expires_at_idx" ON "document_read_requests"("expires_at");

-- AddForeignKey
ALTER TABLE "document_read_requests" ADD CONSTRAINT "document_read_requests_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "document_read_requests" ADD CONSTRAINT "document_read_requests_conversation_id_fkey" FOREIGN KEY ("conversation_id") REFERENCES "chat_conversations"("id") ON DELETE CASCADE ON UPDATE CASCADE;
