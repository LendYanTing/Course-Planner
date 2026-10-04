import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:course_planner/core/error/api_exception.dart';
import 'package:course_planner/data/api/http_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Programmable adapter: every request is recorded and answered by [handle].
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handle);

  final Future<ResponseBody> Function(RequestOptions options) handle;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return handle(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Map<String, dynamic> body, int status) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );

// A ResponseBody's stream can be consumed exactly once, so every request
// must get a freshly built body — never a shared instance.
ResponseBody _unauthorized() => _json({
      'error': {'code': 'UNAUTHORIZED', 'message': 'refresh token is invalid, expired or already used'},
    }, 401);

ResponseBody _tokenPayload() => _json({
      'data': {
        'user': {'id': 'u1', 'username': 'tester', 'timezone': 'Asia/Shanghai'},
        'accessToken': 'at2',
        'expiresIn': 900,
        'refreshToken': 'rt2',
      },
    }, 200);

void main() {
  group('ApiHttp auth interceptor', () {
    test('401 refreshes via the bare transport and retries the request', () async {
      final adapter = _FakeAdapter((options) async {
        if (options.uri.path.endsWith('/auth/refresh')) return _tokenPayload();
        // The retried request carries the fresh token; the first one does not.
        if (options.headers['Authorization'] == 'Bearer at2') {
          return _json({'data': {'serverCursor': 5}}, 200);
        }
        return _unauthorized();
      });
      late final ApiHttp http;
      http = ApiHttp.create(
        baseUrl: 'http://test.local',
        adapter: adapter,
        onRefresh: () async {
          try {
            final res = await http.postBare('/auth/refresh', body: {'refreshToken': 'rt1'});
            http.setAccessToken('at2');
            return res.statusCode == 200;
          } on Object {
            return false;
          }
        },
      );

      final res = await http.get('/sync/state');
      expect(res.statusCode, 200);
      final paths = adapter.requests.map((r) => r.uri.path).toList();
      expect(paths.where((p) => p.endsWith('/auth/refresh')), hasLength(1));
      expect(paths.where((p) => p.endsWith('/sync/state')), hasLength(2));
      // The retry must carry the refreshed access token.
      final retry = adapter.requests.last;
      expect(retry.headers['Authorization'], 'Bearer at2');
    });

    test('a failed refresh propagates the 401 and never wedges the queue', () async {
      // Regression for the observed outage: with the refresh request sharing
      // the auth interceptor's queues, the second 401 could never be
      // dispatched — sync hung forever with no error reaching the engine.
      final adapter = _FakeAdapter((options) async {
        if (options.uri.path.endsWith('/auth/refresh')) return _unauthorized();
        return _unauthorized();
      });
      late final ApiHttp http;
      http = ApiHttp.create(
        baseUrl: 'http://test.local',
        adapter: adapter,
        onRefresh: () async {
          try {
            await http.postBare('/auth/refresh', body: {'refreshToken': 'rt1'});
            return true;
          } on Object {
            return false;
          }
        },
      );

      await expectLater(
        http.get('/sync/state').timeout(const Duration(seconds: 10)),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)),
      );
      // The next cycle's 401 must reach the caller too.
      await expectLater(
        http.get('/sync/state').timeout(const Duration(seconds: 10)),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)),
      );
    });

    test('bare refresh transport survives a hung refresh (bounded wait)', () async {
      // The refresh endpoint hangs: the 401 must still propagate (bounded by
      // the interceptor's wait ceiling + dio timeouts) instead of hanging.
      final refreshStarted = Completer<void>();
      final never = Completer<ResponseBody>().future;
      final adapter = _FakeAdapter((options) async {
        if (options.uri.path.endsWith('/auth/refresh')) {
          refreshStarted.complete();
          return never;
        }
        return _unauthorized();
      });
      late final ApiHttp http;
      http = ApiHttp.create(
        baseUrl: 'http://test.local',
        adapter: adapter,
        onRefresh: () async {
          try {
            await http.postBare('/auth/refresh', body: {'refreshToken': 'rt1'});
            return true;
          } on Object {
            return false;
          }
        },
      );

      // dio's own connect/receive timeouts do not fire against a fake adapter
      // (no real socket), so the interceptor's wait ceiling is what unblocks
      // this. Give it 25s — the ceiling is 20s.
      await expectLater(
        http.get('/sync/state').timeout(const Duration(seconds: 25)),
        throwsA(isA<ApiException>()),
      );
      expect(refreshStarted.future, completes);
    }, timeout: const Timeout(Duration(seconds: 40)));
  });
}
