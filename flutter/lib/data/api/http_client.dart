import 'package:dio/dio.dart';
import 'package:dio/io.dart';

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
  ApiHttp._(this.dio, this._bareDio, this._setAccessToken, this._baseUrl);

  factory ApiHttp.create({
    required RefreshCallback onRefresh,
    String? baseUrl,
    HttpClientAdapter? adapter,
  }) {
    final initial = baseUrl ?? AppConfig.apiBaseUrl;
    BaseOptions options() => BaseOptions(
          baseUrl: initial,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 15),
          headers: {'Content-Type': 'application/json'},
        );
    final dio = Dio(options());
    // Bare transport for the token endpoints (refresh/logout): they carry the
    // refresh token in the body, need no access token, and must NEVER share
    // the auth interceptor's queues — onError awaits its own refresh, and an
    // await inside a QueuedInterceptor blocks the very response that would
    // unblock it (a permanent wedge where no 401 ever reaches the caller).
    final bareDio = Dio(options());
    if (adapter != null) {
      dio.httpClientAdapter = adapter;
      bareDio.httpClientAdapter = adapter;
    }
    String? token;
    dio.interceptors.add(_AuthInterceptor(
      tokenOf: () => token,
      onRefresh: onRefresh,
      dio: dio,
    ));
    return ApiHttp._(dio, bareDio, (t) => token = t, initial);
  }

  final Dio dio;
  final Dio _bareDio;
  final void Function(String? token) _setAccessToken;
  String _baseUrl;

  /// Throws away pooled/half-open connections and any in-flight request state.
  ///
  /// A mobile network that changed underneath us can leave sockets that never
  /// complete and never time out, which shows up as a sync that hangs forever;
  /// a fresh client is the reliable way out. Returns false when the platform
  /// has no IO adapter to rebuild.
  bool resetConnections() {
    try {
      final old = dio.httpClientAdapter;
      dio.httpClientAdapter = IOHttpClientAdapter();
      if (old is IOHttpClientAdapter) old.close(force: true);
      final oldBare = _bareDio.httpClientAdapter;
      _bareDio.httpClientAdapter = IOHttpClientAdapter();
      if (oldBare is IOHttpClientAdapter) oldBare.close(force: true);
      return true;
    } on Object {
      return false;
    }
  }

  /// The server currently in use.
  String get baseUrl => _baseUrl;

  /// Repoints the client at another server. Tokens are server-scoped by the
  /// caller ([TokenBox.serverKey]); this only rewrites the transport target.
  void setBaseUrl(String url) {
    _baseUrl = url;
    dio.options.baseUrl = url;
    _bareDio.options.baseUrl = url;
  }

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

  /// POST on the bare transport: no auth interceptor, no shared queues. Only
  /// for the token endpoints whose body itself carries the credential.
  Future<Response<dynamic>> postBare(String path, {Object? body}) =>
      _guard(() => _bareDio.post<dynamic>(path, data: body));

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
///
/// The refresh itself runs on [ApiHttp]'s bare transport (never through
/// [dio]), so the `await onRefresh()` below can never deadlock the error
/// queue it is blocking. A hard 20s ceiling bounds the wait even if the
/// refresh transport wedges, so a stalled cycle degrades into an error
/// instead of an eternal spinner.
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

  static const _refreshWait = Duration(seconds: 20);

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
        final ok = await onRefresh().timeout(_refreshWait);
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
