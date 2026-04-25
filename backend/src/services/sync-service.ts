import { randomUUID } from "node:crypto";
import type { FastifyBaseLogger } from "fastify";
import { Prisma, type GoogleAccount, type Note } from "@prisma/client";

import { config } from "../config.js";
import { prisma } from "../db.js";
import {
  listTaskLists,
  listTasksSince,
  createTask,
  updateTask,
  moveTaskBetweenLists,
  deleteTask,
  getTaskIfExists,
} from "../lib/google.js";
import { plainTaskToMarkdown } from "../lib/markdown.js";
import { MOCK_TASK_LISTS } from "../mock.js";
import { sseHub } from "../lib/sse.js";
import type { NoteDto, TaskListDto } from "../types.js";

type MutationEnvelope = {
  id: string;
  type:
    | "create_note"
    | "update_note_body"
    | "update_note_title"
    | "move_note_list"
    | "set_note_due_date"
    | "delete_note";
  noteId: string;
  payload: Record<string, string | null>;
};

function serviceError(statusCode: number, message: string) {
  return Object.assign(new Error(message), { statusCode });
}

function noteToDto(note: Note): NoteDto {
  return {
    id: note.id,
    title: note.title,
    bodyMarkdown: note.bodyMarkdown,
    bodyPlaintext: note.bodyPlaintext,
    taskListId: note.googleTaskListId ?? null,
    taskListNameCache: note.taskListNameCache ?? null,
    googleTaskId: note.googleTaskId ?? null,
    dueDate: note.dueDate ?? null,
    serverVersion: note.serverVersion,
    serverUpdatedAt: note.serverUpdatedAt.toISOString(),
    deletedAt: note.deletedAt?.toISOString() ?? null,
    deletionReason: note.deletionReason ?? null,
    pendingProjection: note.pendingProjection,
    lastProjectionError: note.lastProjectionError ?? null,
  };
}

async function appendEvent(
  userId: string,
  type: string,
  noteId: string | null,
  payload: Prisma.JsonObject,
) {
  const event = await prisma.eventLog.create({
    data: {
      userId,
      type,
      noteId: noteId ?? undefined,
      payload,
    },
  });
  sseHub.publish(userId, {
    sequence: event.sequence,
    type,
    payload,
  });
  return event.sequence;
}

function mergeProjectionOperation(existingOperation: string, nextOperation: string) {
  if (existingOperation === nextOperation) {
    return existingOperation;
  }

  if (existingOperation === "delete" || nextOperation === "delete") {
    return nextOperation === "delete" ? nextOperation : existingOperation;
  }

  const existingIsMove = existingOperation.startsWith("move:");
  const nextIsMove = nextOperation.startsWith("move:");
  if (existingIsMove) {
    return existingOperation;
  }
  if (nextIsMove) {
    return nextOperation;
  }

  return nextOperation;
}

function isGoogleTaskNotFoundError(error: unknown) {
  const candidate = error as {
    code?: number;
    status?: number;
    response?: { status?: number };
    message?: string;
  };
  const statusCode = candidate.response?.status ?? candidate.status ?? candidate.code;
  return statusCode === 404 || candidate.message?.includes("Requested entity was not found.") === true;
}

async function upsertProjectionJob(userId: string, noteId: string, operation: string) {
  const existing = await prisma.projectionJob.findUnique({
    where: {
      userId_noteId: {
        userId,
        noteId,
      },
    },
    select: {
      id: true,
      operation: true,
    },
  });

  if (!existing) {
    await prisma.projectionJob.create({
      data: {
        userId,
        noteId,
        operation,
      },
    });
    return;
  }

  await prisma.projectionJob.update({
    where: { id: existing.id },
    data: {
      operation: mergeProjectionOperation(existing.operation, operation),
      runAfter: new Date(),
      lastError: null,
    },
  });
}

function asString(payload: MutationEnvelope["payload"], key: string): string | null {
  return payload[key] ?? null;
}

export class SyncService {
  constructor(private readonly logger: FastifyBaseLogger) {}

  async getOrCreateMockUser(email?: string | null) {
    const normalizedEmail = email?.toLowerCase() ?? null;
    if (normalizedEmail) {
      const existing = await prisma.user.findFirst({
        where: { email: normalizedEmail },
      });
      if (existing) {
        return existing;
      }
    }

    return prisma.user.create({
      data: { email: normalizedEmail ?? undefined },
    });
  }

  async getOrCreateUserByGoogleSubject(googleSubject: string, email?: string | null) {
    const normalizedEmail = email?.toLowerCase() ?? null;
    const existingAccount = await prisma.googleAccount.findUnique({
      where: { googleSubject },
      include: { user: true },
    });

    if (existingAccount) {
      if (normalizedEmail && existingAccount.user.email !== normalizedEmail) {
        return prisma.user.update({
          where: { id: existingAccount.userId },
          data: { email: normalizedEmail },
        });
      }
      return existingAccount.user;
    }

    if (normalizedEmail) {
      const reusableUser = await prisma.user.findFirst({
        where: {
          email: normalizedEmail,
          googleAccounts: {
            none: {},
          },
        },
      });
      if (reusableUser) {
        return reusableUser;
      }
    }

    return prisma.user.create({
      data: { email: normalizedEmail ?? undefined },
    });
  }

  async listTaskListsForUser(userId: string): Promise<TaskListDto[]> {
    const remoteLists = config.SYNC_PROVIDER === "mock"
      ? MOCK_TASK_LISTS
      : await listTaskLists(await this.requireGoogleAccount(userId));
    const subscriptions = await prisma.taskListSubscription.findMany({
      where: { userId },
    });
    const subscriptionMap = new Map(subscriptions.map((list) => [list.googleTaskListId, list]));

    return remoteLists.map((list) => {
      const subscription = subscriptionMap.get(list.id);
      return {
        id: list.id,
        title: list.title,
        isSelected: subscription?.isSelected ?? false,
        isDefault: subscription?.isDefault ?? false,
      };
    });
  }

  async updateTaskListPreferences(
    userId: string,
    selectedTaskListIds: string[],
    defaultTaskListId: string | null,
  ) {
    const availableLists = await this.listTaskListsForUser(userId);
    const availableMap = new Map(availableLists.map((list) => [list.id, list.title]));

    await prisma.$transaction(async (tx) => {
      const existing = await tx.taskListSubscription.findMany({ where: { userId } });
      const existingIds = new Set(existing.map((list) => list.googleTaskListId));

      for (const taskListId of selectedTaskListIds) {
        const title = availableMap.get(taskListId) ?? "Untitled List";
        if (existingIds.has(taskListId)) {
          await tx.taskListSubscription.update({
            where: {
              userId_googleTaskListId: {
                userId,
                googleTaskListId: taskListId,
              },
            },
            data: {
              title,
              isSelected: true,
              isDefault: defaultTaskListId === taskListId,
            },
          });
        } else {
          await tx.taskListSubscription.create({
            data: {
              userId,
              googleTaskListId: taskListId,
              title,
              isSelected: true,
              isDefault: defaultTaskListId === taskListId,
            },
          });
        }
      }

      for (const subscription of existing) {
        const selected = selectedTaskListIds.includes(subscription.googleTaskListId);
        await tx.taskListSubscription.update({
          where: { id: subscription.id },
          data: {
            isSelected: selected,
            isDefault: selected && defaultTaskListId === subscription.googleTaskListId,
            title: availableMap.get(subscription.googleTaskListId) ?? subscription.title,
          },
        });
      }
    });

    await appendEvent(userId, "preferences.updated", null, {
      selectedTaskListIds,
      defaultTaskListId,
    });
    return this.listTaskListsForUser(userId);
  }

  async bootstrap(userId: string) {
    const notes = await prisma.note.findMany({
      where: {
        userId,
        deletedAt: null,
      },
      orderBy: { updatedAt: "asc" },
    });
    const taskLists = await prisma.taskListSubscription.findMany({
      where: { userId },
      orderBy: { title: "asc" },
    });
    const deletedNotes = await prisma.note.findMany({
      where: {
        userId,
        deletedAt: { not: null },
      },
      select: { id: true },
    });
    const latestEvent = await prisma.eventLog.findFirst({
      where: { userId },
      orderBy: { sequence: "desc" },
    });

    return {
      notes: notes.map(noteToDto),
      taskLists: taskLists.map((list) => ({
        id: list.googleTaskListId,
        title: list.title,
        isSelected: list.isSelected,
        isDefault: list.isDefault,
      })),
      deletedNoteIds: deletedNotes.map((note) => note.id),
      latestSequence: latestEvent?.sequence ?? 0,
    };
  }

  async runScheduledSync() {
    const users = config.SYNC_PROVIDER === "mock"
      ? await prisma.user.findMany({ select: { id: true } })
      : await prisma.user.findMany({
          where: {
            googleAccounts: {
              some: {
                authStatus: "connected",
              },
            },
          },
          select: { id: true },
        });

    let syncedUsers = 0;
    let skippedUsers = 0;
    let failedUsers = 0;

    for (const user of users) {
      try {
        const result = await this.runSyncNow(user.id);
        if (result.status === "already_running") {
          skippedUsers += 1;
        } else {
          syncedUsers += 1;
        }
      } catch (error) {
        failedUsers += 1;
        this.logger.error({ err: error, userId: user.id }, "Scheduled sync failed for user.");
      }
    }

    return {
      syncedUsers,
      skippedUsers,
      failedUsers,
      polledAt: new Date().toISOString(),
    };
  }

  private async latestSequenceForUser(userId: string) {
    const latestEvent = await prisma.eventLog.findFirst({
      where: { userId },
      orderBy: { sequence: "desc" },
    });
    return latestEvent?.sequence ?? 0;
  }

  private async markNoteDeletedFromGoogle(
    note: Pick<Note, "id" | "userId">,
    deletionReason: "google_deleted" | "google_completed",
    serverUpdatedAt: Date,
  ) {
    const deleted = await prisma.note.update({
      where: { id: note.id },
      data: {
        deletedAt: new Date(),
        deletionReason,
        pendingProjection: false,
        lastProjectionError: null,
        serverVersion: { increment: 1 },
        serverUpdatedAt,
      },
    });
    await prisma.projectionJob.deleteMany({
      where: {
        userId: note.userId,
        noteId: note.id,
      },
    });
    await appendEvent(note.userId, "note.delete", deleted.id, {
      noteId: deleted.id,
      deletionReason,
    });
    return deleted;
  }

  private async findOwnedNote(userId: string, noteId: string) {
    return prisma.note.findFirst({
      where: {
        id: noteId,
        userId,
      },
    });
  }

  private async findOwnedNoteByGoogleTaskId(
    userId: string,
    googleTaskId: string,
    preferredTaskListId?: string,
  ) {
    const matches = await prisma.note.findMany({
      where: {
        userId,
        googleTaskId,
      },
      orderBy: [
        { deletedAt: "asc" },
        { updatedAt: "asc" },
      ],
    });

    if (matches.length > 1) {
      this.logger.warn(
        {
          userId,
          googleTaskId,
          noteIds: matches.map((match) => match.id),
        },
        "Multiple local notes point at the same Google task id.",
      );
    }

    return matches.find((match) => preferredTaskListId && match.googleTaskListId === preferredTaskListId)
      ?? matches.find((match) => !match.deletedAt)
      ?? matches[0]
      ?? null;
  }

  private async findRemoteTaskListIdForTask(
    userId: string,
    googleAccount: GoogleAccount,
    googleTaskId: string,
    preferredTaskListIds: Array<string | null | undefined> = [],
  ) {
    const subscriptions = await prisma.taskListSubscription.findMany({
      where: { userId },
      orderBy: [
        { isSelected: "desc" },
        { isDefault: "desc" },
        { title: "asc" },
      ],
      select: {
        googleTaskListId: true,
      },
    });
    const candidateTaskListIds = [
      ...preferredTaskListIds,
      ...subscriptions.map((subscription) => subscription.googleTaskListId),
    ].filter((taskListId, index, values): taskListId is string => Boolean(taskListId) && values.indexOf(taskListId) === index);

    for (const taskListId of candidateTaskListIds) {
      const task = await getTaskIfExists(googleAccount, taskListId, googleTaskId);
      if (task) {
        return taskListId;
      }
    }

    return null;
  }

  private async assertNoteOwnershipAvailable(userId: string, noteId: string) {
    const ownedNote = await this.findOwnedNote(userId, noteId);
    if (ownedNote) {
      return ownedNote;
    }

    const foreignNote = await prisma.note.findUnique({
      where: { id: noteId },
      select: { userId: true },
    });
    if (foreignNote && foreignNote.userId !== userId) {
      throw serviceError(403, "This note does not belong to the authenticated user.");
    }

    return null;
  }

  private async loadOwnedNoteOrThrow(userId: string, noteId: string) {
    const note = await this.findOwnedNote(userId, noteId);
    if (!note) {
      throw serviceError(404, "Note not found for the authenticated user.");
    }
    return note;
  }

  async applyMutations(userId: string, mutations: MutationEnvelope[]) {
    let latestSequence = 0;

    for (const mutation of mutations) {
      const alreadyApplied = await prisma.appliedMutation.findFirst({
        where: {
          id: mutation.id,
          userId,
        },
      });
      if (alreadyApplied) {
        continue;
      }

      let note = await this.assertNoteOwnershipAvailable(userId, mutation.noteId);

      const taskListId = asString(mutation.payload, "taskListId");
      const taskListNameCache = asString(mutation.payload, "taskListNameCache");
      const bodyMarkdown = asString(mutation.payload, "content");
      const dueDate = asString(mutation.payload, "dueDate");
      const now = new Date();

      switch (mutation.type) {
      case "create_note":
      case "update_note_body":
      case "update_note_title": {
        const content = bodyMarkdown ?? note?.bodyMarkdown ?? "";
        const { deriveNoteContentParts } = await import("../lib/markdown.js");
        const parts = deriveNoteContentParts(content);
        if (note) {
          note = await prisma.note.update({
            where: { id: note.id },
            data: {
              title: parts.title,
              bodyMarkdown: content,
              bodyPlaintext: parts.bodyPlaintext,
              googleTaskListId: taskListId ?? note.googleTaskListId ?? undefined,
              taskListNameCache: taskListNameCache ?? note.taskListNameCache ?? undefined,
              dueDate: dueDate ?? note.dueDate ?? undefined,
              deletedAt: null,
              deletionReason: null,
              pendingProjection: true,
              lastProjectionError: null,
              serverVersion: { increment: 1 },
              serverUpdatedAt: now,
            },
          });
        } else {
          note = await prisma.note.create({
            data: {
              id: mutation.noteId,
              userId,
              title: parts.title,
              bodyMarkdown: content,
              bodyPlaintext: parts.bodyPlaintext,
              googleTaskListId: taskListId ?? undefined,
              taskListNameCache: taskListNameCache ?? undefined,
              dueDate: dueDate ?? undefined,
              serverUpdatedAt: now,
              pendingProjection: true,
            },
          });
        }
        await upsertProjectionJob(userId, note.id, note.googleTaskId ? "upsert" : "create");
        latestSequence = await appendEvent(userId, "note.upsert", note.id, {
          note: noteToDto(note),
        });
        break;
      }
      case "move_note_list": {
        const existingNote = await this.loadOwnedNoteOrThrow(userId, mutation.noteId);
        const previousTaskListId = existingNote.googleTaskListId;
        note = await prisma.note.update({
          where: { id: existingNote.id },
          data: {
            googleTaskListId: taskListId,
            taskListNameCache,
            pendingProjection: true,
            lastProjectionError: null,
            serverVersion: { increment: 1 },
            serverUpdatedAt: now,
          },
        });
        await upsertProjectionJob(
          userId,
          note.id,
          previousTaskListId ? `move:${previousTaskListId}` : "upsert",
        );
        latestSequence = await appendEvent(userId, "note.upsert", note.id, {
          note: noteToDto(note),
        });
        break;
      }
      case "set_note_due_date": {
        const existingNote = await this.loadOwnedNoteOrThrow(userId, mutation.noteId);
        note = await prisma.note.update({
          where: { id: existingNote.id },
          data: {
            dueDate,
            pendingProjection: true,
            lastProjectionError: null,
            serverVersion: { increment: 1 },
            serverUpdatedAt: now,
          },
        });
        await upsertProjectionJob(userId, note.id, "upsert");
        latestSequence = await appendEvent(userId, "note.upsert", note.id, {
          note: noteToDto(note),
        });
        break;
      }
      case "delete_note": {
        const existingNote = await this.assertNoteOwnershipAvailable(userId, mutation.noteId);
        if (!existingNote) {
          break;
        }
        const deletedNote = await prisma.note.update({
          where: { id: existingNote.id },
          data: {
            deletedAt: now,
            deletionReason: "desktop_delete",
            pendingProjection: true,
            lastProjectionError: null,
            serverVersion: { increment: 1 },
            serverUpdatedAt: now,
          },
        });
        note = deletedNote;
        await upsertProjectionJob(userId, deletedNote.id, "delete");
        latestSequence = await appendEvent(userId, "note.delete", deletedNote.id, {
          noteId: deletedNote.id,
          deletionReason: deletedNote.deletionReason ?? "desktop_delete",
        });
        break;
      }
      }

      await prisma.appliedMutation.create({
        data: {
          id: mutation.id,
          userId,
          noteId: mutation.noteId,
          type: mutation.type,
          payload: mutation.payload,
        },
      });
    }

    return { latestSequence };
  }

  async syncNow(userId: string) {
    return this.runSyncNow(userId);
  }

  private async runSyncNow(userId: string) {
    const ownerId = randomUUID();
    const acquired = await this.acquireSyncLease(userId, ownerId);
    if (!acquired) {
      return {
        latestSequence: await this.latestSequenceForUser(userId),
        syncedAt: new Date().toISOString(),
        status: "already_running" as const,
      };
    }

    try {
      await this.pullRemoteChanges(userId);
      await this.processProjectionJobs(userId);
      return {
        latestSequence: await this.latestSequenceForUser(userId),
        syncedAt: new Date().toISOString(),
        status: "completed" as const,
      };
    } finally {
      await this.releaseSyncLease(userId, ownerId);
    }
  }

  private async acquireSyncLease(userId: string, ownerId: string) {
    const expiresAt = new Date(Date.now() + 5 * 60_000);
    const rows = await prisma.$queryRaw<Array<{ userId: string }>>`
      INSERT INTO "UserSyncLease" ("id", "userId", "ownerId", "expiresAt", "createdAt", "updatedAt")
      VALUES (${randomUUID()}, ${userId}, ${ownerId}, ${expiresAt}, NOW(), NOW())
      ON CONFLICT ("userId") DO UPDATE
      SET "ownerId" = EXCLUDED."ownerId",
          "expiresAt" = EXCLUDED."expiresAt",
          "updatedAt" = NOW()
      WHERE "UserSyncLease"."expiresAt" < NOW()
      RETURNING "userId"
    `;
    return rows.length === 1;
  }

  private async releaseSyncLease(userId: string, ownerId: string) {
    await prisma.$executeRaw`
      DELETE FROM "UserSyncLease"
      WHERE "userId" = ${userId}
        AND "ownerId" = ${ownerId}
    `;
  }

  private async processProjectionJobs(userId: string) {
    if (config.SYNC_PROVIDER === "mock") {
      await this.processProjectionJobsMock(userId);
      return;
    }

    const googleAccount = await this.findGoogleAccount(userId);
    if (!googleAccount) {
      return;
    }

    const jobs = await prisma.projectionJob.findMany({
      where: {
        userId,
        runAfter: { lte: new Date() },
      },
      orderBy: { createdAt: "asc" },
      take: 100,
    });

    for (const job of jobs) {
      const note = await this.findOwnedNote(userId, job.noteId);
      if (!note) {
        await prisma.projectionJob.deleteMany({
          where: { id: job.id },
        });
        continue;
      }

      try {
        await this.projectNoteToGoogle(googleAccount, note, job.operation);
        const refreshed = await prisma.note.update({
          where: { id: note.id },
          data: {
            pendingProjection: false,
            lastProjectionError: null,
          },
        });
        await prisma.projectionJob.delete({ where: { id: job.id } });
        if (!refreshed.deletedAt) {
          await appendEvent(userId, "note.upsert", refreshed.id, {
            note: noteToDto(refreshed),
          });
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : "Unknown projection error";
        await prisma.projectionJob.update({
          where: { id: job.id },
          data: {
            attemptCount: { increment: 1 },
            lastError: message,
            runAfter: new Date(Date.now() + 30_000),
          },
        });
        await prisma.note.update({
          where: { id: note.id },
          data: {
            pendingProjection: true,
            lastProjectionError: message,
          },
        });
      }
    }
  }

  private async projectNoteToGoogle(googleAccount: GoogleAccount, note: Note, operation: string) {
    if (note.deletedAt) {
      if (note.googleTaskId) {
        const remoteTaskListId = await this.findRemoteTaskListIdForTask(
          note.userId,
          googleAccount,
          note.googleTaskId,
          [note.googleTaskListId],
        );
        if (remoteTaskListId) {
          await deleteTask(googleAccount, remoteTaskListId, note.googleTaskId);
        }
      }
      return;
    }

    if (!note.googleTaskListId) {
      return;
    }

    if (!note.googleTaskId) {
      const created = await createTask(
        googleAccount,
        note.googleTaskListId,
        note.title,
        note.bodyPlaintext,
        note.dueDate,
      );
      await prisma.note.update({
        where: { id: note.id },
        data: {
          googleTaskId: created.googleTaskId,
          remoteEtag: created.etag,
        },
      });
      return;
    }

    const previousTaskListId = operation.startsWith("move:")
      ? operation.slice("move:".length)
      : null;
    let remoteTaskListId = previousTaskListId;
    if (previousTaskListId && previousTaskListId !== note.googleTaskListId) {
      try {
        await moveTaskBetweenLists(
          googleAccount,
          previousTaskListId,
          note.googleTaskId,
          note.googleTaskListId,
        );
        remoteTaskListId = note.googleTaskListId;
      } catch (error) {
        if (!isGoogleTaskNotFoundError(error)) {
          throw error;
        }
        remoteTaskListId = await this.findRemoteTaskListIdForTask(
          note.userId,
          googleAccount,
          note.googleTaskId,
          [previousTaskListId, note.googleTaskListId],
        );
        if (remoteTaskListId && remoteTaskListId !== note.googleTaskListId) {
          await moveTaskBetweenLists(
            googleAccount,
            remoteTaskListId,
            note.googleTaskId,
            note.googleTaskListId,
          );
          remoteTaskListId = note.googleTaskListId;
        }
      }
    }

    try {
      const updated = await updateTask(googleAccount, note);
      await prisma.note.update({
        where: { id: note.id },
        data: {
          remoteEtag: updated.etag,
        },
      });
      return;
    } catch (error) {
      if (!isGoogleTaskNotFoundError(error)) {
        throw error;
      }
    }

    remoteTaskListId = await this.findRemoteTaskListIdForTask(
      note.userId,
      googleAccount,
      note.googleTaskId,
      [remoteTaskListId, note.googleTaskListId],
    );

    if (remoteTaskListId && remoteTaskListId !== note.googleTaskListId) {
      await moveTaskBetweenLists(
        googleAccount,
        remoteTaskListId,
        note.googleTaskId,
        note.googleTaskListId,
      );
      const updated = await updateTask(googleAccount, note);
      await prisma.note.update({
        where: { id: note.id },
        data: {
          remoteEtag: updated.etag,
        },
      });
      return;
    }

    await this.markNoteDeletedFromGoogle(
      note,
      "google_deleted",
      new Date(),
    );
  }

  private async processProjectionJobsMock(userId: string) {
    const jobs = await prisma.projectionJob.findMany({
      where: {
        userId,
        runAfter: { lte: new Date() },
      },
      orderBy: { createdAt: "asc" },
      take: 100,
    });

    for (const job of jobs) {
      const note = await this.findOwnedNote(userId, job.noteId);
      if (!note) {
        await prisma.projectionJob.delete({ where: { id: job.id } });
        continue;
      }

      const refreshed = await prisma.note.update({
        where: { id: note.id },
        data: {
          pendingProjection: false,
          lastProjectionError: null,
          googleTaskId: note.deletedAt ? note.googleTaskId : note.googleTaskId ?? `mock-task-${note.id}`,
        },
      });
      await prisma.projectionJob.delete({ where: { id: job.id } });
      if (!refreshed.deletedAt) {
        await appendEvent(userId, "note.upsert", refreshed.id, {
          note: noteToDto(refreshed),
        });
      }
    }
  }

  private async pullRemoteChanges(userId: string) {
    if (config.SYNC_PROVIDER === "mock") {
      return;
    }

    const googleAccount = await this.findGoogleAccount(userId);
    if (!googleAccount) {
      return;
    }
    const subscriptions = await prisma.taskListSubscription.findMany({
      where: {
        userId,
        isSelected: true,
      },
    });

    for (const subscription of subscriptions) {
      const checkpoint = await prisma.syncCheckpoint.findUnique({
        where: {
          userId_googleTaskListId: {
            userId,
            googleTaskListId: subscription.googleTaskListId,
          },
        },
      });
      const updatedMin = checkpoint?.updatedMinCursor
        ? new Date(checkpoint.updatedMinCursor.getTime() - 5_000)
        : undefined;
      const remoteTasks = await listTasksSince(
        googleAccount,
        subscription.googleTaskListId,
        updatedMin,
      );

      let maxUpdatedAt = checkpoint?.updatedMinCursor ?? null;

      for (const remote of remoteTasks) {
        if (remote.updatedAt && (!maxUpdatedAt || remote.updatedAt > maxUpdatedAt)) {
          maxUpdatedAt = remote.updatedAt;
        }

        const existing = await this.findOwnedNoteByGoogleTaskId(
          userId,
          remote.id,
          subscription.googleTaskListId,
        );

        if (remote.deleted || remote.completed) {
          if (existing && !existing.deletedAt) {
            await this.markNoteDeletedFromGoogle(
              existing,
              remote.completed ? "google_completed" : "google_deleted",
              remote.updatedAt ?? new Date(),
            );
          }
          continue;
        }

        // Local pendingProjection means the desktop already changed this note and the
        // remote snapshot is stale until projection catches up. Do not let pull sync
        // immediately overwrite list/body/title back to the old remote state.
        if (existing?.pendingProjection) {
          continue;
        }

        const mergedMarkdown = plainTaskToMarkdown(remote.title, remote.notes);
        const now = remote.updatedAt ?? new Date();
        const noteId = existing?.id ?? randomUUID();
        const note = await prisma.note.upsert({
          where: {
            id: noteId,
          },
          create: {
            id: noteId,
            userId,
            title: remote.title,
            bodyMarkdown: mergedMarkdown,
            bodyPlaintext: remote.notes,
            googleTaskListId: subscription.googleTaskListId,
            taskListNameCache: subscription.title,
            googleTaskId: remote.id,
            remoteEtag: remote.etag,
            dueDate: remote.dueDate ?? undefined,
            serverUpdatedAt: now,
            pendingProjection: false,
          },
          update: {
            title: remote.title,
            bodyMarkdown: mergedMarkdown,
            bodyPlaintext: remote.notes,
            googleTaskListId: subscription.googleTaskListId,
            taskListNameCache: subscription.title,
            googleTaskId: remote.id,
            remoteEtag: remote.etag,
            dueDate: remote.dueDate ?? undefined,
            deletedAt: null,
            deletionReason: null,
            pendingProjection: false,
            lastProjectionError: null,
            serverVersion: { increment: 1 },
            serverUpdatedAt: now,
          },
        });
        await appendEvent(userId, "note.upsert", note.id, {
          note: noteToDto(note),
        });
      }

      await prisma.syncCheckpoint.upsert({
        where: {
          userId_googleTaskListId: {
            userId,
            googleTaskListId: subscription.googleTaskListId,
          },
        },
        create: {
          userId,
          googleTaskListId: subscription.googleTaskListId,
          updatedMinCursor: maxUpdatedAt ?? new Date(),
          lastSyncedAt: new Date(),
        },
        update: {
          updatedMinCursor: maxUpdatedAt ?? checkpoint?.updatedMinCursor ?? new Date(),
          lastSyncedAt: new Date(),
          consecutiveErrors: 0,
          backoffUntil: null,
        },
      });
    }
  }

  async requireGoogleAccount(userId: string) {
    const account = await this.findGoogleAccount(userId);
    if (!account) {
      throw new Error("No Google account is connected.");
    }
    return account;
  }

  private async findGoogleAccount(userId: string) {
    return prisma.googleAccount.findFirst({
      where: {
        userId,
        authStatus: "connected",
      },
      orderBy: { createdAt: "asc" },
    });
  }
}
