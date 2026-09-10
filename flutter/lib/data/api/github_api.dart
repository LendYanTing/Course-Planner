import 'package:dio/dio.dart';

import '../../core/util/json_utils.dart';

/// A published release, reduced to what the About page needs.
class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.name,
    required this.notes,
    required this.htmlUrl,
    this.apkUrl,
    this.apkName,
    this.publishedAt,
  });

  final String tag;
  final String name;
  final String notes;
  final String htmlUrl;

  /// Direct download for the Android build, when the release carries one.
  final String? apkUrl;
  final String? apkName;
  final String? publishedAt;
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
              headers: {'Accept': 'application/vnd.github+json'},
            ));

  final Dio _dio;

  /// Fetches the newest non-draft, non-prerelease release.
  Future<ReleaseInfo> latestRelease(String url) async {
    final res = await _dio.get<dynamic>(url);
    final body = res.data;
    if (body is! Map) throw const FormatException('unexpected release payload');
    final m = Map<String, dynamic>.from(body);

    String? apkUrl;
    String? apkName;
    final assets = m['assets'];
    if (assets is List) {
      for (final raw in assets) {
        if (raw is! Map) continue;
        final a = Map<String, dynamic>.from(raw);
        final name = readStringOrNull(a, 'name') ?? '';
        if (!name.toLowerCase().endsWith('.apk')) continue;
        apkName = name;
        apkUrl = readStringOrNull(a, 'browser_download_url');
        break;
      }
    }

    return ReleaseInfo(
      tag: readString(m, 'tag_name'),
      name: readString(m, 'name', fallback: readString(m, 'tag_name')),
      notes: readString(m, 'body'),
      htmlUrl: readString(m, 'html_url'),
      apkUrl: apkUrl,
      apkName: apkName,
      publishedAt: readStringOrNull(m, 'published_at'),
    );
  }
}
