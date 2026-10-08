-- Additive only: the question waiting on photos shown for a "find it and explain it" request,
-- answered automatically once the user picks one. No image data is stored.

-- AlterTable
ALTER TABLE "photo_references" ADD COLUMN     "analysis_question" VARCHAR(500);
