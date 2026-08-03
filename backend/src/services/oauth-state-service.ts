import { prisma } from "../db.js";
import { randomToken, sha256 } from "../lib/crypto.js";

function invalidStateError() {
  return Object.assign(new Error("OAuth state is invalid or expired."), { statusCode: 400 });
}

export async function createOAuthState(desktopRedirectUri: string, ttlMs = 10 * 60_000) {
  const rawState = randomToken(32);
  await prisma.$transaction([
    prisma.oAuthState.deleteMany({ where: { expiresAt: { lt: new Date() } } }),
    prisma.oAuthState.create({
      data: {
        stateHash: sha256(rawState),
        desktopRedirectUri,
        expiresAt: new Date(Date.now() + ttlMs),
      },
    }),
  ]);
  return rawState;
}

export async function claimOAuthState(rawState: string) {
  return prisma.$transaction(async (tx) => {
    const state = await tx.oAuthState.findUnique({
      where: { stateHash: sha256(rawState) },
    });
    if (!state || state.expiresAt <= new Date() || state.usedAt) {
      throw invalidStateError();
    }
    const claimed = await tx.oAuthState.updateMany({
      where: {
        id: state.id,
        usedAt: null,
        expiresAt: { gt: new Date() },
      },
      data: { usedAt: new Date() },
    });
    if (claimed.count !== 1) throw invalidStateError();
    return state;
  });
}
