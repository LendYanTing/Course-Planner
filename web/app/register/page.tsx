"use client";

import * as React from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useMutation } from "@tanstack/react-query";
import { toast } from "sonner";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { AuthCard } from "@/features/auth/auth-card";
import { register, errorMessage } from "@/features/auth/api";
import { signIn } from "@/features/auth/session-store";
import { COMMON_TIMEZONES } from "@/lib/time/timezones";

export default function RegisterPage() {
  const router = useRouter();
  const [username, setUsername] = React.useState("");
  const [email, setEmail] = React.useState("");
  const [password, setPassword] = React.useState("");
  const [confirm, setConfirm] = React.useState("");
  const [timezone, setTimezone] = React.useState("Asia/Shanghai");

  const mutation = useMutation({
    mutationFn: () =>
      register({
        username: username.trim(),
        email: email.trim() ? email.trim() : null,
        password,
        timezone,
      }),
    onSuccess: async (session) => {
      signIn(session);
      toast.success("Account created");
      router.replace("/week");
    },
    onError: (err) => toast.error(errorMessage(err)),
  });

  function submit() {
    if (password !== confirm) {
      toast.error("Passwords do not match");
      return;
    }
    mutation.mutate();
  }

  return (
    <AuthCard
      title="创建账号"
      subtitle="请谨慎选择时区——创建后不可更改。"
      footer={
        <>
          已有账号？{" "}
          <Link href="/login" className="text-primary hover:underline">
            Sign in
          </Link>
        </>
      }
    >
      <form
        className="flex flex-col gap-4"
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
      >
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="username">用户名</Label>
          <Input
            id="username"
            autoComplete="username"
            autoFocus
            minLength={3}
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            required
          />
          <p className="text-xs text-muted-foreground">
            3–32 位：字母、数字、_ 与 -
          </p>
        </div>
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="email">邮箱（可选）</Label>
          <Input
            id="email"
            type="email"
            autoComplete="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
        </div>
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="timezone">时区</Label>
          <Select value={timezone} onValueChange={setTimezone}>
            <SelectTrigger id="timezone" className="w-full">
              <SelectValue placeholder="Select timezone" />
            </SelectTrigger>
            <SelectContent>
              {COMMON_TIMEZONES.map((z) => (
                <SelectItem key={z.value} value={z.value}>
                  {z.label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          <p className="text-xs text-muted-foreground">
            所有时间都按该时区解释（不使用设备时区）。
          </p>
        </div>
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="password">密码</Label>
          <Input
            id="password"
            type="password"
            autoComplete="new-password"
            minLength={8}
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            required
          />
          <p className="text-xs text-muted-foreground">至少 8 个字符。</p>
        </div>
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="confirm">确认密码</Label>
          <Input
            id="confirm"
            type="password"
            autoComplete="new-password"
            minLength={8}
            value={confirm}
            onChange={(e) => setConfirm(e.target.value)}
            required
          />
        </div>
        <Button
          type="submit"
          disabled={
            mutation.isPending || username.trim().length < 3 || password.length < 8
          }
        >
          {mutation.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
          创建账号
        </Button>
      </form>
    </AuthCard>
  );
}
