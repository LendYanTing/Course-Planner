"use client";

import * as React from "react";
import { RequireAuth } from "@/features/auth/session-guard";
import { AppShell } from "@/components/app-shell";

/** Authenticated page frame: guard + shell + content. */
export function AuthedPage({ children }: { children: React.ReactNode }) {
  return (
    <RequireAuth>
      <AppShell>{children}</AppShell>
    </RequireAuth>
  );
}
