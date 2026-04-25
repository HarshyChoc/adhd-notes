export type NoteDto = {
  id: string;
  title: string;
  bodyMarkdown: string;
  bodyPlaintext: string;
  taskListId: string | null;
  taskListNameCache: string | null;
  googleTaskId: string | null;
  dueDate: string | null;
  serverVersion: number;
  serverUpdatedAt: string;
  deletedAt: string | null;
  deletionReason: string | null;
  pendingProjection: boolean;
  lastProjectionError: string | null;
};

export type TaskListDto = {
  id: string;
  title: string;
  isSelected: boolean;
  isDefault: boolean;
};
