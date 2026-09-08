import '../../core/util/json_utils.dart';
import '../../domain/calendar_event.dart';
import 'api_response.dart';
import 'http_client.dart';

/// Read endpoints that produce *server-projected* views, plus the series
/// editing endpoint (docs/api.md §10-12). Entity CRUD flows through the
/// offline mutation queue + sync push instead (adapters exist server-side for
/// every synced entity); overrides are created exclusively through
/// [seriesApply] because the server owns occurrence semantics.
class DataApi {
  DataApi(this._http);

  final ApiHttp _http;

  /// GET /calendar/events — unified projection for [startUtc, endUtc).
  Future<List<CalendarEvent>> calendarEvents({
    required DateTime startUtc,
    required DateTime endUtc,
    bool includeCourses = true,
    bool includeRecurringSchedules = true,
    bool includeTodoBlocks = true,
    bool includeDeadlines = true,
  }) async {
    final res = await _http.get('/calendar/events', query: {
      'start': formatUtc(startUtc),
      'end': formatUtc(endUtc),
      'includeCourses': includeCourses,
      'includeRecurringSchedules': includeRecurringSchedules,
      'includeTodoBlocks': includeTodoBlocks,
      'includeDeadlines': includeDeadlines,
    });
    return unwrapDataList(res)
        .whereType<Map>()
        .map((e) => CalendarEvent.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// GET /free-slots.
  Future<List<({DateTime startAt, DateTime endAt})>> freeSlots({
    required DateTime startUtc,
    required DateTime endUtc,
    required int durationMinutes,
    String alignment = 'period',
  }) async {
    final res = await _http.get('/free-slots', query: {
      'start': formatUtc(startUtc),
      'end': formatUtc(endUtc),
      'durationMinutes': durationMinutes,
      'alignment': alignment,
    });
    return unwrapDataList(res).whereType<Map>().map((e) {
      final s = parseUtc(readStringOrNull(Map<String, dynamic>.from(e), 'startAt'));
      final en = parseUtc(readStringOrNull(Map<String, dynamic>.from(e), 'endAt'));
      return (
        startAt: s ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        endAt: en ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
    }).toList();
  }

  /// POST /series/{seriesType}/{seriesId}/apply.
  ///
  /// [seriesType] is one of EntityTypes.courseMeeting / recurringSchedule.
  /// [operation] is the wire `operation` object (type MOVE|UPDATE|CANCEL|
  /// DELETE plus scoped fields). Response returns the server-side result map.
  Future<Map<String, dynamic>> seriesApply({
    required String seriesType,
    required String seriesId,
    required String scope,
    String? occurrenceDateLocal,
    required Map<String, dynamic> operation,
  }) async {
    final body = <String, dynamic>{
      'scope': scope,
      'operation': operation,
    };
    if (occurrenceDateLocal != null) {
      body['occurrenceDateLocal'] = occurrenceDateLocal;
    }
    final res = await _http.post(
      '/series/$seriesType/$seriesId/apply',
      body: body,
    );
    return unwrapDataObject(res);
  }
}
