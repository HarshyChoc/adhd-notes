import { randomUUID } from "node:crypto";
import type { FastifyBaseLogger } from "fastify";
import { Prisma, type GoogleAccount, type Note, type TaskListSubscription } from "@prisma/client";

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
  type RemoteTaskSnapshot,
} from "../lib/google.js";
import {
  deriveNoteContentParts,
  plainTaskToMarkdown,
  projectedTaskFingerprint,
} from "../lib/markdown.js";
import { MOCK_TASK_LISTS } from "../mock.js";
import { sseHub } from "../lib/sse.js";
import type { NoteDto, TaskListDto } from "../types.js";

type MutationEnvelope = {
  id: string;
  type: "upsert_note" | "delete_note";
  noteId: string;
  baseServerVersion: number;
  payload: Record<string, string | null>;
};

type MutationResult = {
  id: string;
  status: "applied" | "duplicate" | "conflict";
  note: NoteDto | null;
  tombstone: ReturnType<typeof noteToTombstone> | null;
};

type MutationTransactionResult = {
  result: MutationResult;
  event: { sequence: number; type: string; payload: Prisma.JsonValue } | null;
};

function serviceError(statusCode: number, message: string) {
  return Object.assign(new Error(message), { statusCode });
}

function mutationRaceError() {
  return Object.assign(new Error("The note changed while the mutation was being applied."), {
    mutationRace: true,
  });
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

function noteToTombstone(note: Note) {
  return {
    noteId: note.id,
    deletionReason: note.deletionReason ?? "deleted",
    serverVersion: note.serverVersion,
    serverUpdatedAt: note.serverUpdatedAt.toISOString(),
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

async function upsertProjectionJob(
  tx: Prisma.TransactionClient,
  userId: string,
  noteId: string,
  operation: string,
) {
  const existing = await tx.projectionJob.findUnique({
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
    await tx.projectionJob.create({
      data: {
        userId,
        noteId,
        operation,
      },
    });
    return;
  }

  await tx.projectionJob.update({
    where: { id: existing.id },
    data: {
      operation: mergeProjectionOperation(existing.operation, operation),
      runAfter: new Date(),
      lastError: null,
      generation: { increment: 1 },
    },
  });
}

function asString(payload: MutationEnvelope["payload"], key: string): string | null {
  return payload[key] ?? null;
}

export function isProjectedTaskEcho(
  remoteFingerprint: string,
  lastProjectedFingerprint: string | null,
  canonicalLocalFingerprint: string | null,
) {
  return remoteFingerprint === lastProjectedFingerprint
    || (!lastProjectedFingerprint && remoteFingerprint === canonicalLocalFingerprint);
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
      tombstones: deletedNotes.map(noteToTombstone),
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

    let nextUserIndex = 0;
    const workerCount = Math.min(config.SCHEDULED_SYNC_CONCURRENCY, Math.max(users.length, 1));
    await Promise.all(Array.from({ length: workerCount }, async () => {
      while (nextUserIndex < users.length) {
        const user = users[nextUserIndex++];
        if (!user) continue;
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
    }));

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
    const result = await prisma.$transaction(async (tx) => {
      const deleted = await tx.note.update({
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
      await tx.projectionJob.deleteMany({
        where: {
          userId: note.userId,
          noteId: note.id,
        },
      });
      const event = await tx.eventLog.create({
        data: {
          userId: note.userId,
          type: "note.delete",
          noteId: deleted.id,
          payload: noteToTombstone(deleted),
        },
      });
      return { deleted, event };
    });
    sseHub.publish(note.userId, {
      sequence: result.event.sequence,
      type: result.event.type,
      payload: result.event.payload,
    });
    return result.deleted;
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
    const results: MutationResult[] = [];

    for (const mutation of mutations) {
      const alreadyApplied = await prisma.appliedMutation.findUnique({
        where: { id: mutation.id },
      });
      if (alreadyApplied) {
        if (alreadyApplied.userId !== userId) {
          throw serviceError(403, "This mutation id belongs to another user.");
        }
        const existing = await this.findOwnedNote(userId, mutation.noteId);
        results.push({
          id: mutation.id,
          status: "duplicate",
          note: existing && !existing.deletedAt ? noteToDto(existing) : null,
          tombstone: existing?.deletedAt ? noteToTombstone(existing) : null,
        });
        continue;
      }

      let transactionResult: MutationTransactionResult;
      try {
        transactionResult = await prisma.$transaction(async (tx) => {
        const existing = await tx.note.findUnique({ where: { id: mutation.noteId } });
        if (existing && existing.userId !== userId) {
          throw serviceError(403, "This note does not belong to the authenticated user.");
        }

        if (existing && existing.serverVersion !== mutation.baseServerVersion) {
          return {
            result: {
              id: mutation.id,
              status: "conflict" as const,
              note: existing.deletedAt ? null : noteToDto(existing),
              tombstone: existing.deletedAt ? noteToTombstone(existing) : null,
            },
            event: null,
          };
        }
        if (!existing && mutation.baseServerVersion !== 0) {
          return {
            result: {
              id: mutation.id,
              status: "conflict" as const,
              note: null,
              tombstone: null,
            },
            event: null,
          };
        }

        const now = new Date();
        let updatedNote: Note | null = null;
        let eventType: "note.upsert" | "note.delete" | null = null;
        let eventPayload: Prisma.JsonObject | null = null;

        if (mutation.type === "upsert_note") {
          const taskListId = asString(mutation.payload, "taskListId")?.trim() ?? "";
          const content = asString(mutation.payload, "content") ?? "";
          if (!taskListId) {
            throw serviceError(400, "A synced note must be assigned to a task list.");
          }
          const taskListNameCache = asString(mutation.payload, "taskListNameCache");
          const dueDate = asString(mutation.payload, "dueDate");
          const parts = deriveNoteContentParts(content);
          const previousTaskListId = existing?.googleTaskListId ?? null;

          if (existing) {
            const changed = await tx.note.updateMany({
                where: {
                  id: existing.id,
                  userId,
                  serverVersion: mutation.baseServerVersion,
                },
                data: {
                  title: parts.title,
                  bodyMarkdown: parts.bodyMarkdown,
                  bodyPlaintext: parts.bodyPlaintext,
                  googleTaskListId: taskListId,
                  taskListNameCache,
                  dueDate,
                  deletedAt: null,
                  deletionReason: null,
                  pendingProjection: true,
                  lastProjectionError: null,
                  serverVersion: { increment: 1 },
                  serverUpdatedAt: now,
                },
              });
            if (changed.count !== 1) throw mutationRaceError();
            updatedNote = await tx.note.findUniqueOrThrow({ where: { id: existing.id } });
          } else {
            updatedNote = await tx.note.create({
                data: {
                  id: mutation.noteId,
                  userId,
                  title: parts.title,
                  bodyMarkdown: parts.bodyMarkdown,
                  bodyPlaintext: parts.bodyPlaintext,
                  googleTaskListId: taskListId,
                  taskListNameCache,
                  dueDate,
                  serverUpdatedAt: now,
                  pendingProjection: true,
                },
              });
          }

          const operation = previousTaskListId && previousTaskListId !== taskListId
            ? `move:${previousTaskListId}`
            : updatedNote.googleTaskId ? "upsert" : "create";
          await upsertProjectionJob(tx, userId, updatedNote.id, operation);
          eventType = "note.upsert";
          eventPayload = { note: noteToDto(updatedNote) } as unknown as Prisma.JsonObject;
        } else if (existing) {
          const changed = await tx.note.updateMany({
            where: {
              id: existing.id,
              userId,
              serverVersion: mutation.baseServerVersion,
            },
            data: {
              deletedAt: now,
              deletionReason: "desktop_delete",
              pendingProjection: true,
              lastProjectionError: null,
              serverVersion: { increment: 1 },
              serverUpdatedAt: now,
            },
          });
          if (changed.count !== 1) throw mutationRaceError();
          updatedNote = await tx.note.findUniqueOrThrow({ where: { id: existing.id } });
          await upsertProjectionJob(tx, userId, updatedNote.id, "delete");
          eventType = "note.delete";
          eventPayload = noteToTombstone(updatedNote);
        }

        await tx.appliedMutation.create({
          data: {
            id: mutation.id,
            userId,
            noteId: mutation.noteId,
            type: mutation.type,
            payload: {
              ...mutation.payload,
              baseServerVersion: mutation.baseServerVersion,
            },
          },
        });

        let event: { sequence: number; type: string; payload: Prisma.JsonValue } | null = null;
        if (eventType && eventPayload) {
          const created = await tx.eventLog.create({
            data: {
              userId,
              type: eventType,
              noteId: mutation.noteId,
              payload: eventPayload,
            },
          });
          event = { sequence: created.sequence, type: eventType, payload: created.payload };
        }

        return {
          result: {
            id: mutation.id,
            status: "applied" as const,
            note: updatedNote && !updatedNote.deletedAt ? noteToDto(updatedNote) : null,
            tombstone: updatedNote?.deletedAt ? noteToTombstone(updatedNote) : null,
          },
          event,
        };
        });
      } catch (error) {
        const candidate = error as { mutationRace?: boolean };
        const isUniqueRace = error instanceof Prisma.PrismaClientKnownRequestError
          && error.code === "P2002";
        if (!candidate.mutationRace && !isUniqueRace) throw error;

        const applied = await prisma.appliedMutation.findUnique({ where: { id: mutation.id } });
        if (applied) {
          if (applied.userId !== userId) {
            throw serviceError(403, "This mutation id belongs to another user.");
          }
          const canonical = await this.findOwnedNote(userId, mutation.noteId);
          results.push({
            id: mutation.id,
            status: "duplicate",
            note: canonical && !canonical.deletedAt ? noteToDto(canonical) : null,
            tombstone: canonical?.deletedAt ? noteToTombstone(canonical) : null,
          });
          continue;
        }

        const canonical = await this.findOwnedNote(userId, mutation.noteId);
        if (!canonical) throw error;
        results.push({
          id: mutation.id,
          status: "conflict",
          note: canonical.deletedAt ? null : noteToDto(canonical),
          tombstone: canonical.deletedAt ? noteToTombstone(canonical) : null,
        });
        continue;
      }

      results.push(transactionResult.result);
      if (transactionResult.event) {
        latestSequence = Math.max(latestSequence, transactionResult.event.sequence);
        sseHub.publish(userId, transactionResult.event);
      }
    }

    if (latestSequence === 0) {
      latestSequence = await this.latestSequenceForUser(userId);
    }
    return { latestSequence, results };
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

    let leaseLost = false;
    const leaseHeartbeat = setInterval(() => {
      void this.renewSyncLease(userId, ownerId)
        .then((renewed) => {
          if (!renewed) leaseLost = true;
        })
        .catch((error) => {
          leaseLost = true;
          this.logger.error({ err: error, userId }, "Failed to renew sync lease.");
        });
    }, 30_000);
    leaseHeartbeat.unref();

    try {
      await this.pullRemoteChanges(userId);
      if (leaseLost) throw serviceError(409, "The synchronization lease was lost.");
      await this.processProjectionJobs(userId);
      return {
        latestSequence: await this.latestSequenceForUser(userId),
        syncedAt: new Date().toISOString(),
        status: "completed" as const,
      };
    } finally {
      clearInterval(leaseHeartbeat);
      await this.releaseSyncLease(userId, ownerId);
    }
  }

  private async acquireSyncLease(userId: string, ownerId: string) {
    const expiresAt = new Date(Date.now() + 2 * 60_000);
    const reclaimed = await prisma.userSyncLease.updateMany({
      where: { userId, expiresAt: { lt: new Date() } },
      data: { ownerId, expiresAt },
    });
    if (reclaimed.count === 1) return true;

    try {
      await prisma.userSyncLease.create({
        data: { userId, ownerId, expiresAt },
      });
      return true;
    } catch (error) {
      if (error instanceof Prisma.PrismaClientKnownRequestError && error.code === "P2002") {
        return false;
      }
      throw error;
    }
  }

  private async renewSyncLease(userId: string, ownerId: string) {
    const renewed = await prisma.userSyncLease.updateMany({
      where: { userId, ownerId },
      data: { expiresAt: new Date(Date.now() + 2 * 60_000) },
    });
    return renewed.count === 1;
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
        const outcome = await this.projectNoteToGoogle(googleAccount, note, job.operation);
        if (outcome.remoteDeleted) {
          await this.markNoteDeletedFromGoogle(note, "google_deleted", new Date());
          continue;
        }

        const refreshed = await prisma.$transaction(async (tx) => {
          const cleared = await tx.projectionJob.deleteMany({
            where: { id: job.id, generation: job.generation },
          });
          const data: Prisma.NoteUpdateInput = {
            googleTaskId: outcome.googleTaskId ?? undefined,
            remoteEtag: outcome.etag ?? undefined,
            lastProjectedFingerprint: outcome.fingerprint ?? undefined,
          };
          if (cleared.count === 1) {
            data.pendingProjection = false;
            data.lastProjectionError = null;
          }
          return tx.note.update({ where: { id: note.id }, data });
        });

        if (!refreshed.deletedAt && !refreshed.pendingProjection) {
          await appendEvent(userId, "note.upsert", refreshed.id, {
            note: noteToDto(refreshed),
          });
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : "Unknown projection error";
        const currentJob = await prisma.projectionJob.updateMany({
          where: { id: job.id, generation: job.generation },
          data: {
            attemptCount: { increment: 1 },
            lastError: message,
            runAfter: new Date(Date.now() + 30_000),
          },
        });
        if (currentJob.count === 1) {
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
  }

  private async projectNoteToGoogle(
    googleAccount: GoogleAccount,
    note: Note,
    operation: string,
  ): Promise<{
    googleTaskId?: string;
    etag?: string | null;
    fingerprint?: string;
    remoteDeleted?: boolean;
  }> {
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
      return {};
    }

    if (!note.googleTaskListId) {
      throw serviceError(400, "A synced note must be assigned to a task list.");
    }

    const fingerprint = projectedTaskFingerprint({
      title: note.title,
      notes: note.bodyPlaintext,
      dueDate: note.dueDate,
      taskListId: note.googleTaskListId,
    });

    if (!note.googleTaskId) {
      const created = await createTask(
        googleAccount,
        note.googleTaskListId,
        note.title,
        note.bodyPlaintext,
        note.dueDate,
      );
      return {
        googleTaskId: created.googleTaskId,
        etag: created.etag,
        fingerprint,
      };
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
      return { etag: updated.etag, fingerprint };
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
      return { etag: updated.etag, fingerprint };
    }

    return { remoteDeleted: true };
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

      const refreshed = await prisma.$transaction(async (tx) => {
        const cleared = await tx.projectionJob.deleteMany({
          where: { id: job.id, generation: job.generation },
        });
        return tx.note.update({
          where: { id: note.id },
          data: {
            pendingProjection: cleared.count === 1 ? false : note.pendingProjection,
            lastProjectionError: cleared.count === 1 ? null : note.lastProjectionError,
            googleTaskId: note.deletedAt ? note.googleTaskId : note.googleTaskId ?? `mock-task-${note.id}`,
            lastProjectedFingerprint: note.googleTaskListId
              ? projectedTaskFingerprint({
                  title: note.title,
                  notes: note.bodyPlaintext,
                  dueDate: note.dueDate,
                  taskListId: note.googleTaskListId,
                })
              : undefined,
          },
        });
      });
      if (!refreshed.deletedAt && !refreshed.pendingProjection) {
        await appendEvent(userId, "note.upsert", refreshed.id, {
          note: noteToDto(refreshed),
        });
      }
    }
  }

  async reconcileRemoteTask(
    userId: string,
    subscription: Pick<TaskListSubscription, "googleTaskListId" | "title">,
    remote: RemoteTaskSnapshot,
  ): Promise<"echo" | "changed" | "deleted" | "ignored"> {
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
        return "deleted";
      }
      return "ignored";
    }

    const remoteFingerprint = projectedTaskFingerprint({
      title: remote.title,
      notes: remote.notes,
      dueDate: remote.dueDate,
      taskListId: subscription.googleTaskListId,
    });
    const canonicalLocalFingerprint = existing?.googleTaskListId
      ? projectedTaskFingerprint({
          title: existing.title,
          notes: existing.bodyPlaintext,
          dueDate: existing.dueDate,
          taskListId: existing.googleTaskListId,
        })
      : null;

    if (existing && isProjectedTaskEcho(
      remoteFingerprint,
      existing.lastProjectedFingerprint,
      canonicalLocalFingerprint,
    )) {
      await prisma.note.update({
        where: { id: existing.id },
        data: {
          remoteEtag: remote.etag,
          lastProjectedFingerprint: remoteFingerprint,
        },
      });
      return "echo";
    }

    // A different fingerprint is a genuine Google edit. Google wins, including
    // over an older queued projection, so the stale projection must not run.
    const mergedMarkdown = plainTaskToMarkdown(remote.title, remote.notes);
    const now = remote.updatedAt ?? new Date();
    const noteId = existing?.id ?? randomUUID();
    const reconciliation = await prisma.$transaction(async (tx) => {
      if (existing?.pendingProjection) {
        await tx.projectionJob.deleteMany({
          where: { userId, noteId: existing.id },
        });
      }
      const reconciled = await tx.note.upsert({
        where: { id: noteId },
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
          lastProjectedFingerprint: remoteFingerprint,
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
          lastProjectedFingerprint: remoteFingerprint,
          dueDate: remote.dueDate,
          deletedAt: null,
          deletionReason: null,
          pendingProjection: false,
          lastProjectionError: null,
          serverVersion: { increment: 1 },
          serverUpdatedAt: now,
        },
      });
      const event = await tx.eventLog.create({
        data: {
          userId,
          type: "note.upsert",
          noteId: reconciled.id,
          payload: { note: noteToDto(reconciled) } as unknown as Prisma.JsonObject,
        },
      });
      return { note: reconciled, event };
    });
    sseHub.publish(userId, {
      sequence: reconciliation.event.sequence,
      type: reconciliation.event.type,
      payload: reconciliation.event.payload,
    });
    return "changed";
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

        await this.reconcileRemoteTask(userId, subscription, remote);
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
