/// Static facts about this build.
///
/// Kept as constants on purpose: reading them through a plugin
/// (`package_info_plus`) would add a dependency for one string.
/// **Keep [version] and [build] in sync with `pubspec.yaml`.**
class AppInfo {
  AppInfo._();

  /// `version:` in pubspec.yaml, without the `+build` part.
  static const version = '0.2.4';
  static const build = 6;

  static const versionLabel = '$version+$build';

  static const repo = 'LendYanTing/Course-Planner';
  static const repoUrl = 'https://github.com/$repo';
  static const releasesUrl = '$repoUrl/releases';
  static const latestReleaseApi = 'https://api.github.com/repos/$repo/releases/latest';
}

/// Compares dotted versions (`v0.2.3`, `0.2`, `1.0.0+4`). Returns a negative
/// number when [a] is older than [b], 0 when equal, positive when newer.
///
/// Pre-release/build suffixes are ignored: they only order the same core
/// version, and we never want to nag about those.
int compareVersions(String a, String b) {
  List<int> parse(String v) {
    final core = v.replaceFirst(RegExp(r'^[vV]'), '').split('+').first;
    final parts = core.split('.');
    return [
      for (var i = 0; i < 3; i++)
        i < parts.length ? (int.tryParse(parts[i].trim()) ?? 0) : 0,
    ];
  }

  final x = parse(a);
  final y = parse(b);
  for (var i = 0; i < 3; i++) {
    if (x[i] != y[i]) return x[i] - y[i];
  }
  return 0;
}
