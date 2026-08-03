import { createHash } from "node:crypto";

const MARKDOWN_SPECIALS = /([\\`*_{}[\]()#+\-.!|>~])/g;

export function stripMarkdown(input: string): string {
  return input
    .replace(/```[\s\S]*?```/g, "")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/!\[[^\]]*]\([^)]*\)/g, "")
    .replace(/\[([^\]]+)]\([^)]*\)/g, "$1")
    .replace(/^>\s?/gm, "")
    .replace(/^[-*+]\s+/gm, "")
    .replace(/^\d+\.\s+/gm, "")
    .replace(/^#{1,6}\s+/gm, "")
    .replace(/\*\*([^*]+)\*\*/g, "$1")
    .replace(/\*([^*]+)\*/g, "$1")
    .replace(/~~([^~]+)~~/g, "$1")
    .trim();
}

export function escapeMarkdownPlainText(input: string): string {
  return input.replace(MARKDOWN_SPECIALS, "\\$1");
}

export function deriveNoteContentParts(markdown: string): {
  title: string;
  bodyMarkdown: string;
  bodyPlaintext: string;
} {
  const rawLines = markdown.split(/\r?\n/);
  const firstNonEmptyIndex = rawLines.findIndex((line) => line.trim().length > 0);
  const titleSource = firstNonEmptyIndex >= 0 ? rawLines[firstNonEmptyIndex].trim() : "Untitled";
  const title = stripMarkdown(titleSource).slice(0, 1024) || "Untitled";

  const bodyLines = firstNonEmptyIndex >= 0 ? rawLines.slice(firstNonEmptyIndex + 1) : [];
  const bodyMarkdown = markdown;
  const bodyPlaintext = stripMarkdown(bodyLines.join("\n")).slice(0, 8192);

  return { title, bodyMarkdown, bodyPlaintext };
}

export function projectedTaskFingerprint(input: {
  title: string;
  notes: string;
  dueDate: string | null;
  taskListId: string;
}): string {
  return createHash("sha256")
    .update(JSON.stringify({
      title: input.title,
      notes: input.notes,
      dueDate: input.dueDate,
      taskListId: input.taskListId,
    }))
    .digest("hex");
}

export function plainTaskToMarkdown(title: string, notes: string): string {
  const safeTitle = escapeMarkdownPlainText(title.trim() || "Untitled");
  const safeNotes = escapeMarkdownPlainText(notes.trim());
  return safeNotes.length > 0 ? `${safeTitle}\n\n${safeNotes}` : safeTitle;
}
