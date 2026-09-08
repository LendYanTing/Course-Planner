import 'package:dio/dio.dart';

import '../../core/config/app_config.dart';
import '../../core/error/api_exception.dart';

/// Signature used by the auth interceptor to fetch a fresh access token when
/// a request is rejected with 401. Returns true on success.
typedef RefreshCallback = Future<bool> Function();

/// Shared Dio client with Course Planner transport rules
/// (agents/flutter-agent.md §Networking):
/// * base URL from [AppConfig],
/// * `Authorization: Bearer <access-token>` injected on every request,
/// * structured `{error:{code,message,details}}` decoding,
/// * one retry after a successful token refresh (never blindly retries
///   non-idempotent requests).
class ApiHttp {
  ApiHttp._(this.dio, this._setAccessToken);

  factory ApiHttp.create({required RefreshCallback onRefresh}) {
    final dio = Dio(
      BaseOptions(
        baseUrl: AppConfig.apiBaseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 15),
        headers: {'Content-Type': 'application/json'},
      ),
    );
    String? token;
    dio.interceptors.add(_AuthInterceptor(
      tokenOf: () => token,
      onRefresh: onRefresh,
      dio: dio,
    ));
    return ApiHttp._(dio, (t) => token = t);
  }

  final Dio dio;
  final void Function(String? token) _setAccessToken;

  /// Injects the in-memory access token used by the auth interceptor.
  void setAccessToken(String? token) => _setAccessToken(token);

  Future<Response<dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) =>
      _guard(() => dio.get<dynamic>(path, queryParameters: query));

  Future<Response<dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    String? contentType,
  }) =>
      _guard(() => dio.post<dynamic>(
            path,
            data: body,
            queryParameters: query,
            options:
                contentType != null ? Options(contentType: contentType) : null,
          ));

  Future<Response<dynamic>> patch(String path, {Object? body}) =>
      _guard(() => dio.patch<dynamic>(path, data: body));

  Future<Response<dynamic>> delete(String path) =>
      _guard(() => dio.delete<dynamic>(path));

  /// Runs the request through the interceptor chain and converts failures
  /// into [ApiException].
  Future<Response<dynamic>> _guard(
      Future<Response<dynamic>> Function() run) async {
    try {
      return await run();
    } on DioException catch (e) {
      throw decodeApiError(e);
    }
  }
}

/// Queued interceptor implementing bearer injection + single refresh-retry.
class _AuthInterceptor extends QueuedInterceptor {
  _AuthInterceptor({
    required this.tokenOf,
    required this.onRefresh,
    required this.dio,
  });

  final String? Function() tokenOf;
  final RefreshCallback onRefresh;
  final Dio dio;
  final Set<String> _retried = {};

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final token = options.extra['accessToken'] as String? ?? tokenOf();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final status = err.response?.statusCode;
    final request = err.requestOptions;
    final uri = request.uri.path;
    final isAuthCall = uri.endsWith('/auth/login') ||
        uri.endsWith('/auth/register') ||
        uri.endsWith('/auth/refresh');
    final cacheKey = '${request.method}:$uri';
    if (status == 401 && !isAuthCall && !_retried.contains(cacheKey)) {
      _retried.add(cacheKey);
      try {
        final ok = await onRefresh();
        if (ok) {
          final token = tokenOf();
          final clone = await dio.fetch<dynamic>(request
            ..extra['accessToken'] = token);
          handler.resolve(clone);
          return;
        }
      } catch (_) {
        // fall through: report the original 401
      } finally {
        _retried.remove(cacheKey);
      }
    }
    handler.next(err);
  }
}
