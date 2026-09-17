import 'package:course_planner/core/config/app_info.dart';
import 'package:course_planner/data/api/github_api.dart';
import 'package:course_planner/presentation/settings/about_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The About page is reachable from 设置 → 关于; this checks it renders the
/// version and the links (the update check itself needs the network).
void main() {
  testWidgets('AboutPage shows the version and the project links', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AboutPage())),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('关于'), findsOneWidget);
    expect(find.text('Course Planner'), findsOneWidget);
    expect(find.text('版本 ${AppInfo.versionLabel}'), findsOneWidget);

    expect(find.text('检查更新'), findsOneWidget);
    expect(find.text('项目主页'), findsOneWidget);
    expect(find.text(AppInfo.repoUrl), findsOneWidget);
    expect(find.text('全部版本'), findsOneWidget);
    // Nothing is fetched until the user taps 检查更新.
    expect(find.text('从 GitHub 读取最新版本'), findsOneWidget);
  });

  group('pickReleaseAsset', () {
    const assets = [
      ReleaseAsset(name: 'course-planner-1.0.0-universal.apk', url: 'u'),
      ReleaseAsset(name: 'course-planner-1.0.0-arm64-v8a.apk', url: 'a64'),
      ReleaseAsset(name: 'course-planner-1.0.0-armeabi-v7a.apk', url: 'a32'),
      ReleaseAsset(name: 'course-planner-1.0.0-x86_64.apk', url: 'x64'),
      ReleaseAsset(name: 'course-planner-1.0.0-windows-x64.zip', url: 'win'),
      ReleaseAsset(name: 'checksums.txt', url: 'sums'),
    ];

    ReleaseAsset? pick({
      bool android = false,
      bool windows = false,
      String abi = '',
    }) =>
        pickReleaseAsset(assets,
            isAndroid: android, isWindows: windows, abi: abi);

    test('android picks the artifact built for its own ABI', () {
      expect(pick(android: true, abi: 'arm64-v8a')!.url, 'a64');
      expect(pick(android: true, abi: 'armeabi-v7a')!.url, 'a32');
      expect(pick(android: true, abi: 'x86_64')!.url, 'x64');
    });

    test('android without a compiled-in ABI falls back to universal', () {
      expect(pick(android: true)!.url, 'u');
    });

    test('an unknown ABI still falls back to universal', () {
      expect(pick(android: true, abi: 'riscv64')!.url, 'u');
    });

    test('android with only per-ABI files takes the first apk', () {
      final only = assets.where((a) => !a.name.contains('universal')).toList();
      final picked = pickReleaseAsset(only,
          isAndroid: true, isWindows: false, abi: 'riscv64');
      expect(picked!.name.endsWith('.apk'), isTrue);
    });

    test('windows picks the archive, not an apk', () {
      expect(pick(windows: true)!.url, 'win');
    });

    test('other platforms get nothing (the page offers the release page)', () {
      expect(pick(), isNull);
      expect(pickReleaseAsset(const [], isAndroid: true, isWindows: false, abi: ''), isNull);
    });
  });
}
