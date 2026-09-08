"use client";

import { AuthedPage } from "@/components/authed-page";
import { MonthView } from "@/features/month-view/MonthView";

export default function MonthPage() {
  return (
    <AuthedPage>
      <MonthView />
    </AuthedPage>
  );
}
