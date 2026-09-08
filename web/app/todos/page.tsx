"use client";

import { AuthedPage } from "@/components/authed-page";

export default function TodosPage() {
  return (
    <AuthedPage>
      <div className="flex h-full items-center justify-center text-muted-foreground">
        Todos — coming up.
      </div>
    </AuthedPage>
  );
}
