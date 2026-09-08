import { api, postCsv } from "@/lib/api/http";
import type { ImportCommitResult, ImportPreview, Uuid } from "@/generated/entities";

export async function previewCourseCsv(
  calendarId: Uuid,
  csv: string
): Promise<ImportPreview> {
  return postCsv<ImportPreview>(
    "/import/courses/preview",
    csv,
    { calendarId }
  );
}

export async function commitCourseCsv(
  previewId: Uuid
): Promise<ImportCommitResult> {
  return api.post<ImportCommitResult>("/import/courses/commit", { previewId });
}
