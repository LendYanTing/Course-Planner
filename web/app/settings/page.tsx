"use client";

import * as React from "react";
import { AuthedPage } from "@/components/authed-page";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { CalendarSettings } from "@/features/settings/calendar-settings";
import { CoursesSettings } from "@/features/settings/courses-settings";
import { SchedulesSettings } from "@/features/settings/schedules-settings";
import { SyncSettingsCard } from "@/features/settings/sync-settings";
import { useSession } from "@/features/auth/session-store";

export default function SettingsPage() {
  const user = useSession((s) => s.user);
  const [tab, setTab] = React.useState("calendars");

  return (
    <AuthedPage>
      <div className="flex min-h-0 flex-1 flex-col overflow-y-auto p-4">
        <div className="mx-auto w-full max-w-3xl">
          <Card className="mb-4">
            <CardHeader className="p-4">
              <CardTitle className="text-base">Settings</CardTitle>
              <CardDescription>
                Signed in as <span className="font-medium">{user?.username}</span> · Timezone{" "}
                <span className="font-medium">{user?.timezone}</span> (locked at registration) ·
                Semester data lives below.
              </CardDescription>
            </CardHeader>
          </Card>
          <Tabs value={tab} onValueChange={setTab}>
            <TabsList className="w-full justify-start">
              <TabsTrigger value="calendars">Calendars</TabsTrigger>
              <TabsTrigger value="courses">Courses</TabsTrigger>
              <TabsTrigger value="schedules">Recurring schedules</TabsTrigger>
            </TabsList>
            <Card className="mt-2">
              <CardContent className="p-4">
                <TabsContent value="calendars" className="mt-0">
                  <CalendarSettings />
                </TabsContent>
                <TabsContent value="courses" className="mt-0">
                  <CoursesSettings />
                </TabsContent>
                <TabsContent value="schedules" className="mt-0">
                  <SchedulesSettings />
                </TabsContent>
              </CardContent>
            </Card>
          </Tabs>
          <SyncSettingsCard />
        </div>
      </div>
    </AuthedPage>
  );
}
