"use client";

import * as React from "react";
import { CalendarClock } from "lucide-react";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { GuestOnly } from "@/features/auth/session-guard";

export function AuthCard({
  title,
  subtitle,
  children,
  footer,
}: {
  title: string;
  subtitle?: string;
  children: React.ReactNode;
  footer: React.ReactNode;
}) {
  return (
    <GuestOnly>
      <div className="flex min-h-dvh items-center justify-center bg-muted/30 px-4">
        <div className="w-full max-w-sm">
          <div className="mb-6 flex flex-col items-center gap-2 text-center">
            <span className="flex h-11 w-11 items-center justify-center rounded-xl bg-primary text-primary-foreground">
              <CalendarClock className="h-6 w-6" />
            </span>
            <h1 className="text-xl font-semibold tracking-tight">
              课程规划
            </h1>
            <p className="text-sm text-muted-foreground">
              课表 / 日程 / 待办 · 离线优先。
            </p>
          </div>
          <Card>
            <CardHeader>
              <CardTitle className="text-base">{title}</CardTitle>
              {subtitle && (
                <p className="text-sm text-muted-foreground">{subtitle}</p>
              )}
            </CardHeader>
            <CardContent>{children}</CardContent>
          </Card>
          <p className="mt-4 text-center text-sm text-muted-foreground">
            {footer}
          </p>
        </div>
      </div>
    </GuestOnly>
  );
}
