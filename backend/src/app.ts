import Fastify, { type FastifyReply, type FastifyRequest } from "fastify";
import rateLimit from "@fastify/rate-limit";
import { google } from "googleapis";
import { z } from "zod";

import { config } from "./config.js";
import { prisma } from "./db.js";
import { encrypt, randomToken, sha256 } from "./lib/crypto.js";
import { MOCK_TASK_LISTS } from "./mock.js";
import { sseHub } from "./lib/sse.js";
import { SyncService } from "./services/sync-service.js";
import { claimOAuthState, createOAuthState } from "./services/oauth-state-service.js";

declare module "fastify" {
  interface FastifyRequest {
    userId?: string;
  }
}

const mutationBaseSchema = z.object({
  id: z.string().uuid(),
  noteId: z.string().uuid(),
  baseServerVersion: z.number().int().nonnegative(),
});

const mutationSchema = z.discriminatedUnion("type", [
  mutationBaseSchema.extend({
    type: z.literal("upsert_note"),
    payload: z.object({
      content: z.string().max(1_000_000),
      taskListId: z.string().min(1).max(4096),
      taskListNameCache: z.string().max(4096).nullish().transform((value) => value ?? null),
      dueDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).nullish().transform((value) => value ?? null),
    }),
  }),
  mutationBaseSchema.extend({
    type: z.literal("delete_note"),
    payload: z.object({}).strict(),
  }),
]);

const preferencesSchema = z.object({
  selectedTaskListIds: z.array(z.string().min(1)),
  defaultTaskListId: z.string().min(1).nullish().transform((value) => value ?? null),
});

function desktopRedirectTarget(url: string) {
  return `${url}${url.includes("?") ? "&" : "?"}`;
}

function httpError(statusCode: number, message: string) {
  return Object.assign(new Error(message), { statusCode });
}

const cronOidcPayloadSchema = z.object({
  aud: z.string(),
  email: z.string().email().optional(),
  email_verified: z.union([z.literal("true"), z.literal("false")]).optional(),
  iss: z.string().optional(),
});

function allowedGoogleEmails(): string[] {
  return config.ALLOWED_GOOGLE_EMAILS
    .split(",")
    .map((email) => email.trim().toLowerCase())
    .filter((email) => email.length > 0);
}

function isAllowedDesktopRedirectUri(redirectUri: string) {
  return redirectUri === config.APP_DESKTOP_REDIRECT_URI;
}

const GOOGLE_AUTH_SCOPES = [
  "https://www.googleapis.com/auth/tasks",
  "openid",
  "email",
  "profile",
];

function escapeHtml(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("\"", "&quot;")
    .replaceAll("'", "&#39;");
}

function sendDesktopRedirectPage(reply: FastifyReply, desktopRedirectURL: string) {
  const escapedURL = escapeHtml(desktopRedirectURL);
  const scriptURL = JSON.stringify(desktopRedirectURL);

  return reply
    .type("text/html; charset=utf-8")
    .send(`<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Opening MD Sticky Notes</title>
    <style>
      :root {
        color-scheme: dark;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      }
      body {
        margin: 0;
        min-height: 100vh;
        display: grid;
        place-items: center;
        background: #111111;
        color: #f3f1ec;
      }
      .card {
        width: min(480px, calc(100vw - 32px));
        padding: 28px;
        border-radius: 20px;
        background: #1a1715;
        border: 1px solid #3b322d;
        box-shadow: 0 24px 80px rgba(0, 0, 0, 0.35);
      }
      h1 {
        margin: 0 0 12px;
        font-size: 28px;
        line-height: 1.1;
      }
      p {
        margin: 0 0 12px;
        color: #d2cbc5;
        line-height: 1.5;
      }
      a.button {
        display: inline-block;
        margin-top: 12px;
        padding: 11px 16px;
        border-radius: 999px;
        background: #f6e38b;
        color: #1f1b17;
        font-weight: 700;
        text-decoration: none;
      }
      .hint {
        margin-top: 14px;
        font-size: 13px;
        color: #a89f97;
      }
    </style>
  </head>
  <body>
    <main class="card">
      <h1>Opening MD Sticky Notes…</h1>
      <p>The sign-in succeeded. If the app does not come to the front automatically, use the button below.</p>
      <a class="button" href="${escapedURL}">Open MD Sticky Notes</a>
      <p class="hint">You can close this tab after the app opens.</p>
    </main>
    <script>
      const desktopURL = ${scriptURL};
      window.location.replace(desktopURL);
      setTimeout(() => {
        window.location.href = desktopURL;
      }, 400);
    </script>
  </body>
</html>`);
}

export async function buildApp() {
  const app = Fastify({ logger: true });
  const syncService = new SyncService(app.log);
  let backgroundSyncTimer: NodeJS.Timeout | undefined;
  let isClosing = false;

  await app.register(rateLimit, {
    global: true,
    max: 300,
    timeWindow: "1 minute",
  });

  app.addHook("onRequest", async (_request, reply) => {
    reply.header("X-Content-Type-Options", "nosniff");
    reply.header("X-Frame-Options", "DENY");
    reply.header("Referrer-Policy", "no-referrer");
    reply.header(
      "Content-Security-Policy",
      "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",
    );
  });

  app.setErrorHandler((error, request, reply) => {
    const candidate = error as { statusCode?: unknown; message?: unknown };
    const statusCode = error instanceof z.ZodError
      ? 400
      : typeof candidate.statusCode === "number" ? candidate.statusCode : 500;
    if (statusCode >= 500) {
      request.log.error({ err: error }, "Unhandled request error.");
    }
    reply.code(statusCode).send({
      error: statusCode >= 500
        ? "An internal error occurred."
        : typeof candidate.message === "string" ? candidate.message : "Invalid request.",
    });
  });

  const scheduleBackgroundSync = () => {
    if (isClosing) return;
    backgroundSyncTimer = setTimeout(async () => {
      try {
        await syncService.runScheduledSync();
      } catch (error) {
        app.log.error({ err: error }, "Background sync loop failed.");
      } finally {
        scheduleBackgroundSync();
      }
    }, config.GOOGLE_SYNC_INTERVAL_MS);
    backgroundSyncTimer.unref();
  };

  app.addHook("onReady", async () => {
    scheduleBackgroundSync();
  });

  app.addHook("onClose", async () => {
    isClosing = true;
    if (backgroundSyncTimer) clearTimeout(backgroundSyncTimer);
    await prisma.$disconnect();
  });

  app.decorateRequest("userId", undefined);

  async function issueDesktopAuthCode(userId: string, desktopRedirectUri: string) {
    const rawAuthCode = randomToken();
    await prisma.appAuthCode.create({
      data: {
        userId,
        codeHash: sha256(rawAuthCode),
        redirectUri: desktopRedirectUri,
        expiresAt: new Date(Date.now() + 5 * 60_000),
      },
    });
    return rawAuthCode;
  }

  async function requireAuth(request: FastifyRequest) {
    const header = request.headers.authorization;
    if (!header?.startsWith("Bearer ")) {
      throw httpError(401, "Missing bearer token.");
    }
    const token = header.slice("Bearer ".length);
    const tokenHash = sha256(token);
    const session = await prisma.appSession.findUnique({
      where: { tokenHash },
    });
    if (!session || session.expiresAt < new Date()) {
      throw httpError(401, "Session expired.");
    }
    request.userId = session.userId;
    await prisma.appSession.update({
      where: { id: session.id },
      data: { lastSeenAt: new Date() },
    });
  }

  async function requireInternalCronAuth(request: FastifyRequest) {
    if (!config.INTERNAL_CRON_AUDIENCE) {
      throw httpError(503, "Internal cron audience is not configured.");
    }

    const header = request.headers.authorization;
    if (!header?.startsWith("Bearer ")) {
      throw httpError(401, "Missing bearer token.");
    }

    const token = header.slice("Bearer ".length);
    const verifyURL = new URL("https://oauth2.googleapis.com/tokeninfo");
    verifyURL.searchParams.set("id_token", token);

    const response = await fetch(verifyURL);
    if (!response.ok) {
      throw httpError(401, "Invalid cron identity token.");
    }

    const payload = cronOidcPayloadSchema.parse(await response.json());
    if (payload.aud !== config.INTERNAL_CRON_AUDIENCE) {
      throw httpError(403, "Cron identity token has an unexpected audience.");
    }
    if (payload.iss && !["accounts.google.com", "https://accounts.google.com"].includes(payload.iss)) {
      throw httpError(403, "Cron identity token has an unexpected issuer.");
    }
    if (payload.email_verified && payload.email_verified !== "true") {
      throw httpError(403, "Cron identity token email is not verified.");
    }
    if (config.INTERNAL_CRON_SERVICE_ACCOUNT_EMAIL) {
      const expectedEmail = config.INTERNAL_CRON_SERVICE_ACCOUNT_EMAIL.toLowerCase();
      if (!payload.email || payload.email.toLowerCase() !== expectedEmail) {
        throw httpError(403, "Cron identity token is not from the configured scheduler service account.");
      }
    }
  }

  app.get("/healthz", async (_request, reply) => {
    try {
      await prisma.$queryRaw`SELECT 1`;
      return {
        ok: true,
        database: "ok",
        releaseSha: config.APP_RELEASE_SHA,
        provider: config.SYNC_PROVIDER,
        mockTaskLists: config.SYNC_PROVIDER === "mock" ? MOCK_TASK_LISTS.length : 0,
      };
    } catch (error) {
      app.log.error({ err: error }, "Database readiness check failed.");
      return reply.code(503).send({
        ok: false,
        database: "unavailable",
        releaseSha: config.APP_RELEASE_SHA,
      });
    }
  });

  app.get("/auth/google/start", async (request, reply) => {
    const query = z.object({
      desktop_redirect_uri: z.string().optional(),
    }).parse(request.query);

    const desktopRedirectUri = query.desktop_redirect_uri ?? config.APP_DESKTOP_REDIRECT_URI;
    if (!isAllowedDesktopRedirectUri(desktopRedirectUri)) {
      throw httpError(400, "Unrecognized desktop redirect URI.");
    }
    if (config.SYNC_PROVIDER === "mock") {
      const user = await syncService.getOrCreateMockUser(config.MOCK_USER_EMAIL);
      const authCode = await issueDesktopAuthCode(user.id, desktopRedirectUri);
      return sendDesktopRedirectPage(
        reply,
        `${desktopRedirectTarget(desktopRedirectUri)}auth_code=${encodeURIComponent(authCode)}`,
      );
      return;
    }

    const state = await createOAuthState(desktopRedirectUri);
    const oauth2 = new google.auth.OAuth2(
      config.GOOGLE_CLIENT_ID,
      config.GOOGLE_CLIENT_SECRET,
      config.GOOGLE_REDIRECT_URI,
    );
    const url = oauth2.generateAuthUrl({
      access_type: "offline",
      include_granted_scopes: true,
      prompt: "consent",
      scope: GOOGLE_AUTH_SCOPES,
      state,
    });
    reply.redirect(url);
  });

  app.get("/auth/google/callback", async (request, reply) => {
    if (config.SYNC_PROVIDER === "mock") {
      return reply.code(404).send({ error: "Mock sync provider does not use OAuth callbacks." });
    }

    const query = z.object({
      code: z.string().optional(),
      state: z.string().optional(),
      error: z.string().optional(),
    }).parse(request.query);

    if (!query.state) {
      return reply.code(400).send({ error: "Missing OAuth callback parameters." });
    }
    const oauthState = await claimOAuthState(query.state);
    if (query.error) {
      return reply.code(400).send({ error: "Google sign-in was cancelled or denied." });
    }
    if (!query.code) {
      return reply.code(400).send({ error: "Missing OAuth callback parameters." });
    }
    if (!isAllowedDesktopRedirectUri(oauthState.desktopRedirectUri)) {
      throw httpError(400, "Unrecognized desktop redirect URI.");
    }

    const oauth2 = new google.auth.OAuth2(
      config.GOOGLE_CLIENT_ID,
      config.GOOGLE_CLIENT_SECRET,
      config.GOOGLE_REDIRECT_URI,
    );
    const { tokens } = await oauth2.getToken(query.code);
    if (!tokens.refresh_token || !tokens.access_token) {
      throw httpError(400, "Google OAuth did not return a refresh token.");
    }
    oauth2.setCredentials(tokens);

    let email: string | null = null;
    let subject: string | undefined;

    if (tokens.id_token) {
      const ticket = await oauth2.verifyIdToken({
        idToken: tokens.id_token,
        audience: config.GOOGLE_CLIENT_ID,
      });
      const payload = ticket.getPayload();
      email = payload?.email?.toLowerCase() ?? null;
      subject = payload?.sub;
    }

    if (!subject) {
      const oauth2Info = await google.oauth2("v2").userinfo.get({ auth: oauth2 });
      email = oauth2Info.data.email?.toLowerCase() ?? email;
      subject = oauth2Info.data.id ?? undefined;
    }

    if (!subject) {
      throw httpError(400, "Google OAuth did not return a stable subject.");
    }

    const allowedEmails = allowedGoogleEmails();
    if (allowedEmails.length > 0 && (!email || !allowedEmails.includes(email))) {
      throw httpError(403, "This Google account is not allowed for this local backend.");
    }

    const user = await syncService.getOrCreateUserByGoogleSubject(subject, email);
    const encryptedRefreshToken = encrypt(tokens.refresh_token, config.APP_ENCRYPTION_KEY);

    await prisma.googleAccount.upsert({
      where: { googleSubject: subject },
      create: {
        userId: user.id,
        googleSubject: subject,
        email: email ?? undefined,
        refreshTokenCiphertext: encryptedRefreshToken.ciphertext,
        refreshTokenIv: encryptedRefreshToken.iv,
        refreshTokenTag: encryptedRefreshToken.tag,
        scope: tokens.scope ?? GOOGLE_AUTH_SCOPES.join(" "),
        tokenType: tokens.token_type ?? undefined,
      },
      update: {
        userId: user.id,
        email: email ?? undefined,
        refreshTokenCiphertext: encryptedRefreshToken.ciphertext,
        refreshTokenIv: encryptedRefreshToken.iv,
        refreshTokenTag: encryptedRefreshToken.tag,
        scope: tokens.scope ?? GOOGLE_AUTH_SCOPES.join(" "),
        tokenType: tokens.token_type ?? undefined,
        authStatus: "connected",
      },
    });

    await prisma.oAuthState.update({
      where: { id: oauthState.id },
      data: { userId: user.id },
    });
    const rawAuthCode = await issueDesktopAuthCode(user.id, oauthState.desktopRedirectUri);

    return sendDesktopRedirectPage(
      reply,
      `${desktopRedirectTarget(oauthState.desktopRedirectUri)}auth_code=${encodeURIComponent(rawAuthCode)}`,
    );
  });

  app.post("/auth/app/exchange", async (request) => {
    const body = z.object({
      authCode: z.string().min(1),
    }).parse(request.body);
    const codeHash = sha256(body.authCode);
    const authCode = await prisma.appAuthCode.findUnique({
      where: { codeHash },
    });
    if (!authCode || authCode.expiresAt < new Date() || authCode.usedAt) {
      throw httpError(401, "Auth code is invalid or expired.");
    }

    const rawSessionToken = randomToken();
    const session = await prisma.$transaction(async (tx) => {
      const claimed = await tx.appAuthCode.updateMany({
        where: {
          id: authCode.id,
          usedAt: null,
          expiresAt: { gt: new Date() },
        },
        data: { usedAt: new Date() },
      });
      if (claimed.count !== 1) {
        throw httpError(401, "Auth code is invalid or expired.");
      }
      return tx.appSession.create({
        data: {
          userId: authCode.userId,
          tokenHash: sha256(rawSessionToken),
          expiresAt: new Date(Date.now() + config.SESSION_TTL_DAYS * 24 * 60 * 60 * 1000),
        },
      });
    });

    return {
      sessionToken: rawSessionToken,
      expiresAt: session.expiresAt.toISOString(),
      bootstrap: await syncService.bootstrap(authCode.userId),
    };
  });

  app.get("/v1/bootstrap", { preHandler: requireAuth }, async (request) => {
    return syncService.bootstrap(request.userId!);
  });

  app.get("/v1/task-lists", { preHandler: requireAuth }, async (request) => {
    return {
      taskLists: await syncService.listTaskListsForUser(request.userId!),
    };
  });

  app.patch("/v1/preferences/sync", { preHandler: requireAuth }, async (request) => {
    const body = preferencesSchema.parse(request.body);
    return {
      taskLists: await syncService.updateTaskListPreferences(
        request.userId!,
        body.selectedTaskListIds,
        body.defaultTaskListId,
      ),
    };
  });

  app.post("/v1/mutations", { preHandler: requireAuth }, async (request) => {
    const body = z.object({
      mutations: z.array(mutationSchema),
    }).parse(request.body);
    return syncService.applyMutations(request.userId!, body.mutations);
  });

  app.post("/v1/sync/now", { preHandler: requireAuth }, async (request) => {
    return syncService.syncNow(request.userId!);
  });

  app.post("/internal/cron/sync", { preHandler: requireInternalCronAuth }, async () => {
    return syncService.runScheduledSync();
  });

  app.get("/v1/events/stream", { preHandler: requireAuth }, async (request, reply) => {
    const query = z.object({
      since: z.coerce.number().int().nonnegative().optional(),
    }).parse(request.query);
    const userId = request.userId!;

    reply.raw.setHeader("Content-Type", "text/event-stream");
    reply.raw.setHeader("Cache-Control", "no-cache, no-transform");
    reply.raw.setHeader("Connection", "keep-alive");
    reply.raw.setHeader("X-Accel-Buffering", "no");
    reply.raw.flushHeaders();
    reply.hijack();
    reply.raw.socket?.setNoDelay(true);
    reply.raw.write(": connected\n\n");

    let cursor = query.since ?? 0;
    let isClosed = false;
    let flushPromise: Promise<void> | null = null;

    const flushEvents = () => {
      if (isClosed) return Promise.resolve();
      if (flushPromise) return flushPromise;

      flushPromise = (async () => {
        while (!isClosed) {
          const events = await prisma.eventLog.findMany({
            where: {
              userId,
              sequence: { gt: cursor },
            },
            orderBy: { sequence: "asc" },
            take: 500,
          });
          for (const event of events) {
            if (isClosed) return;
            reply.raw.write(`event: ${event.type}\n`);
            reply.raw.write(`data: ${JSON.stringify({
              sequence: event.sequence,
              type: event.type,
              payload: event.payload,
            })}\n\n`);
            cursor = event.sequence;
          }
          if (events.length < 500) return;
        }
      })().finally(() => {
        flushPromise = null;
      });
      return flushPromise;
    };

    await flushEvents();

    // The emitter gives same-instance low latency. Database polling is the source
    // of truth and delivers events produced by any Railway replica.
    const unsubscribe = sseHub.subscribe(userId, () => {
      void flushEvents();
    });
    const poller = setInterval(() => {
      void flushEvents();
    }, 1_000);

    const heartbeat = setInterval(() => {
      reply.raw.write(": keep-alive\n\n");
    }, 15_000);

    request.raw.on("close", () => {
      isClosed = true;
      clearInterval(heartbeat);
      clearInterval(poller);
      unsubscribe();
    });
  });

  return app;
}
