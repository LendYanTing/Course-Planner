"use client";

import { AuthedPage } from "@/components/authed-page";
import { WeekTableView } from "@/features/table-view/week-table";

export default function TablePage() {
  return (
    <AuthedPage>
      <WeekTableView />
    </AuthedPage>
  );
}
