import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { after, before, beforeEach, test } from "node:test";

import { buildApp } from "../src/app.js";
import { prisma } from "../src/db.js";
import { sha256 } from "../src/lib/crypto.js";
import {
  deriveNoteContentParts,
  plainTaskToMarkdown,
  projectedTaskFingerprint,
} from "../src/lib/markdown.js";
import { claimOAuthState, createOAuthState } from "../src/services/oauth-state-service.js";
import { isProjectedTaskEcho, SyncService } from "../src/services/sync-service.js";

const app = await buildApp();

before(async () => {
  await app.ready();
});

beforeEach(async () => {
  await prisma.oAuthState.deleteMany();
  await prisma.user.deleteMany();
});

after(async () => {
  await app.close();
});

async function startMockSignIn() {
  const start = await app.inject({ method: "GET", url: "/auth/google/start" });
  assert.equal(start.statusCode, 200);
  const authCode = /auth_code=([A-Za-z0-9_-]+)/.exec(start.body)?.[1];
  assert.ok(authCode, "mock sign-in page should contain a desktop auth code");
  return authCode;
}

async function authenticatedSession() {
  const authCode = await startMockSignIn();
  const exchange = await app.inject({
    method: "POST",
    url: "/auth/app/exchange",
    payload: { authCode },
  });
  assert.equal(exchange.statusCode, 200, exchange.body);
  const body = exchange.json<{ sessionToken: string }>();
  const session = await prisma.appSession.findUniqueOrThrow({
    where: { tokenHash: sha256(body.sessionToken) },
  });
  return { token: body.sessionToken, userId: session.userId };
}

function upsertMutation(noteId: string, baseServerVersion: number, content = "# Title\n\nRich **Markdown**") {
  return {
    id: randomUUID(),
    type: "upsert_note",
    noteId,
    baseServerVersion,
    payload: {
      content,
      taskListId: "mock-inbox",
      taskListNameCache: "Inbox",
      dueDate: null,
    },
  };
}

test("health reports database readiness and the exact release SHA", async () => {
  const response = await app.inject({ method: "GET", url: "/healthz" });
  assert.equal(response.statusCode, 200);
  assert.deepEqual(response.json(), {
    ok: true,
    database: "ok",
    releaseSha: process.env.APP_RELEASE_SHA,
    provider: "mock",
    mockTaskLists: 3,
  });
});

test("auth-code redemption is atomic under concurrent exchange", async () => {
  const authCode = await startMockSignIn();
  const exchanges = await Promise.all([
    app.inject({ method: "POST", url: "/auth/app/exchange", payload: { authCode } }),
    app.inject({ method: "POST", url: "/auth/app/exchange", payload: { authCode } }),
  ]);
  assert.deepEqual(exchanges.map((response) => response.statusCode).sort(), [200, 401]);
  assert.equal(await prisma.appSession.count(), 1);
});

test("opaque OAuth state rejects tampering, expiry, replay, and concurrent claims", async () => {
  const tamperTarget = await createOAuthState("mdstickynotes://auth/callback");
  await assert.rejects(claimOAuthState(`${tamperTarget}tampered`), /invalid or expired/);

  const expired = await createOAuthState("mdstickynotes://auth/callback", -1);
  await assert.rejects(claimOAuthState(expired), /invalid or expired/);

  const replay = await createOAuthState("mdstickynotes://auth/callback");
  await claimOAuthState(replay);
  await assert.rejects(claimOAuthState(replay), /invalid or expired/);

  const concurrent = await createOAuthState("mdstickynotes://auth/callback");
  const claims = await Promise.allSettled([claimOAuthState(concurrent), claimOAuthState(concurrent)]);
  assert.equal(claims.filter((claim) => claim.status === "fulfilled").length, 1);
  assert.equal(claims.filter((claim) => claim.status === "rejected").length, 1);
});

test("mutations are atomic, reject stale versions, and retry idempotently", async () => {
  const { token, userId } = await authenticatedSession();
  const headers = { authorization: `Bearer ${token}` };
  const noteId = randomUUID();
  const first = upsertMutation(noteId, 0);

  const applied = await app.inject({
    method: "POST",
    url: "/v1/mutations",
    headers,
    payload: { mutations: [first] },
  });
  assert.equal(applied.statusCode, 200, applied.body);
  assert.equal(applied.json().results[0].status, "applied");
  assert.equal(await prisma.note.count({ where: { userId, id: noteId } }), 1);
  assert.equal(await prisma.appliedMutation.count({ where: { userId, id: first.id } }), 1);
  assert.equal(await prisma.projectionJob.count({ where: { userId, noteId } }), 1);
  assert.equal(await prisma.eventLog.count({ where: { userId, noteId } }), 1);

  const duplicate = await app.inject({
    method: "POST",
    url: "/v1/mutations",
    headers,
    payload: { mutations: [first] },
  });
  assert.equal(duplicate.json().results[0].status, "duplicate");
  assert.equal(await prisma.eventLog.count({ where: { userId, noteId } }), 1);

  const stale = await app.inject({
    method: "POST",
    url: "/v1/mutations",
    headers,
    payload: { mutations: [upsertMutation(noteId, 0, "stale")] },
  });
  assert.equal(stale.json().results[0].status, "conflict");
  assert.equal(stale.json().results[0].note.serverVersion, 1);
  assert.equal(await prisma.note.findUniqueOrThrow({ where: { id: noteId } }).then((note) => note.bodyMarkdown), "# Title\n\nRich **Markdown**");
});

test("concurrent idempotent retries produce one write and one event", async () => {
  const { token, userId } = await authenticatedSession();
  const headers = { authorization: `Bearer ${token}` };
  const noteId = randomUUID();
  const mutation = upsertMutation(noteId, 0);
  const responses = await Promise.all([
    app.inject({ method: "POST", url: "/v1/mutations", headers, payload: { mutations: [mutation] } }),
    app.inject({ method: "POST", url: "/v1/mutations", headers, payload: { mutations: [mutation] } }),
  ]);
  assert.ok(responses.every((response) => response.statusCode === 200));
  assert.deepEqual(
    responses.map((response) => response.json().results[0].status).sort(),
    ["applied", "duplicate"],
  );
  assert.equal(await prisma.note.count({ where: { userId, id: noteId } }), 1);
  assert.equal(await prisma.appliedMutation.count({ where: { userId, id: mutation.id } }), 1);
  assert.equal(await prisma.eventLog.count({ where: { userId, noteId } }), 1);
});

test("authenticated notes cannot be unassigned", async () => {
  const { token } = await authenticatedSession();
  const response = await app.inject({
    method: "POST",
    url: "/v1/mutations",
    headers: { authorization: `Bearer ${token}` },
    payload: {
      mutations: [{
        ...upsertMutation(randomUUID(), 0),
        payload: { content: "note", taskListId: null, taskListNameCache: null, dueDate: null },
      }],
    },
  });
  assert.equal(response.statusCode, 400);
});

test("projection generations prevent a stale worker from clearing newer work", async () => {
  const { token, userId } = await authenticatedSession();
  const headers = { authorization: `Bearer ${token}` };
  const noteId = randomUUID();
  await app.inject({
    method: "POST", url: "/v1/mutations", headers,
    payload: { mutations: [upsertMutation(noteId, 0, "first")] },
  });
  const firstJob = await prisma.projectionJob.findUniqueOrThrow({
    where: { userId_noteId: { userId, noteId } },
  });
  await app.inject({
    method: "POST", url: "/v1/mutations", headers,
    payload: { mutations: [upsertMutation(noteId, 1, "second")] },
  });
  const secondJob = await prisma.projectionJob.findUniqueOrThrow({
    where: { userId_noteId: { userId, noteId } },
  });
  assert.equal(secondJob.generation, firstJob.generation + 1);
  const staleClear = await prisma.projectionJob.deleteMany({
    where: { id: firstJob.id, generation: firstJob.generation },
  });
  assert.equal(staleClear.count, 0);

  const synchronized = await app.inject({ method: "POST", url: "/v1/sync/now", headers });
  assert.equal(synchronized.statusCode, 200, synchronized.body);
  assert.equal(await prisma.projectionJob.count({ where: { userId, noteId } }), 0);
  assert.equal((await prisma.note.findUniqueOrThrow({ where: { id: noteId } })).pendingProjection, false);
});

test("database event replay works without an in-process publish", async () => {
  const { token, userId } = await authenticatedSession();
  const noteId = randomUUID();
  await prisma.eventLog.create({
    data: { userId, noteId, type: "note.delete", payload: { noteId, serverVersion: 3 } },
  });
  const address = await app.listen({ host: "127.0.0.1", port: 0 });
  const controller = new AbortController();
  const response = await fetch(`${address}/v1/events/stream?since=0`, {
    headers: { authorization: `Bearer ${token}` },
    signal: controller.signal,
  });
  assert.equal(response.status, 200);
  const reader = response.body!.getReader();
  const chunk = await reader.read();
  const text = new TextDecoder().decode(chunk.value);
  controller.abort();
  assert.match(text, /event: note\.delete/);
  assert.match(text, new RegExp(noteId));
});

test("sync leases exclude peers, renew ownership, and allow takeover after expiry", async () => {
  const user = await prisma.user.create({ data: { email: "lease@example.com" } });
  const service = new SyncService(console as never) as unknown as {
    acquireSyncLease(userId: string, ownerId: string): Promise<boolean>;
    renewSyncLease(userId: string, ownerId: string): Promise<boolean>;
    releaseSyncLease(userId: string, ownerId: string): Promise<void>;
  };
  assert.equal(await service.acquireSyncLease(user.id, "owner-a"), true);
  assert.equal(await service.acquireSyncLease(user.id, "owner-b"), false);
  const beforeRenewal = await prisma.userSyncLease.findUniqueOrThrow({ where: { userId: user.id } });
  assert.equal(await service.renewSyncLease(user.id, "owner-a"), true);
  const afterRenewal = await prisma.userSyncLease.findUniqueOrThrow({ where: { userId: user.id } });
  assert.ok(afterRenewal.expiresAt >= beforeRenewal.expiresAt);
  await prisma.userSyncLease.update({
    where: { userId: user.id },
    data: { expiresAt: new Date(Date.now() - 1_000) },
  });
  assert.equal(await service.acquireSyncLease(user.id, "owner-b"), true);
  await service.releaseSyncLease(user.id, "owner-b");
});

test("Markdown projection preserves rich echo content and applies a genuine Google edit", async () => {
  const local = deriveNoteContentParts("# Rich title\n\nBody with **formatting**");
  assert.equal(local.bodyMarkdown, "# Rich title\n\nBody with **formatting**");
  const projected = projectedTaskFingerprint({
    title: local.title,
    notes: local.bodyPlaintext,
    taskListId: "list-1",
    dueDate: null,
  });
  assert.equal(isProjectedTaskEcho(projected, projected, null), true);

  const user = await prisma.user.create({ data: { email: "remote-edit@example.com" } });
  const subscription = await prisma.taskListSubscription.create({
    data: {
      userId: user.id,
      googleTaskListId: "list-1",
      title: "Inbox",
      isSelected: true,
      isDefault: true,
    },
  });
  const noteId = randomUUID();
  await prisma.note.create({
    data: {
      id: noteId,
      userId: user.id,
      title: local.title,
      bodyMarkdown: local.bodyMarkdown,
      bodyPlaintext: local.bodyPlaintext,
      googleTaskListId: "list-1",
      taskListNameCache: "Inbox",
      googleTaskId: "google-task-1",
      lastProjectedFingerprint: projected,
    },
  });
  const service = new SyncService(console as never);
  const echoResult = await service.reconcileRemoteTask(user.id, subscription, {
    id: "google-task-1",
    title: local.title,
    notes: local.bodyPlaintext,
    dueDate: null,
    updatedAt: new Date(),
    etag: "echo-etag",
    deleted: false,
    completed: false,
  });
  assert.equal(echoResult, "echo");
  const afterEcho = await prisma.note.findUniqueOrThrow({ where: { id: noteId } });
  assert.equal(afterEcho.bodyMarkdown, local.bodyMarkdown);
  assert.equal(afterEcho.serverVersion, 1);
  assert.equal(await prisma.eventLog.count({ where: { userId: user.id, noteId } }), 0);

  const remote = projectedTaskFingerprint({
    title: "Google changed this",
    notes: "plain replacement",
    taskListId: "list-1",
    dueDate: null,
  });
  assert.equal(isProjectedTaskEcho(remote, projected, projected), false);
  assert.equal(plainTaskToMarkdown("Google changed this", "plain replacement"), "Google changed this\n\nplain replacement");

  await prisma.note.update({ where: { id: noteId }, data: { pendingProjection: true } });
  await prisma.projectionJob.create({
    data: { userId: user.id, noteId, operation: "upsert" },
  });
  const changedResult = await service.reconcileRemoteTask(user.id, subscription, {
    id: "google-task-1",
    title: "Google changed this",
    notes: "plain replacement",
    dueDate: null,
    updatedAt: new Date(),
    etag: "changed-etag",
    deleted: false,
    completed: false,
  });
  assert.equal(changedResult, "changed");
  const afterChange = await prisma.note.findUniqueOrThrow({ where: { id: noteId } });
  assert.equal(afterChange.bodyMarkdown, "Google changed this\n\nplain replacement");
  assert.equal(afterChange.serverVersion, 2);
  assert.equal(afterChange.pendingProjection, false);
  assert.equal(await prisma.projectionJob.count({ where: { userId: user.id, noteId } }), 0);
  assert.equal(await prisma.eventLog.count({ where: { userId: user.id, noteId } }), 1);
});
