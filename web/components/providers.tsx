"use client";

import * as React from "react";
import { QueryClient, QueryClientProvider, useQueryClient } from "@tanstack/react-query";
import { TooltipProvider } from "@/components/ui/tooltip";
import { Toaster } from "sonner";
import { bootSession, useSession } from "@/features/auth/session-store";
import { useClock } from "@/features/time/clock";
import { startSyncEngine } from "@/features/sync/engine";

function makeQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: 30_000,
        refetchOnWindowFocus: false,
        retry: (failureCount, error) => {
          const status = (error as { status?: number })?.status;
          if (
            status &&
            [400, 401, 403, 404, 409, 410, 422].includes(status)
          ) {
            return false;
          }
          return failureCount < 1;
        },
      },
    },
  });
}

let client: QueryClient | undefined;

function getClient() {
  if (!client) client = makeQueryClient();
  return client;
}

function Bootstrap() {
  const queryClient = useQueryClient();
  const status = useSession((s) => s.status);

  React.useEffect(() => {
    void (async () => {
      await bootSession();
      if (useSession.getState().status === "signedIn") startSyncEngine();
    })();
    const clock = useClock.getState();
    void clock.sync();
    const clockId = setInterval(() => void useClock.getState().sync(), 60_000);
    return () => clearInterval(clockId);
  }, []);

  // The sync engine dispatches this after a successful push so every view can
  // refetch authoritative data.
  React.useEffect(() => {
    const handler = () => void queryClient.invalidateQueries();
    window.addEventListener("cp:data-changed", handler);
    return () => window.removeEventListener("cp:data-changed", handler);
  }, [queryClient]);

  // Start the sync engine after login happens client-side too.
  React.useEffect(() => {
    if (status === "signedIn") startSyncEngine();
  }, [status]);

  return null;
}

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <QueryClientProvider client={getClient()}>
      <TooltipProvider delayDuration={300}>
        <Bootstrap />
        {children}
        <Toaster richColors position="top-center" />
      </TooltipProvider>
    </QueryClientProvider>
  );
}
