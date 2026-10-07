-- AlterEnum
ALTER TYPE "ChatActionType" ADD VALUE 'SHARE_CONTACT';

-- AlterTable
ALTER TABLE "chat_actions" ADD COLUMN     "shared_contact_name" VARCHAR(120),
ADD COLUMN     "shared_contact_phone" VARCHAR(32),
ADD COLUMN     "shared_contact_query" VARCHAR(120);
