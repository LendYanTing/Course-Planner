"use client";

import * as React from "react";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { Loader2, Upload } from "lucide-react";
import { AuthedPage } from "@/components/authed-page";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { useCalendars } from "@/features/calendars/hooks";
import { previewCourseCsv, commitCourseCsv } from "@/features/import/api";
import type { ImportPreview } from "@/generated/entities";
import { dropCachePrefix } from "@/db/db";

const SAMPLE_CSV = `课程名称,星期,开始节数,结束节数,老师,地点,周数
高等数学,1,1,2,小明,逸夫楼201,1-5、7-11单、12-16双
线性代数,2,3,4,小红,理工楼110,1-16
大学英语,2,3,4,小红,文成楼125,2、5、8`;

export default function ImportCoursesPage() {
  const qc = useQueryClient();
  const calendars = useCalendars();
  const cals = calendars.data ?? [];
  const [calendarId, setCalendarId] = React.useState("");
  const [csv, setCsv] = React.useState("");
  const [preview, setPreview] = React.useState<ImportPreview | null>(null);
  const [busy, setBusy] = React.useState(false);
  const [step, setStep] = React.useState<"edit" | "preview">("edit");

  // Default to the first semester once the list is available.
  const effectiveCalendarId = calendarId || cals[0]?.id || "";

  async function runPreview() {
    if (!effectiveCalendarId || !csv.trim()) {
      toast.error("Pick a calendar and paste some CSV");
      return;
    }
    setBusy(true);
    try {
      const p = await previewCourseCsv(effectiveCalendarId, csv);
      setPreview(p);
      setStep("preview");
    } catch (e) {
      const message = e instanceof Error ? e.message : "Preview failed";
      toast.error(message);
      const details = (e as { details?: unknown }).details as
        | { errors?: { line: number; field: string; code: string; message: string }[]; conflicts?: string[] }
        | undefined;
      const rows = details?.errors?.map(
        (r) => `Line ${r.line} (${r.field}): ${r.message}`
      );
      const conflicts = details?.conflicts;
      if (rows?.length || conflicts?.length) {
        setPreview({
          previewId: "",
          expiresAt: "",
          calendarId: effectiveCalendarId,
          courses: [],
          conflicts: [...(rows ?? []), ...(conflicts ?? [])],
        } as ImportPreview);
        setStep("preview");
      }
    } finally {
      setBusy(false);
    }
  }

  async function runCommit() {
    if (!preview?.previewId) return;
    setBusy(true);
    try {
      const r = await commitCourseCsv(preview.previewId);
      toast.success(`Imported ${r.courses} course(s)`);
      await dropCachePrefix("/courses");
      await dropCachePrefix("/calendar/events");
      await qc.invalidateQueries();
      setPreview(null);
      setCsv("");
      setStep("edit");
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Commit failed");
    } finally {
      setBusy(false);
    }
  }

  return (
    <AuthedPage>
      <div className="flex min-h-0 flex-1 flex-col overflow-y-auto p-4">
        <div className="mx-auto w-full max-w-3xl">
          <Card>
            <CardHeader>
              <CardTitle>Import courses from CSV</CardTitle>
              <CardDescription>
                Columns: 课程名称 / 星期 (1–7, Mon=1) / 开始节数 / 结束节数 / 老师 / 地点 / 周数.
                Week syntax supports ranges, lists and odd/even:{" "}
                <code className="rounded bg-muted px-1">1-16</code>,{" "}
                <code className="rounded bg-muted px-1">2、5、8</code>,{" "}
                <code className="rounded bg-muted px-1">7-11单</code>. Importing is preview →
                confirm → commit.
              </CardDescription>
            </CardHeader>
            <CardContent className="flex flex-col gap-3">
              <div className="grid gap-3 sm:grid-cols-[1fr_auto]">
                <div className="flex flex-col gap-1.5">
                  <Label>Target calendar</Label>
                  <Select value={effectiveCalendarId} onValueChange={setCalendarId} disabled={step === "preview"}>
                    <SelectTrigger>
                      <SelectValue placeholder="Choose semester" />
                    </SelectTrigger>
                    <SelectContent>
                      {cals.map((c) => (
                        <SelectItem key={c.id} value={c.id}>
                          {c.name}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
                <div className="flex items-end gap-2">
                  <Button
                    variant="outline"
                    size="sm"
                    disabled={busy}
                    onClick={() => {
                      setCsv(SAMPLE_CSV);
                      toast.info("Sample CSV loaded");
                    }}
                  >
                    Load sample
                  </Button>
                  <Button size="sm" disabled={busy || !effectiveCalendarId} onClick={() => void runPreview()}>
                    <Upload /> Preview
                  </Button>
                </div>
              </div>

              {step === "edit" ? (
                <Textarea
                  rows={10}
                  value={csv}
                  onChange={(e) => setCsv(e.target.value)}
                  placeholder={SAMPLE_CSV}
                  className="font-mono text-xs"
                />
              ) : preview ? (
                <div className="flex flex-col gap-3">
                  <div className="flex items-center justify-between">
                    <div className="text-sm font-medium">
                      Preview — {preview.courses.length} course row(s)
                    </div>
                    {preview.conflicts && preview.conflicts.length > 0 && (
                      <Badge variant="destructive">{preview.conflicts.length} issue(s)</Badge>
                    )}
                  </div>
                  <div className="overflow-x-auto rounded border">
                    <table className="w-full text-left text-xs">
                      <thead className="border-b bg-muted/50">
                        <tr>
                          <th className="p-2">Line</th>
                          <th className="p-2">Name</th>
                          <th className="p-2">Weekday</th>
                          <th className="p-2">Periods</th>
                          <th className="p-2">Teacher</th>
                          <th className="p-2">Location</th>
                          <th className="p-2">Weeks</th>
                        </tr>
                      </thead>
                      <tbody>
                        {preview.courses.map((c) => (
                          <tr key={c.line} className="border-b last:border-0">
                            <td className="p-2 text-muted-foreground">{c.line}</td>
                            <td className="p-2 font-medium">{c.name}</td>
                            <td className="p-2">{c.weekday}</td>
                            <td className="p-2">{c.periodStart}–{c.periodEnd}</td>
                            <td className="p-2">{c.teacher}</td>
                            <td className="p-2">{c.location}</td>
                            <td className="p-2">{c.weeks}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                  {preview.conflicts && preview.conflicts.length > 0 && (
                    <ul className="flex flex-col gap-1 text-xs text-destructive">
                      {preview.conflicts.map((c, i) => (
                        <li key={i}>• {c}</li>
                      ))}
                    </ul>
                  )}
                  <div className="flex justify-end gap-2">
                    <Button variant="outline" onClick={() => setStep("edit")} disabled={busy}>
                      Back
                    </Button>
                    <Button
                      disabled={busy || preview.courses.length === 0}
                      onClick={() => void runCommit()}
                    >
                      {busy && <Loader2 className="h-4 w-4 animate-spin" />}
                      Commit import
                    </Button>
                  </div>
                </div>
              ) : null}
            </CardContent>
          </Card>
        </div>
      </div>
    </AuthedPage>
  );
}
