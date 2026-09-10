import 'package:course_planner/core/config/app_info.dart';
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
}
