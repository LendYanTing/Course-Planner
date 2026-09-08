import { api } from "@/lib/api/http";
import type {
  Course,
  CourseCreatePayload,
  CourseMeeting,
  CourseMeetingCreatePayload,
  Uuid,
  WeekRule,
} from "@/generated/entities";

export async function listCourses(calendarId?: Uuid): Promise<Course[]> {
  return api.get<Course[]>("/courses", {
    query: calendarId ? { calendarId } : {},
  });
}

export async function getCourse(id: Uuid): Promise<Course & { meetings: CourseMeeting[] }> {
  return api.get<Course & { meetings: CourseMeeting[] }>(`/courses/${id}`);
}

export async function createCourse(payload: CourseCreatePayload): Promise<
  Course & { meetings?: CourseMeeting[] }
> {
  return api.post<Course & { meetings?: CourseMeeting[] }>("/courses", payload);
}

export async function updateCourse(
  id: Uuid,
  patch: Partial<Pick<Course, "name" | "teacher" | "location" | "color" | "notes">> & {
    baseRevision?: number;
  }
): Promise<Course> {
  return api.patch<Course>(`/courses/${id}`, patch);
}

export async function deleteCourse(id: Uuid): Promise<void> {
  return api.del(`/courses/${id}`);
}

export async function listCourseMeetings(courseId: Uuid): Promise<CourseMeeting[]> {
  return api.get<CourseMeeting[]>(`/courses/${courseId}/meetings`);
}

export async function createCourseMeeting(
  courseId: Uuid,
  payload: CourseMeetingCreatePayload
): Promise<CourseMeeting> {
  return api.post<CourseMeeting>(`/courses/${courseId}/meetings`, payload);
}

export async function updateCourseMeeting(
  courseId: Uuid,
  meetingId: Uuid,
  patch: Partial<{
    weekday: number;
    periodStart: number;
    periodEnd: number;
    weekRule: WeekRule;
    baseRevision: number;
  }>
): Promise<CourseMeeting> {
  return api.patch<CourseMeeting>(
    `/courses/${courseId}/meetings/${meetingId}`,
    patch
  );
}

export async function deleteCourseMeeting(courseId: Uuid, meetingId: Uuid): Promise<void> {
  return api.del(`/courses/${courseId}/meetings/${meetingId}`);
}
