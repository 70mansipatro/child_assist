-- AlterTable
ALTER TABLE "location_history" ADD COLUMN     "address" VARCHAR(1000),
ADD COLUMN     "city" VARCHAR(255),
ADD COLUMN     "country" VARCHAR(255),
ADD COLUMN     "locality" VARCHAR(255),
ADD COLUMN     "place_name" VARCHAR(255),
ADD COLUMN     "postal_code" VARCHAR(32),
ADD COLUMN     "state" VARCHAR(255),
ADD COLUMN     "street" VARCHAR(255);
