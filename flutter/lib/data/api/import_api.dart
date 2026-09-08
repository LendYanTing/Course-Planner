import '../../core/error/api_exception.dart';
import 'api_response.dart';
import 'http_client.dart';

/// Result of a CSV preview (server importcsv.PreviewResult).
class CourseCsvPreview {
  const CourseCsvPreview({
    required this.previewId,
    required this.expiresAt,
    required this.calendarId,
    required this.courses,
    required this.conflicts,
  });

  factory CourseCsvPreview.fromJson(Map<String, dynamic> m) =>
      CourseCsvPreview(
        previewId: (m['previewId'] ?? '') as String,
        expiresAt: (m['expiresAt'] ?? '') as String,
        calendarId: (m['calendarId'] ?? '') as String,
        courses: m['courses'] is List
            ? (m['courses'] as List)
                .whereType<Map>()
                .map((e) => ParsedCsvCourse.fromJson(Map<String, dynamic>.from(e)))
                .toList()
            : const [],
        conflicts: m['conflicts'] is List
            ? (m['conflicts'] as List).whereType<String>().toList()
            : const [],
      );

  final String previewId;
  final String expiresAt;
  final String calendarId;
  final List<ParsedCsvCourse> courses;
  final List<String> conflicts;
}

/// One parsed row (server importcsv.ParsedCourse) shown in the preview.
class ParsedCsvCourse {
  const ParsedCsvCourse({
    required this.line,
    required this.name,
    required this.weekday,
    required this.periodStart,
    required this.periodEnd,
    this.teacher,
    this.location,
    this.weekRuleText,
  });

  factory ParsedCsvCourse.fromJson(Map<String, dynamic> m) => ParsedCsvCourse(
        line: (m['line'] as num?)?.toInt() ?? 0,
        name: (m['name'] ?? '') as String,
        weekday: (m['weekday'] as num?)?.toInt() ?? 1,
        periodStart: (m['periodStart'] as num?)?.toInt() ?? 1,
        periodEnd: (m['periodEnd'] as num?)?.toInt() ?? 1,
        teacher: m['teacher'] as String?,
        location: m['location'] as String?,
        weekRuleText: m['weekRule'] as String?,
      );

  final int line;
  final String name;
  final int weekday;
  final int periodStart;
  final int periodEnd;
  final String? teacher;
  final String? location;

  /// Original week column text (e.g. `1-5、7-11单`).
  final String? weekRuleText;
}

/// Row-level validation error (docs/csv-import.md §Errors).
class CsvFieldError {
  const CsvFieldError({
    required this.line,
    required this.field,
    required this.code,
    required this.message,
  });

  factory CsvFieldError.fromMap(Map<String, dynamic> m) => CsvFieldError(
        line: (m['line'] as num?)?.toInt() ?? 0,
        field: (m['field'] ?? '') as String,
        code: (m['code'] ?? '') as String,
        message: (m['message'] ?? '') as String,
      );

  final int line;
  final String field;
  final String code;
  final String message;
}

/// CSV import endpoints (docs/api.md §14, docs/csv-import.md).
///
/// The Flutter side never parses the CSV itself: preview performs server-side
/// parse/validate against the chosen calendar, and commit imports atomically.
class ImportApi {
  ImportApi(this._http);

  final ApiHttp _http;

  /// POST /import/courses/preview?calendarId=... with a raw `text/csv` body.
  Future<CourseCsvPreview> previewCourses({
    required String calendarId,
    required String csvText,
  }) async {
    final res = await _http.post(
      '/import/courses/preview',
      query: {'calendarId': calendarId},
      body: csvText,
      contentType: 'text/csv',
    );
    return CourseCsvPreview.fromJson(unwrapDataObject(res));
  }

  /// POST /import/courses/commit — imports the previously previewed file.
  Future<({bool committed, int courses})> commitCourses({
    required String previewId,
  }) async {
    final res = await _http.post('/import/courses/commit', body: {
      'previewId': previewId,
    });
    final data = unwrapDataObject(res);
    return (
      committed: data['committed'] == true,
      courses: (data['courses'] as num?)?.toInt() ?? 0,
    );
  }

  /// Extracts row-level validation errors from a [ApiException] carrying
  /// `details.errors` (server 422 CSV_VALIDATION_ERROR).
  static List<CsvFieldError> validationErrors(ApiException e) {
    final errors = e.details?['errors'];
    if (errors is List) {
      return errors
          .whereType<Map>()
          .map((m) => CsvFieldError.fromMap(Map<String, dynamic>.from(m)))
          .toList();
    }
    return const [];
  }
}
