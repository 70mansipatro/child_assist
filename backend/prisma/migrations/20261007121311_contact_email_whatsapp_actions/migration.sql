-- CreateEnum
CREATE TYPE "ChatActionStatus" AS ENUM ('PENDING', 'CONFIRMED', 'CANCELLED', 'COMPLETED', 'FAILED', 'EXPIRED');

-- CreateEnum
CREATE TYPE "ChatActionType" AS ENUM ('SEND_EMAIL', 'SEND_WHATSAPP', 'SHARE_LOCATION', 'SHARE_TRAVEL_HISTORY', 'SHARE_DOCUMENT');

-- CreateEnum
CREATE TYPE "ChatActionChannel" AS ENUM ('EMAIL', 'WHATSAPP');

-- AlterEnum
ALTER TYPE "PermissionType" ADD VALUE 'CONTACTS';

-- CreateTable
CREATE TABLE "chat_actions" (
    "id" TEXT NOT NULL,
    "user_id" UUID NOT NULL,
    "conversation_id" TEXT NOT NULL,
    "type" "ChatActionType" NOT NULL,
    "channel" "ChatActionChannel" NOT NULL,
    "status" "ChatActionStatus" NOT NULL DEFAULT 'PENDING',
    "contact_query" VARCHAR(120),
    "recipient_name" VARCHAR(120),
    "recipient_address" VARCHAR(320),
    "subject" VARCHAR(200),
    "message" TEXT,
    "data_summary" VARCHAR(300),
    "document_query" VARCHAR(120),
    "expires_at" TIMESTAMP(3) NOT NULL,
    "confirmed_at" TIMESTAMP(3),
    "completed_at" TIMESTAMP(3),
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "chat_actions_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "chat_actions_user_id_status_idx" ON "chat_actions"("user_id", "status");

-- CreateIndex
CREATE INDEX "chat_actions_conversation_id_created_at_idx" ON "chat_actions"("conversation_id", "created_at");

-- CreateIndex
CREATE INDEX "chat_actions_expires_at_idx" ON "chat_actions"("expires_at");

-- AddForeignKey
ALTER TABLE "chat_actions" ADD CONSTRAINT "chat_actions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "chat_actions" ADD CONSTRAINT "chat_actions_conversation_id_fkey" FOREIGN KEY ("conversation_id") REFERENCES "chat_conversations"("id") ON DELETE CASCADE ON UPDATE CASCADE;
