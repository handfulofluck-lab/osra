-- ADR-0041 D1 / issue #619: a finite family plan and an opaque per-family purchase-account id.
ALTER TABLE "Family" ADD COLUMN "store_account_id" CHAR(32);
CREATE UNIQUE INDEX "Family_store_account_id_key" ON "Family"("store_account_id");

CREATE TABLE "family_purchases" (
  "id" TEXT NOT NULL,
  "family_id" TEXT NOT NULL,
  "source" TEXT NOT NULL,
  "product_id" TEXT NOT NULL,
  "store_ref" CHAR(64) NOT NULL,
  "status" TEXT NOT NULL,
  "expires_at" TIMESTAMP(3),
  "auto_renews" BOOLEAN NOT NULL,
  "last_verified_at" TIMESTAMP(3) NOT NULL,
  "cause" TEXT NOT NULL,
  "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "family_purchases_pkey" PRIMARY KEY ("id"),
  CONSTRAINT "family_purchases_family_id_fkey"
    FOREIGN KEY ("family_id") REFERENCES "Family"("id") ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE UNIQUE INDEX "family_purchases_source_store_ref_key" ON "family_purchases"("source", "store_ref");
CREATE INDEX "family_purchases_family_id_idx" ON "family_purchases"("family_id");
