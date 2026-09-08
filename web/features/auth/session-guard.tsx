"use client";

import * as React from "react";
import { useRouter } from "next/navigation";
import { Loader2 } from "lucide-react";
import { useSession } from "@/features/auth/session-store";

/** Full-screen boot splash while the session state is unknown. */
export function BootSplash() {
  return (
    <div className="flex min-h-screen flex-col items-center justify-center gap-3 text-muted-foreground">
      <Loader2 className="h-6 w-6 animate-spin text-primary" />
      <p className="text-sm">Loading…</p>
    </div>
  );
}

/**
 * Redirect /login and /register away when already authenticated.
 */
export function GuestOnly({ children }: { children: React.ReactNode }) {
  const status = useSession((s) => s.status);
  const router = useRouter();
  React.useEffect(() => {
    if (status === "signedIn") router.replace("/week");
  }, [status, router]);
  if (status === "booting") return <BootSplash />;
  if (status === "signedIn") return null; // redirecting
  return <>{children}</>;
}

/**
 * Gate for authenticated areas: splash while booting, /login when signed out.
 */
export function RequireAuth({ children }: { children: React.ReactNode }) {
  const status = useSession((s) => s.status);
  const router = useRouter();
  React.useEffect(() => {
    if (status === "signedOut") router.replace("/login");
  }, [status, router]);
  if (status !== "signedIn") return <BootSplash />;
  return <>{children}</>;
}
