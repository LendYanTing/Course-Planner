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
import { AuthCard } from "@/features/auth/auth-card";
import { login, errorMessage } from "@/features/auth/api";
import { signIn } from "@/features/auth/session-store";

export default function LoginPage() {
  const router = useRouter();
  const [username, setUsername] = React.useState("");
  const [password, setPassword] = React.useState("");

  const mutation = useMutation({
    mutationFn: () => login(username.trim(), password),
    onSuccess: async (session) => {
      signIn(session);
      toast.success("Signed in");
      router.replace("/week");
    },
    onError: (err) => toast.error(errorMessage(err)),
  });

  return (
    <AuthCard
      title="Sign in"
      subtitle="Welcome back"
      footer={
        <>
          No account?{" "}
          <Link href="/register" className="text-primary hover:underline">
            Register
          </Link>
        </>
      }
    >
      <form
        className="flex flex-col gap-4"
        onSubmit={(e) => {
          e.preventDefault();
          mutation.mutate();
        }}
      >
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="username">Username</Label>
          <Input
            id="username"
            autoComplete="username"
            autoFocus
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            required
          />
        </div>
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="password">Password</Label>
          <Input
            id="password"
            type="password"
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            required
          />
        </div>
        <Button type="submit" disabled={mutation.isPending || !username || !password}>
          {mutation.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
          Sign in
        </Button>
      </form>
    </AuthCard>
  );
}
