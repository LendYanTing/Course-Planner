"use client";

import { AuthedPage } from "@/components/authed-page";
import { WeekView } from "@/features/week-view/WeekView";

export default function WeekPage() {
  return (
    <AuthedPage>
      <WeekView />
    </AuthedPage>
  );
}
