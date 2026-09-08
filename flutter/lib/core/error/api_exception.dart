import 'package:dio/dio.dart';

/// Error codes documented in docs/api.md §16. Clients depend on these codes,
/// never on natural-language messages.
class ApiErrorCodes {
  ApiErrorCodes._();

  static const invalidRequest = 'INVALID_REQUEST';
  static const unauthorized = 'UNAUTHORIZED';
  static const forbidden = 'FORBIDDEN';
  static const notFound = 'NOT_FOUND';
  static const validationError = 'VALIDATION_ERROR';
  static const invalidTimezone = 'INVALID_TIMEZONE';
  static const crossMidnight = 'CROSS_MIDNIGHT_NOT_ALLOWED';
  static const scheduleConflict = 'SCHEDULE_CONFLICT';
  static const courseConflict = 'COURSE_CONFLICT';
  static const staleRevision = 'STALE_REVISION';
  static const syncConflict = 'SYNC_CONFLICT';
  static const duplicateOperation = 'DUPLICATE_OPERATION';
  static const csvParseError = 'CSV_PARSE_ERROR';
  static const csvValidationError = 'CSV_VALIDATION_ERROR';
  static const confirmationRequired = 'CONFIRMATION_REQUIRED';
  static const confirmationExpired = 'CONFIRMATION_EXPIRED';
}

/// Structured API error decoded from the server's `{"error":{...}}` envelope
/// (docs/api.md §2).
class ApiException implements Exception {
  const ApiException({
    required this.code,
    required this.message,
    this.status,
    this.details,
  });

  final String code;
  final String message;
  final int? status;
  final Map<String, dynamic>? details;

  bool get isUnauthorized => code == ApiErrorCodes.unauthorized;

  bool get isNetwork => this is NetworkException;

  @override
  String toString() => 'ApiException($status $code): $message';
}

/// No connectivity / unreachable host (never a server error).
class NetworkException extends ApiException {
  NetworkException(String message)
      : super(code: 'NETWORK_ERROR', message: message);
}

/// The HTTP call itself failed (5xx, bad status without structured body).
class TransportException extends ApiException {
  TransportException(this.dioError)
      : super(
          code: 'TRANSPORT_ERROR',
          message: dioError.message ?? 'transport error',
          status: dioError.response?.statusCode,
        );
  final DioException dioError;
}

/// Decodes a [DioException] into [ApiException].
ApiException decodeApiError(DioException e) {
  final res = e.response;
  if (e.type == DioExceptionType.connectionTimeout ||
      e.type == DioExceptionType.receiveTimeout ||
      e.type == DioExceptionType.sendTimeout ||
      e.type == DioExceptionType.connectionError) {
    return NetworkException('Cannot reach server: ${e.message}');
  }
  if (res == null) {
    return TransportException(e);
  }
  final body = res.data;
  if (body is Map<String, dynamic>) {
    final err = body['error'];
    if (err is Map<String, dynamic>) {
      final code = err['code'];
      final message = err['message'];
      final details = err['details'];
      return ApiException(
        code: code is String ? code : 'UNKNOWN_ERROR',
        message: message is String ? message : 'unknown error',
        status: res.statusCode,
        details: details is Map<String, dynamic> ? details : null,
      );
    }
  }
  return TransportException(e);
}
