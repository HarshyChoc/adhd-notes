import { google, tasks_v1 } from "googleapis";
import type { GoogleAccount, Note } from "@prisma/client";

import { config } from "../config.js";
import { decrypt } from "./crypto.js";

export type TaskListDescriptor = {
  id: string;
  title: string;
};

export type RemoteTaskSnapshot = {
  id: string;
  title: string;
  notes: string;
  dueDate: string | null;
  updatedAt: Date | null;
  etag: string | null;
  deleted: boolean;
  completed: boolean;
};

function toDueTimestamp(dateOnly: string | null | undefined): string | undefined {
  if (!dateOnly) return undefined;
  return `${dateOnly}T00:00:00.000Z`;
}

function fromDueTimestamp(timestamp: string | null | undefined): string | null {
  if (!timestamp) return null;
  const [dateOnly] = timestamp.split("T");
  return dateOnly ?? null;
}

async function getOAuthClient(googleAccount: GoogleAccount) {
  const client = new google.auth.OAuth2(
    config.GOOGLE_CLIENT_ID,
    config.GOOGLE_CLIENT_SECRET,
    config.GOOGLE_REDIRECT_URI,
  );
  const refreshToken = decrypt(
    {
      ciphertext: googleAccount.refreshTokenCiphertext,
      iv: googleAccount.refreshTokenIv,
      tag: googleAccount.refreshTokenTag,
    },
    config.APP_ENCRYPTION_KEY,
  );
  client.setCredentials({
    refresh_token: refreshToken,
  });
  return client;
}

async function tasksApi(googleAccount: GoogleAccount): Promise<tasks_v1.Tasks> {
  const authClient = await getOAuthClient(googleAccount);
  return google.tasks({
    version: "v1",
    auth: authClient,
  });
}

export async function listTaskLists(googleAccount: GoogleAccount): Promise<TaskListDescriptor[]> {
  const tasks = await tasksApi(googleAccount);
  const response = await tasks.tasklists.list({ maxResults: 100 });
  return (response.data.items ?? [])
    .filter((list): list is tasks_v1.Schema$TaskList => Boolean(list.id && list.title))
    .map((list) => ({
      id: list.id!,
      title: list.title!,
    }));
}

export async function listTasksSince(
  googleAccount: GoogleAccount,
  taskListId: string,
  updatedMin?: Date,
): Promise<RemoteTaskSnapshot[]> {
  const tasks = await tasksApi(googleAccount);
  const snapshots: RemoteTaskSnapshot[] = [];
  let pageToken: string | undefined;

  do {
    const response = await tasks.tasks.list({
      tasklist: taskListId,
      pageToken,
      maxResults: 100,
      showCompleted: true,
      showDeleted: true,
      showHidden: true,
      updatedMin: updatedMin?.toISOString(),
    });
    const items = response.data.items ?? [];
    for (const item of items) {
      if (!item.id || !item.title) {
        continue;
      }
      snapshots.push({
        id: item.id,
        title: item.title,
        notes: item.notes ?? "",
        dueDate: fromDueTimestamp(item.due ?? null),
        updatedAt: item.updated ? new Date(item.updated) : null,
        etag: item.etag ?? null,
        deleted: Boolean(item.deleted),
        completed: item.status === "completed",
      });
    }
    pageToken = response.data.nextPageToken ?? undefined;
  } while (pageToken);

  return snapshots;
}

export async function createTask(
  googleAccount: GoogleAccount,
  taskListId: string,
  title: string,
  notes: string,
  dueDate: string | null,
): Promise<{ googleTaskId: string; etag: string | null }> {
  const tasks = await tasksApi(googleAccount);
  const response = await tasks.tasks.insert({
    tasklist: taskListId,
    requestBody: {
      title,
      notes,
      due: toDueTimestamp(dueDate),
      status: "needsAction",
    },
  });
  if (!response.data.id) {
    throw new Error("Google Tasks insert did not return an id.");
  }
  return {
    googleTaskId: response.data.id,
    etag: response.data.etag ?? null,
  };
}

export async function updateTask(
  googleAccount: GoogleAccount,
  note: Pick<Note, "googleTaskListId" | "googleTaskId" | "title" | "bodyPlaintext" | "dueDate">,
): Promise<{ etag: string | null }> {
  if (!note.googleTaskListId || !note.googleTaskId) {
    throw new Error("Cannot update a Google task without list and task ids.");
  }
  const tasks = await tasksApi(googleAccount);
  const response = await tasks.tasks.patch({
    tasklist: note.googleTaskListId,
    task: note.googleTaskId,
    requestBody: {
      title: note.title,
      notes: note.bodyPlaintext,
      due: toDueTimestamp(note.dueDate),
      status: "needsAction",
    },
  });
  return { etag: response.data.etag ?? null };
}

export async function getTaskIfExists(
  googleAccount: GoogleAccount,
  taskListId: string,
  taskId: string,
): Promise<tasks_v1.Schema$Task | null> {
  const tasks = await tasksApi(googleAccount);
  try {
    const response = await tasks.tasks.get({
      tasklist: taskListId,
      task: taskId,
    });
    return response.data;
  } catch (error) {
    const candidate = error as { code?: number; status?: number; response?: { status?: number } };
    const statusCode = candidate.response?.status ?? candidate.status ?? candidate.code;
    if (statusCode === 404) {
      return null;
    }
    throw error;
  }
}

export async function moveTaskBetweenLists(
  googleAccount: GoogleAccount,
  fromTaskListId: string,
  taskId: string,
  toTaskListId: string,
): Promise<void> {
  if (fromTaskListId === toTaskListId) {
    return;
  }
  const tasks = await tasksApi(googleAccount);
  await tasks.tasks.move({
    tasklist: fromTaskListId,
    task: taskId,
    destinationTasklist: toTaskListId,
  });
}

export async function deleteTask(
  googleAccount: GoogleAccount,
  taskListId: string,
  taskId: string,
): Promise<void> {
  const tasks = await tasksApi(googleAccount);
  await tasks.tasks.delete({
    tasklist: taskListId,
    task: taskId,
  });
}
