-- AlterTable: additive only. Existing rows keep NULL (no document picked yet).
ALTER TABLE "chat_actions" ADD COLUMN     "document_id" VARCHAR(64),
ADD COLUMN     "document_name" VARCHAR(255),
ADD COLUMN     "document_type" VARCHAR(8);
