import 'package:course_planner/core/edu/edu_webview_bridge.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/edu_import/school_catalog.dart';
import 'package:course_planner/presentation/settings/edu_import_page.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:course_planner/state/session.dart';
import 'package:course_planner/state/sync_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_prefs.dart';
import 'helpers/week_page_harness.dart';

/// School-driven import flow (phase 10, Step 5).
///
/// The native browser is replaced by a fake bridge and the catalog by an
/// explicit list, so every case runs offline with no DB writes.
void main() {
  const snapshot = EntitiesSnapshot(
    rows: [
      EntityRow(
        entityType: 'academic_calendar',
        entityId: 'cal-1',
        revision: 1,
        payload: {
          'id': 'cal-1',
          'name': '2026 秋季',
          'firstDay': '2026-09-01',
          'totalWeeks': 20,
          'revision': 1,
        },
      ),
    ],
    pendingOps: [],
    conflicts: [],
  );

  SchoolCatalog catalog() => SchoolCatalog.fromEntries(const [
    SchoolEntry(
      name: '安徽大学',
      loginUrl: 'jw.ahu.edu.cn',
      type: 'shuwei_new',
      mode: '',
      strategy: 'local-parser',
      parser: 'Parser_ShuWei',
    ),
    SchoolEntry(
      name: '安徽理工大学',
      loginUrl: 'https://jw.aust.edu.cn',
      type: 'zf',
      mode: 'pc',
      strategy: 'local-parser',
      parser: 'Parser_ZF',
    ),
    SchoolEntry(
      name: '北京大学',
      loginUrl: '',
      type: 'ai-fallback',
      mode: '',
      strategy: 'ai-fallback',
      parser: 'Parser_GPT',
    ),
  ]);

  Future<void> pumpPage(
    WidgetTester tester, {
    EduWebViewResult? webViewResult,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1000, 2400);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefStoreProvider.overrideWithValue(MemoryPrefs()),
          snapshotProvider.overrideWith((ref) => Stream.value(snapshot)),
          sessionControllerProvider.overrideWith(FakeSession.new),
          serverNowProvider.overrideWith(
            (ref) => Stream.value(DateTime.utc(2026, 9, 9)),
          ),
          schoolCatalogProvider.overrideWith((ref) async => catalog()),
          eduWebViewBridgeProvider.overrideWithValue(
            _FakeBridge(webViewResult),
          ),
        ],
        child: const MaterialApp(home: EduImportPage()),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> pickSchool(WidgetTester tester, String name) async {
    await tester.tap(find.text('搜索全国高校（3570 所）'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(SchoolPickerSheet),
        matching: find.byType(TextField),
      ),
      '安徽',
    );
    await tester.pump();
    await tester.tap(find.text(name));
    await tester.pumpAndSettle();
  }

  testWidgets('选择学校后显示厂商标签与教务网址', (tester) async {
    await pumpPage(tester);
    // The picker is the only place with a search field.
    expect(find.byType(TextField), findsOneWidget);

    await pickSchool(tester, '安徽大学');

    expect(find.text('安徽大学'), findsOneWidget);
    expect(find.text('树维教务'), findsOneWidget);
    expect(find.text('清除'), findsOneWidget);
    // The URL is filled into the address field (and shown on the card).
    expect(find.text('https://jw.ahu.edu.cn'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('内置浏览器返回正方 JSON 时本地解析并预览', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pumpPage(
      tester,
      webViewResult: const EduWebViewResult(
        pageUrl: 'https://jw.ahu.edu.cn/kbcx',
        schoolName: '安徽大学',
        vendorType: 'zf',
        extractedData:
            '{"kbList":[{"kcmc":"高等数学A(1)","xm":"张教授",'
            '"cdmc":"逸夫楼201","xqj":"1","jcs":"1-2","zcd":"1-16周"}]}',
        bestTableHtml: '',
        rawHtml: '',
      ),
    );

    await pickSchool(tester, '安徽大学');
    await tester.tap(find.text('打开教务网登录并提取'));
    await tester.pumpAndSettle();

    expect(find.text('高等数学A(1)'), findsOneWidget);
    expect(find.text('识别到 1 门课（来源：内置浏览器）'), findsOneWidget);
    expect(find.text('确认导入 1 门课程'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('本地未命中且未配置 AI 时把压缩 HTML 填进粘贴框', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const unparsable =
        '<table><tr><th>节次</th><th>星期一</th><th>星期二</th></tr>'
        '<tr><td>课程</td><td>暂无数据</td><td>请登录后查看</td></tr></table>';
    await pumpPage(
      tester,
      webViewResult: const EduWebViewResult(
        pageUrl: 'https://jw.ahu.edu.cn/kbcx',
        schoolName: '安徽大学',
        vendorType: 'unknown',
        extractedData: '',
        bestTableHtml: unparsable,
        rawHtml: unparsable,
      ),
    );

    await pickSchool(tester, '安徽大学');
    await tester.tap(find.text('打开教务网登录并提取'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, contains('<table'));
    expect(find.textContaining('请配置 AI 助手'), findsOneWidget);
    expect(find.text('去配置'), findsOneWidget);
    // No preview: local rules missed and the agent is not configured.
    expect(find.textContaining('确认导入'), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('桌面端显示在浏览器打开教务网', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpPage(tester);

    expect(find.text('在浏览器打开教务网'), findsOneWidget);
    expect(find.text('打开教务网登录并提取'), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}

/// Bridge that returns a fixed capture without touching the platform channel.
class _FakeBridge extends EduWebViewBridge {
  const _FakeBridge(this.result);

  final EduWebViewResult? result;

  @override
  Future<EduWebViewResult?> open({
    required String url,
    String schoolName = '',
    String parserType = '',
    bool desktopMode = false,
  }) async => result;
}
