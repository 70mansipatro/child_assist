-- CreateEnum
CREATE TYPE "PermissionType" AS ENUM ('LOCATION', 'MICROPHONE', 'CAMERA', 'PHOTOS', 'NOTIFICATIONS', 'DOCUMENTS');

-- CreateEnum
CREATE TYPE "PermissionStatus" AS ENUM ('UNKNOWN', 'GRANTED', 'DENIED', 'RESTRICTED', 'LIMITED');

-- AlterTable
ALTER TABLE "users" ADD COLUMN     "profile_image_url" TEXT;

-- CreateTable
CREATE TABLE "user_permissions" (
    "id" UUID NOT NULL,
    "user_id" UUID NOT NULL,
    "permission" "PermissionType" NOT NULL,
    "status" "PermissionStatus" NOT NULL DEFAULT 'UNKNOWN',
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "user_permissions_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "user_permissions_user_id_permission_key" ON "user_permissions"("user_id", "permission");

-- AddForeignKey
ALTER TABLE "user_permissions" ADD CONSTRAINT "user_permissions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;
