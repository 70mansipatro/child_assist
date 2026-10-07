-- Phase 9: push notifications (FCM delivery only), notification history and preferences.
-- Additive only: new enums and tables; no existing table or row is changed.
-- CreateEnum
CREATE TYPE "NotificationType" AS ENUM ('ACCOUNT_LOGIN', 'ACCOUNT_SECURITY', 'EMAIL_VERIFICATION', 'PASSWORD_RESET', 'PASSWORD_CHANGED', 'PERMISSION_CHANGED', 'TRACKING_STARTED', 'TRACKING_STOPPED', 'TRACKING_PAUSED', 'LOCATION_UPDATED', 'TRAVEL_HISTORY_UPDATED', 'CHAT_REPLY_READY', 'EMAIL_ACTION', 'WHATSAPP_ACTION', 'DOCUMENT_UPDATED', 'PHOTO_UPDATED', 'SYSTEM', 'GENERAL');

-- CreateEnum
CREATE TYPE "DevicePlatform" AS ENUM ('ANDROID', 'IOS');

-- CreateTable
CREATE TABLE "notification_devices" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "token" VARCHAR(4096) NOT NULL,
    "platform" "DevicePlatform" NOT NULL,
    "app_version" VARCHAR(40),
    "enabled" BOOLEAN NOT NULL DEFAULT true,
    "last_seen_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "notification_devices_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "notifications" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "type" "NotificationType" NOT NULL,
    "title" VARCHAR(120) NOT NULL,
    "body" VARCHAR(300) NOT NULL,
    "deep_link" VARCHAR(200),
    "metadata_json" JSONB,
    "dedupe_key" VARCHAR(200),
    "read_at" TIMESTAMP(3),
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "notifications_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "notification_preferences" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "security_enabled" BOOLEAN NOT NULL DEFAULT true,
    "account_enabled" BOOLEAN NOT NULL DEFAULT true,
    "permission_enabled" BOOLEAN NOT NULL DEFAULT true,
    "location_enabled" BOOLEAN NOT NULL DEFAULT true,
    "chat_enabled" BOOLEAN NOT NULL DEFAULT true,
    "communication_enabled" BOOLEAN NOT NULL DEFAULT true,
    "system_enabled" BOOLEAN NOT NULL DEFAULT true,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "notification_preferences_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "notification_devices_token_key" ON "notification_devices"("token");

-- CreateIndex
CREATE INDEX "notification_devices_user_id_idx" ON "notification_devices"("user_id");

-- CreateIndex
CREATE INDEX "notification_devices_enabled_idx" ON "notification_devices"("enabled");

-- CreateIndex
CREATE INDEX "notifications_user_id_idx" ON "notifications"("user_id");

-- CreateIndex
CREATE INDEX "notifications_created_at_idx" ON "notifications"("created_at");

-- CreateIndex
CREATE INDEX "notifications_read_at_idx" ON "notifications"("read_at");

-- CreateIndex
CREATE UNIQUE INDEX "notifications_user_id_dedupe_key_key" ON "notifications"("user_id", "dedupe_key");

-- CreateIndex
CREATE UNIQUE INDEX "notification_preferences_user_id_key" ON "notification_preferences"("user_id");

-- AddForeignKey
ALTER TABLE "notification_devices" ADD CONSTRAINT "notification_devices_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "notifications" ADD CONSTRAINT "notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "notification_preferences" ADD CONSTRAINT "notification_preferences_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

