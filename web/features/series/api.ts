import { api } from "@/lib/api/http";
import type {
  SeriesApplyRequest,
  SeriesApplyResult,
  SeriesType,
  Uuid,
} from "@/generated/entities";

/**
 * Apply an occurrence-level change to a course meeting or recurring schedule
 * series (docs/api.md §10). `scope` THIS / THIS_AND_FUTURE / ALL.
 */
export async function applySeriesChange(
  seriesType: SeriesType,
  seriesId: Uuid,
  request: SeriesApplyRequest
): Promise<SeriesApplyResult> {
  return api.post<SeriesApplyResult>(
    `/series/${seriesType}/${seriesId}/apply`,
    request
  );
}
