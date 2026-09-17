import 'package:dio/dio.dart';

import '../../core/util/json_utils.dart';

/// One downloadable file attached to a release.
class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.url});

  final String name;
  final String url;
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
              headers: {'Accept': 'application/vnd.github+json'},
            ));

  final Dio _dio;

  /// Fetches the newest non-draft, non-prerelease release.
  Future<ReleaseInfo> latestRelease(String url) async {
    final res = await _dio.get<dynamic>(url);
    final body = res.data;
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
}
