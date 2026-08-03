-- Persist opaque one-time OAuth state instead of trusting browser-returned JSON.
CREATE TABLE "OAuthState" (
    "id" TEXT NOT NULL,
    "userId" TEXT,
    "stateHash" TEXT NOT NULL,
    "desktopRedirectUri" TEXT NOT NULL,
    "expiresAt" TIMESTAMP(3) NOT NULL,
    "usedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "OAuthState_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "OAuthState_stateHash_key" ON "OAuthState"("stateHash");
CREATE INDEX "OAuthState_expiresAt_idx" ON "OAuthState"("expiresAt");

ALTER TABLE "OAuthState"
ADD CONSTRAINT "OAuthState_userId_fkey"
FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- A fingerprint distinguishes our own Google Tasks echo from a real remote edit.
ALTER TABLE "Note" ADD COLUMN "lastProjectedFingerprint" TEXT;

-- Workers clear only the projection generation they actually processed.
ALTER TABLE "ProjectionJob" ADD COLUMN "generation" INTEGER NOT NULL DEFAULT 1;
