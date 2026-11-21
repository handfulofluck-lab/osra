CREATE TABLE "ChildInternetOperation" (
    "childId" TEXT NOT NULL,
    "id" TEXT NOT NULL,
    "generation" INTEGER NOT NULL,
    "desiredPaused" BOOLEAN NOT NULL,
    "requestedAt" TIMESTAMPTZ(3) NOT NULL,
    "targets" JSONB NOT NULL,
    CONSTRAINT "ChildInternetOperation_pkey" PRIMARY KEY ("childId")
);

CREATE UNIQUE INDEX "ChildInternetOperation_id_key" ON "ChildInternetOperation"("id");

ALTER TABLE "ChildInternetOperation" ADD CONSTRAINT "ChildInternetOperation_childId_fkey"
    FOREIGN KEY ("childId") REFERENCES "Child"("id") ON DELETE CASCADE ON UPDATE CASCADE;
