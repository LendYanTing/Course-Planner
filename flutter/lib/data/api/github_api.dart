import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/config/app_info.dart';
import '../../core/util/json_utils.dart';

/// One downloadable file attached to a release.
class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.url});

  final String name;
  final String url;
}

/// A checked update failure that is safe to show to the user.
class GithubApiException implements Exception {
  const GithubApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// A published release, reduced to what the About page needs.
class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.name,
    required this.notes,
    required this.htmlUrl,
    this.assets = const [],
    this.publishedAt,
  });

  final String tag;
  final String name;
  final String notes;
  final String htmlUrl;
  final List<ReleaseAsset> assets;
  final String? publishedAt;
}

/// Picks the artifact that belongs on this device.
///
/// Android releases ship one APK per ABI (plus optionally a universal one); the
/// build injects [AppInfo.abi] so the right file is chosen rather than the
/// first `.apk` in the list. Desktop releases ship an archive.
ReleaseAsset? pickReleaseAsset(
  List<ReleaseAsset> assets, {
  required bool isAndroid,
  required bool isWindows,
  required String abi,
}) {
  bool has(ReleaseAsset a, String needle) =>
      a.name.toLowerCase().contains(needle.toLowerCase());

  if (isAndroid) {
    final apks = assets.where((a) => a.name.toLowerCase().endsWith('.apk')).toList();
    if (apks.isEmpty) return null;
    if (abi.isNotEmpty) {
      final exact = apks.where((a) => has(a, abi)).firstOrNull;
      if (exact != null) return exact;
    }
    return apks.where((a) => has(a, 'universal')).firstOrNull ?? apks.first;
  }
  if (isWindows) {
    return assets.where((a) => has(a, 'windows')).firstOrNull;
  }
  return null;
}

/// Reads public release metadata from the GitHub REST API.
///
/// Uses its own Dio instance: the app's shared client carries the backend base
/// URL and the bearer interceptor, neither of which belongs on github.com.
class GithubApi {
  GithubApi({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 20),
              headers: {
                'Accept': 'application/vnd.github+json',
                // GitHub rejects requests without a User-Agent with HTTP 403
                // ("Request forbidden by administrative rules").
                'User-Agent': 'Course-Planner/${AppInfo.versionLabel}',
              },
            ));

  final Dio _dio;

  /// Recent successful answers, so tapping 检查更新 repeatedly does not burn
  /// the 60/hour unauthenticated GitHub quota.
  static final Map<String, ({DateTime at, ReleaseInfo release})> _cache = {};

  /// Fetches the newest non-draft, non-prerelease release.
  Future<ReleaseInfo> latestRelease(String url) async {
    final cached = _cache[url];
    if (cached != null &&
        DateTime.now().difference(cached.at) < const Duration(minutes: 5)) {
      return cached.release;
    }
    try {
      final release = await _fetchApi(url);
      _cache[url] = (at: DateTime.now(), release: release);
      return release;
    } on GithubApiException {
      // The unauthenticated REST API allows 60 requests/hour per IP, which
      // carrier NATs exhaust quickly. github.com/releases/latest redirects to
      // the tag and is not subject to that quota.
      final fallback = await _fetchLatestTagFallback();
      if (fallback != null) {
        _cache[url] = (at: DateTime.now(), release: fallback);
        return fallback;
      }
      rethrow;
    }
  }

  Future<ReleaseInfo> _fetchApi(String url) async {
    late final Response<String> res;
    try {
      res = await _dio.get<String>(
        url,
        options: Options(
          // Plain text keeps the response attached to 403/404 DioExceptions;
          // GitHub's "administrative rules" 403 is HTML, not JSON.
          responseType: ResponseType.plain,
          headers: {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'Course-Planner/${AppInfo.versionLabel}',
          },
        ),
      );
    } on DioException catch (e) {
      throw GithubApiException(_describeDioError(e),
          statusCode: e.response?.statusCode);
    }
    Object? decoded;
    try {
      decoded = jsonDecode(res.data ?? '');
    } on FormatException {
      throw const GithubApiException('GitHub 返回了无法识别的响应，请稍后重试。');
    }
    final body = decoded;
    if (body is! Map) throw const FormatException('unexpected release payload');
    final m = Map<String, dynamic>.from(body);

    final parsed = <ReleaseAsset>[];
    final assets = m['assets'];
    if (assets is List) {
      for (final raw in assets) {
        if (raw is! Map) continue;
        final a = Map<String, dynamic>.from(raw);
        final name = readStringOrNull(a, 'name') ?? '';
        final url = readStringOrNull(a, 'browser_download_url');
        if (name.isEmpty || url == null) continue;
        parsed.add(ReleaseAsset(name: name, url: url));
      }
    }

    return ReleaseInfo(
      tag: readString(m, 'tag_name'),
      name: readString(m, 'name', fallback: readString(m, 'tag_name')),
      notes: readString(m, 'body'),
      htmlUrl: readString(m, 'html_url'),
      assets: parsed,
      publishedAt: readStringOrNull(m, 'published_at'),
    );
  }

  /// Resolves the latest tag from the HTML redirect, without using the REST
  /// API quota. Assets follow the project's release-file naming convention so
  /// the download button still works when the API is rate-limited.
  Future<ReleaseInfo?> _fetchLatestTagFallback() async {
    try {
      final res = await _dio.get<String>(
        '${AppInfo.repoUrl}/releases/latest',
        options: Options(
          followRedirects: false,
          validateStatus: (status) => status != null && status < 400,
          responseType: ResponseType.plain,
          headers: {
            'User-Agent': 'Course-Planner/${AppInfo.versionLabel}',
          },
        ),
      );
      final location = res.headers.value('location') ?? '';
      final match = RegExp(r'/releases/tag/([^/?#]+)').firstMatch(location);
      if (match == null) return null;
      final tag = Uri.decodeComponent(match.group(1)!);
      final version = tag.replaceFirst(RegExp(r'^[vV]'), '');
      final base =
          '${AppInfo.repoUrl}/releases/download/$tag/course-planner-$version';
      return ReleaseInfo(
        tag: tag,
        name: tag,
        notes: '',
        htmlUrl: '${AppInfo.repoUrl}/releases/tag/$tag',
        assets: [
          for (final suffix in const [
            'arm64-v8a.apk',
            'armeabi-v7a.apk',
            'x86_64.apk',
            'windows-x64.zip',
          ])
            ReleaseAsset(name: 'course-planner-$version-$suffix', url: '$base-$suffix'),
        ],
      );
    } on Object {
      return null;
    }
  }

  /// Turns GitHub/Dio failures into one actionable sentence instead of dumping
  /// the DioException type and a generic HTTP explainer at the user.
  static String _describeDioError(DioException error) {
    final response = error.response;
    final code = response?.statusCode;
    final data = response?.data;
    String? apiMessage;
    if (data is Map) {
      final raw = data['message'];
      if (raw is String && raw.trim().isNotEmpty) apiMessage = raw.trim();
    } else if (data is String && data.trim().isNotEmpty) {
      final trimmed = data.trim();
      // The rate-limit body is JSON even when Dio did not decode it.
      if (trimmed.startsWith('{') && trimmed.length < 2000) {
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is Map && decoded['message'] is String) {
            apiMessage = (decoded['message'] as String).trim();
          }
        } on FormatException {
          // Keep raw HTML/plain bodies out of the UI.
        }
      }
    }

    if (code == 403) {
      final remaining =
          response?.headers.value('x-ratelimit-remaining')?.trim();
      final reset =
          int.tryParse(response?.headers.value('x-ratelimit-reset')?.trim() ?? '');
      final rateLimited = remaining == '0' ||
          (apiMessage?.toLowerCase().contains('rate limit') ?? false);
      if (rateLimited) {
        var when = '';
        if (reset != null) {
          final local = DateTime.fromMillisecondsSinceEpoch(
            reset * 1000,
            isUtc: true,
          ).toLocal();
          final hh = local.hour.toString().padLeft(2, '0');
          final mm = local.minute.toString().padLeft(2, '0');
          when = '，约 $hh:$mm 后恢复';
        }
        return 'GitHub API 请求次数已用尽（403）$when。'
            '也可以点下方「全部版本」直接打开 Releases 页面。';
      }
      final detail = apiMessage == null ? '' : '：$apiMessage';
      return 'GitHub 拒绝了检查更新请求（403）$detail。'
          '请检查网络/代理，或稍后重试。';
    }
    if (code == 404) {
      return '没有找到可用的 Release（404）。请点「全部版本」查看发布页。';
    }
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return '连接 GitHub 超时，请检查网络或代理后重试。';
      case DioExceptionType.connectionError:
        return '无法连接 GitHub，请检查网络或代理后重试。';
      default:
        break;
    }
    final detail = apiMessage == null ? '' : '：$apiMessage';
    return '检查更新失败（HTTP ${code ?? '网络错误'}）$detail';
  }
}
