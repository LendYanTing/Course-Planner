"use client";

import * as React from "react";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import {
  CalendarDays,
  CalendarRange,
  LayoutGrid,
  ListTodo,
  Settings,
  Upload,
  LogOut,
  CalendarClock,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { Button, buttonVariants } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { useSession, signOut } from "@/features/auth/session-store";
import { SyncBadge } from "@/features/sync/ui/sync-badge";

const NAV = [
  { href: "/week", label: "周视图", icon: CalendarDays },
  { href: "/table", label: "课表", icon: LayoutGrid },
  { href: "/month", label: "月视图", icon: CalendarRange },
  { href: "/todos", label: "待办", icon: ListTodo },
  { href: "/import/courses", label: "导入", icon: Upload },
  { href: "/settings", label: "设置", icon: Settings },
];

export function AppShell({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const router = useRouter();
  const user = useSession((s) => s.user);

  async function handleLogout() {
    await signOut();
    router.replace("/login");
  }

  return (
    <div className="flex h-dvh flex-col bg-background">
      <header className="flex h-14 shrink-0 items-center gap-4 border-b bg-background/85 px-4 backdrop-blur supports-[backdrop-filter]:bg-background/75">
        <Link
          href="/week"
          className="flex items-center gap-2 font-semibold tracking-tight"
        >
          <CalendarClock className="h-5 w-5 text-primary" />
          <span className="hidden sm:inline">课程规划</span>
        </Link>
        <nav className="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto">
          {NAV.map((item) => {
            const active =
              pathname === item.href || pathname.startsWith(item.href + "/");
            const Icon = item.icon;
            return (
              <Link
                key={item.href}
                href={item.href}
                className={cn(
                  buttonVariants({ variant: "ghost", size: "sm" }),
                  "shrink-0 text-muted-foreground transition-colors",
                  active && "bg-accent font-medium text-foreground"
                )}
              >
                <Icon className="mr-1 h-4 w-4" />
                {item.label}
              </Link>
            );
          })}
        </nav>
        <div className="flex items-center gap-2">
          <SyncBadge />
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button variant="ghost" size="sm" className="gap-2">
                <span className="flex h-6 w-6 items-center justify-center rounded-full bg-primary/15 text-xs font-semibold text-primary">
                  {(user?.username ?? "?").slice(0, 1).toUpperCase()}
                </span>
                <span className="hidden max-w-[140px] truncate text-sm sm:inline">
                  {user?.username}
                </span>
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="w-56">
              <DropdownMenuLabel>
                <div className="flex flex-col gap-0.5">
                  <span>{user?.username}</span>
                  <span className="text-xs font-normal text-muted-foreground">
                    {user?.timezone}
                  </span>
                </div>
              </DropdownMenuLabel>
              <DropdownMenuSeparator />
              <DropdownMenuItem onClick={() => router.push("/settings")}>
                <Settings className="mr-2" />
                设置
              </DropdownMenuItem>
              <DropdownMenuItem onSelect={() => void handleLogout()}>
                <LogOut className="mr-2" />
                退出登录
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </header>
      <div className="cp-fade-up flex min-h-0 flex-1 flex-col">{children}</div>
    </div>
  );
}
