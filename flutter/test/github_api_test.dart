import 'dart:convert';
import 'dart:typed_data';

import 'package:course_planner/data/api/github_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.statusCode, this.body, {this.headers = const {}});

  final int statusCode;
  final String body;
  final Map<String, List<String>> headers;
  RequestOptions? last;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    last = options;
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        ...headers,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _RoutingAdapter implements HttpClientAdapter {
  RequestOptions? lastApi;
  RequestOptions? lastHtml;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.host == 'api.github.com') {
      lastApi = options;
      return ResponseBody.fromString(
        jsonEncode({'message': 'API rate limit exceeded'}),
        403,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
          'x-ratelimit-remaining': ['0'],
          'x-ratelimit-reset': ['1795853424'],
        },
      );
    }
    lastHtml = options;
    return ResponseBody.fromString(
      '',
      302,
      headers: {
        'location': [
          'https://github.com/LendYanTing/Course-Planner/releases/tag/v1.0.1',
        ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('sends a User-Agent and parses the latest release', () async {
    final adapter = _FakeAdapter(
      200,
      jsonEncode({
        'tag_name': 'v1.0.0',
        'name': 'Course Planner 1.0',
        'html_url': 'https://example.test/release',
        'body': 'notes',
        'assets': [
          {
            'name': 'course-planner-1.0.0-arm64-v8a.apk',
            'browser_download_url': 'https://example.test/app.apk',
          },
        ],
      }),
    );
    final api = GithubApi(dio: Dio()..httpClientAdapter = adapter);

    final release = await api.latestRelease('https://api.github.com/ok');

    expect(release.tag, 'v1.0.0');
    expect(release.assets.single.name, 'course-planner-1.0.0-arm64-v8a.apk');
    final ua = adapter.last!.headers['User-Agent']?.toString() ?? '';
    expect(ua, contains('Course-Planner/'));
  });

  test('maps a rate-limited 403 to an actionable message when the fallback fails',
      () async {
    final adapter = _FakeAdapter(
      403,
      jsonEncode({'message': 'API rate limit exceeded for 1.2.3.4.'}),
      headers: {
        'x-ratelimit-remaining': ['0'],
        'x-ratelimit-reset': ['1795853424'],
      },
    );
    final api = GithubApi(dio: Dio()..httpClientAdapter = adapter);

    await expectLater(
      api.latestRelease('https://api.github.com/limited'),
      throwsA(
        isA<GithubApiException>()
            .having((e) => e.statusCode, 'statusCode', 403)
            .having((e) => e.message, 'message',
                allOf(contains('请求次数已用尽'), contains('全部版本'))),
      ),
    );
  });

  test('falls back to the HTML redirect when the API quota is exhausted',
      () async {
    final adapter = _RoutingAdapter();
    final api = GithubApi(dio: Dio()..httpClientAdapter = adapter);

    final release = await api.latestRelease('https://api.github.com/fallback');

    expect(release.tag, 'v1.0.1');
    expect(release.htmlUrl, contains('/releases/tag/v1.0.1'));
    expect(
      release.assets.map((a) => a.name),
      containsAll([
        'course-planner-1.0.1-arm64-v8a.apk',
        'course-planner-1.0.1-windows-x64.zip',
      ]),
    );
    expect(adapter.lastApi?.headers['User-Agent'], contains('Course-Planner/'));
    expect(adapter.lastHtml?.headers['User-Agent'], contains('Course-Planner/'));
  });

  test('maps a non-rate-limit 403 to a network/proxy hint', () async {
    final adapter = _FakeAdapter(
      403,
      'Request forbidden by administrative rules.',
      headers: {
        'x-ratelimit-remaining': ['42'],
      },
    );
    final api = GithubApi(dio: Dio()..httpClientAdapter = adapter);

    await expectLater(
      api.latestRelease('https://api.github.com/forbidden'),
      throwsA(
        isA<GithubApiException>().having(
          (e) => e.message,
          'message',
          allOf(contains('403'), contains('代理')),
        ),
      ),
    );
  });
}
