import 'package:course_planner/app/theme.dart';
import 'package:course_planner/presentation/widgets/app_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Markdown rendering for agent replies: block structure, inline style
/// resolution, the code-block copy action, and the edge cases that used to
/// crash naive parsers.
const String _sample = '''
# 课程表
### 今日课程

**加粗** 与 *斜体*，还有 ~~删除~~ 和 `行内代码`。

- 列表项一
- 列表项二
1. 有序项

---

| 星期 | 课程 |
| --- | --- |
| 周一 | 高等数学 |

```json
{"mode": "fast"}
```
''';

Widget _host(Widget child, {Brightness brightness = Brightness.light}) {
  return MaterialApp(
    theme: brightness == Brightness.light ? AppTheme.light() : AppTheme.dark(),
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: child,
      ),
    ),
  );
}

/// A tall logical surface so the whole sample is laid out on screen (taps on
/// off-screen widgets would silently miss).
void _useTallSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(900, 2000);
  addTearDown(tester.view.reset);
}

/// Every leaf-capable span reachable from the rendered rich text.
Iterable<TextSpan> _textSpans(WidgetTester tester) sync* {
  for (final richText in tester.widgetList<RichText>(find.byType(RichText))) {
    final pending = <InlineSpan>[richText.text];
    while (pending.isNotEmpty) {
      final span = pending.removeLast();
      if (span is! TextSpan) continue;
      yield span;
      final children = span.children;
      if (children != null) pending.addAll(children);
    }
  }
}

TextSpan _spanOf(WidgetTester tester, String text) {
  return _textSpans(tester).firstWhere(
    (span) => span.text == text,
    orElse: () => throw StateError('no inline span with text "$text"'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders every block without leaking raw Markdown markers', (
    tester,
  ) async {
    _useTallSurface(tester);
    await tester.pumpWidget(_host(const AppMarkdownContent(data: _sample)));
    await tester.pump();

    final scheme = AppTheme.light().colorScheme;

    // Markers are consumed by the parser, including the table delimiter row.
    expect(find.textContaining('###'), findsNothing);
    expect(find.textContaining('**'), findsNothing);
    expect(find.textContaining('~~'), findsNothing);
    expect(find.textContaining('|'), findsNothing);
    expect(find.textContaining('---'), findsNothing);

    // Heading sizes and weights.
    final h1 = tester.widget<Text>(find.text('课程表'));
    expect(h1.style!.fontSize, 19);
    expect(h1.style!.fontWeight, FontWeight.w700);
    final h3 = tester.widget<Text>(find.text('今日课程'));
    expect(h3.style!.fontSize, 15.5);
    expect(h3.style!.fontWeight, FontWeight.w600);

    // Inline emphasis resolves onto the leaf spans.
    expect(_spanOf(tester, '加粗').style!.fontWeight, FontWeight.w700);
    expect(_spanOf(tester, '斜体').style!.fontStyle, FontStyle.italic);
    expect(
      _spanOf(tester, '删除').style!.decoration,
      TextDecoration.lineThrough,
    );

    // Inline code uses the monospace stack and the primary colour.
    final inlineCode = _spanOf(tester, '行内代码').style!;
    expect(inlineCode.fontFamily, 'monospace');
    expect(inlineCode.fontSize, 13);
    expect(inlineCode.color, scheme.primary);
    expect(inlineCode.backgroundColor, scheme.surfaceContainerHighest);

    // List content and the ordered marker.
    expect(find.text('列表项一'), findsOneWidget);
    expect(find.text('列表项二'), findsOneWidget);
    final ordered = tester.widget<Text>(find.text('1.'));
    expect(ordered.style!.color, scheme.primary);

    // Table header and cells.
    final headerCell = tester.widget<Text>(find.text('星期'));
    expect(headerCell.style!.fontWeight, FontWeight.w700);
    final bodyCell = tester.widget<Text>(find.text('周一'));
    expect(bodyCell.style!.fontWeight, FontWeight.w400);
    expect(find.text('高等数学'), findsOneWidget);

    // Fenced code block: language label plus verbatim body.
    expect(find.text('json'), findsOneWidget);
    expect(find.text('{"mode": "fast"}'), findsOneWidget);
    expect(find.byType(Table), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('copy button writes the fenced code to the clipboard', (
    tester,
  ) async {
    _useTallSurface(tester);
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') calls.add(call);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(_host(const AppMarkdownContent(data: _sample)));
    await tester.pump();

    await tester.tap(find.text('复制代码'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));
    expect(calls.single.arguments['text'], '{"mode": "fast"}');
    expect(find.text('已复制代码'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dark theme takes container colours from the ColorScheme', (
    tester,
  ) async {
    _useTallSurface(tester);
    await tester.pumpWidget(
      _host(
        const AppMarkdownContent(data: _sample),
        brightness: Brightness.dark,
      ),
    );
    await tester.pump();

    final scheme = AppTheme.dark().colorScheme;

    final code = tester.widget<Container>(
      find.byKey(const ValueKey('app-markdown-code-0')),
    );
    final codeColour = (code.decoration! as BoxDecoration).color;
    expect(codeColour, scheme.surfaceContainerLowest);
    expect(codeColour, isNot(Colors.white));

    final table = tester.widget<Container>(
      find.byKey(const ValueKey('app-markdown-table-0')),
    );
    final tableBorder = (table.decoration! as BoxDecoration).border! as Border;
    expect(tableBorder.top.color, scheme.outlineVariant);
    expect(tableBorder.top.color, isNot(Colors.white));
    expect(tester.takeException(), isNull);
  });

  testWidgets('inline emphasis variants resolve', (tester) async {
    await tester.pumpWidget(
      _host(
        const AppMarkdownContent(
          data: '**粗体** __下划线粗体__ *斜体* _下划线斜体_ '
              '***粗斜体*** ~~删除线~~ 与 snake_case_name',
        ),
      ),
    );

    expect(_spanOf(tester, '粗体').style!.fontWeight, FontWeight.w700);
    expect(_spanOf(tester, '下划线粗体').style!.fontWeight, FontWeight.w700);
    expect(_spanOf(tester, '斜体').style!.fontStyle, FontStyle.italic);
    expect(_spanOf(tester, '下划线斜体').style!.fontStyle, FontStyle.italic);
    final both = _spanOf(tester, '粗斜体').style!;
    expect(both.fontWeight, FontWeight.w700);
    expect(both.fontStyle, FontStyle.italic);
    expect(
      _spanOf(tester, '删除线').style!.decoration,
      TextDecoration.lineThrough,
    );

    // Underscores inside a word stay literal.
    expect(find.textContaining('snake_case_name'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selectable can be turned off', (tester) async {
    await tester.pumpWidget(
      _host(const AppMarkdownContent(data: '普通段落', selectable: false)),
    );
    expect(find.byType(SelectionArea), findsNothing);

    await tester.pumpWidget(_host(const AppMarkdownContent(data: '普通段落')));
    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('edge cases render without throwing', (tester) async {
    const cases = [
      '',
      '   ',
      '**未闭合',
      '***未闭合',
      '`未闭合',
      '```dart\nvoid main() {',
      '| 无表头 | 表格 |\n| 值 | 值 |',
      '| 只有一列 |',
      '> 引用第一行\n> 引用第二行',
      '######',
      '- ',
    ];
    for (final data in cases) {
      await tester.pumpWidget(_host(AppMarkdownContent(data: data)));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: data);
    }

    // An unclosed fence still renders the code and the copy action.
    await tester.pumpWidget(
      _host(const AppMarkdownContent(data: '```dart\nvoid main() {')),
    );
    expect(find.text('dart'), findsOneWidget);
    expect(find.text('复制代码'), findsOneWidget);

    // Unclosed emphasis stays literal instead of swallowing characters.
    await tester.pumpWidget(
      _host(const AppMarkdownContent(data: '**未闭合')),
    );
    expect(find.textContaining('**未闭合'), findsOneWidget);
  });
}
