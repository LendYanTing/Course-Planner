import 'package:course_planner/agent/agent_config.dart';
import 'package:course_planner/agent/llm_client.dart';
import 'package:course_planner/core/util/week_text.dart';
import 'package:course_planner/domain/edu_import/edu_ai_extractor.dart';
import 'package:course_planner/domain/edu_import/edu_html_parser.dart';
import 'package:course_planner/domain/week_rule.dart';
import 'package:flutter_test/flutter_test.dart';

/// Returns a canned assistant turn; no socket is ever opened.
class _FakeLlmClient extends LlmClient {
  _FakeLlmClient(this.reply);

  final String? reply;
  int calls = 0;
  List<Map<String, dynamic>>? lastMessages;

  @override
  Future<LlmReply> complete({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
  }) async {
    calls++;
    lastMessages = messages;
    return LlmReply(content: reply, finishReason: 'stop');
  }
}

const _zhengfangJson = '''
{"kbList":[
{"kcmc":"高等数学A(1)","xm":"张教授","cdmc":"逸夫楼201","xqj":"1","jcs":"1-2","zcd":"1-16周"},
{"kcmc":"线性代数","xm":"李老师","cdmc":"理工楼110","xqj":3,"jcs":"3-4节","zcd":"1-16周(单)"}
],
"jcList":[{"jc":"1","qssj":"08:00","jssj":"08:45"},{"jc":"2","qssj":"08:55","jssj":"09:40"}]}
''';

const _tableHtml = '''
<html><head><title>课表</title>
<style>td { color: red; }</style>
<script>var kbList = [];</script>
</head><body>
<table border="1">
<tr><th>节次</th><th>周一</th><th>周二</th><th>周三</th><th>周四</th><th>周五</th><th>周六</th><th>周日</th></tr>
<tr>
<td>第1-2节</td>
<td>高等数学A(1)<br/>1-16周<br/>张教授@逸夫楼201</td>
<td>&nbsp;</td>
<td>线性代数<br/>1-16周(单)<br/>李老师@理工楼110</td>
<td></td><td></td><td></td><td></td>
</tr>
<tr>
<td>第3-4节</td>
<td></td><td>大学物理<br/>1-16周<br/>王五 文成楼125</td>
<td></td><td></td><td></td><td></td><td></td>
</tr>
</table>
</body></html>
''';

void main() {
  group('EduHtmlParser.parse — new Zhengfang JSON', () {
    test('maps kbList fields to courses and reads the period table', () {
      final result = EduHtmlParser.parse(_zhengfangJson);

      expect(result.source, 'zhengfang-json');
      expect(result.courses, hasLength(2));

      final first = result.courses[0];
      expect(first.name, '高等数学A(1)');
      expect(first.weekday, 1);
      expect(first.periodStart, 1);
      expect(first.periodEnd, 2);
      expect(first.teacher, '张教授');
      expect(first.location, '逸夫楼201');
      expect(first.weekRuleText, '1-16');

      final second = result.courses[1];
      expect(second.name, '线性代数');
      expect(second.weekday, 3);
      expect(second.periodStart, 3);
      expect(second.periodEnd, 4);
      expect(second.weekRuleText, isNotNull);
      final rule = parseWeekRuleText(second.weekRuleText!);
      expect(rule, isNotNull);
      expect(rule!.segments.single.parity, WeekParity.odd);
      expect(rule.weeks(16), [1, 3, 5, 7, 9, 11, 13, 15]);

      expect(result.periods, hasLength(2));
      expect(result.periods.first.periodNo, 1);
      expect(result.periods.first.startLocal, '08:00');
      expect(result.periods.first.endLocal, '08:45');
    });

    test('finds kbList embedded in an HTML script block', () {
      const html =
          '<html><body><script type="text/javascript">'
          'var kbList = ['
          '{"kcmc":"概率论","xm":"赵六","cdmc":"南楼101","xqj":"5",'
          '"jcs":"5-6","zcd":"1-8周(双)"}'
          '];</script></body></html>';
      final result = EduHtmlParser.parse(html);

      expect(result.source, 'zhengfang-json');
      expect(result.courses, hasLength(1));
      expect(result.courses.single.name, '概率论');
      expect(result.courses.single.weekday, 5);
      expect(result.courses.single.periodStart, 5);
      final rule = parseWeekRuleText(result.courses.single.weekRuleText!);
      expect(rule!.weeks(8), [2, 4, 6, 8]);
    });
  });

  group('EduHtmlParser.parse — HTML tables', () {
    test('reads a header row, row periods, @ teacher/room', () {
      final result = EduHtmlParser.parse(_tableHtml);

      expect(result.source, 'table');
      expect(result.courses, hasLength(3));

      final math = result.courses[0];
      expect(math.name, '高等数学A(1)');
      expect(math.weekday, 1);
      expect(math.periodStart, 1);
      expect(math.periodEnd, 2);
      expect(math.teacher, '张教授');
      expect(math.location, '逸夫楼201');
      expect(parseWeekRuleText(math.weekRuleText!), isNotNull);

      final linear = result.courses[1];
      expect(linear.name, '线性代数');
      expect(linear.weekday, 3);
      expect(linear.teacher, '李老师');
      expect(linear.location, '理工楼110');
      expect(
        parseWeekRuleText(linear.weekRuleText!)!.segments.single.parity,
        WeekParity.odd,
      );

      final physics = result.courses[2];
      expect(physics.name, '大学物理');
      expect(physics.weekday, 2);
      expect(physics.periodStart, 3);
      expect(physics.periodEnd, 4);
      expect(physics.teacher, '王五');
      expect(physics.location, '文成楼125');
    });

    test('splits several courses packed into one cell', () {
      const html = '''
<table>
<tr><td>1-2节</td>
<td>高等数学<br>1-16周<br>张三<br>逸夫楼201<br>线性代数<br>1-8周<br>李四<br>理工楼110</td>
<td></td><td></td><td></td><td></td><td></td><td></td></tr>
</table>''';
      final result = EduHtmlParser.parse(html);

      expect(result.courses, hasLength(2));
      expect(result.courses[0].name, '高等数学');
      expect(result.courses[0].teacher, '张三');
      expect(result.courses[0].location, '逸夫楼201');
      expect(result.courses[1].name, '线性代数');
      expect(result.courses[1].teacher, '李四');
      expect(result.courses[1].location, '理工楼110');
      expect(result.courses[1].weekRuleText, '1-8');
    });

    test('infers weekdays from columns when the header is missing', () {
      const html = '''
<table>
<tr><td>1-2节</td><td>高等数学</td><td></td><td>线性代数</td><td></td><td></td><td></td><td></td></tr>
</table>''';
      final result = EduHtmlParser.parse(html);

      expect(result.source, 'table');
      expect(result.courses, hasLength(2));
      expect(result.courses[0].name, '高等数学');
      expect(result.courses[0].weekday, 1);
      expect(result.courses[1].name, '线性代数');
      expect(result.courses[1].weekday, 3);
    });
  });

  group('EduHtmlParser.parseText', () {
    test('parses shuffled fields, tabs and full-width spaces', () {
      const text =
          '高等数学A(1)　周一　1-2节　1-16周　张三　逸夫楼201\n'
          '逸夫楼201 周三 第3-4节 1-16周 李四 大学物理\n'
          '大学英语\t周五\t(5-6节)\t1-8周\t王五\t文成楼125\n';
      final result = EduHtmlParser.parseText(text);

      expect(result.source, 'text');
      expect(result.courses, hasLength(3));

      final math = result.courses[0];
      expect(math.name, '高等数学A(1)');
      expect(math.weekday, 1);
      expect(math.periodStart, 1);
      expect(math.periodEnd, 2);
      expect(math.teacher, '张三');
      expect(math.location, '逸夫楼201');
      expect(math.weekRuleText, '1-16');

      final physics = result.courses[1];
      expect(physics.name, '大学物理');
      expect(physics.weekday, 3);
      expect(physics.periodStart, 3);
      expect(physics.periodEnd, 4);
      expect(physics.teacher, '李四');
      expect(physics.location, '逸夫楼201');

      final english = result.courses[2];
      expect(english.name, '大学英语');
      expect(english.weekday, 5);
      expect(english.periodStart, 5);
      expect(english.periodEnd, 6);
      expect(english.teacher, '王五');
      expect(english.location, '文成楼125');
    });

    test('keeps a name that sits on its own line above the detail line', () {
      const text = '高等数学\n周一第1-2节 1-16周 张三 逸夫楼201\n';
      final result = EduHtmlParser.parseText(text);

      expect(result.courses, hasLength(1));
      expect(result.courses.single.name, '高等数学');
      expect(result.courses.single.teacher, '张三');
      expect(result.courses.single.location, '逸夫楼201');
    });

    test('skips headers, notes and lines without periods', () {
      const text =
          '课程名称 教师 周次\n'
          '备注：本表仅供参考\n'
          '高等数学 周一 1-2节 1-16周 张三 逸夫楼201\n'
          '打印时间 2026-09-01\n';
      final result = EduHtmlParser.parseText(text);

      expect(result.courses, hasLength(1));
      expect(result.courses.single.name, '高等数学');
    });
  });

  group('stripHtmlForAi', () {
    test('drops script/style and shrinks the page', () {
      final html =
          '<html><head><script>${'var leak = 1;' * 400}</script>'
          '<style>${'.x { color: red; }' * 200}</style></head>'
          '<body><table><tr><td>高等数学A(1)</td><td>周一 1-2节</td></tr>'
          '</table><div>备注</div></body></html>';
      final stripped = EduHtmlParser.stripHtmlForAi(html);

      expect(stripped.toLowerCase().contains('<script'), isFalse);
      expect(stripped.toLowerCase().contains('color: red'), isFalse);
      expect(stripped.length, lessThan(html.length));
      expect(stripped, contains('高等数学A(1)'));
    });

    test('honours maxChars', () {
      final html = '<div>${'课程 ' * 2000}</div>';
      final stripped = EduHtmlParser.stripHtmlForAi(html, maxChars: 120);
      expect(stripped.length, lessThanOrEqualTo(120));
    });
  });

  group('EduHtmlParser.parse — bad input', () {
    test('empty and garbage input yield empty results', () {
      for (final input in ['', '   ', '\n\t\r\n', '<<<>>>', '\u0000\u0001%%']) {
        final result = EduHtmlParser.parse(input);
        expect(result.isEmpty, isTrue, reason: 'input: ${input.length}');
      }
      expect(EduHtmlParser.parseText('nothing here').isEmpty, isTrue);
    });

    test('a broken table does not throw', () {
      final result = EduHtmlParser.parse('<table><tr><td>高等数学<td>');
      expect(result.isEmpty, isTrue);
    });
  });

  group('EduAiExtractor', () {
    test('parses a fenced JSON array and skips invalid entries', () async {
      final client = _FakeLlmClient('''```json
[
 {"name":"高等数学A(1)","weekday":1,"periodStart":1,"periodEnd":2,
  "teacher":"张教授","location":"逸夫楼201","weeks":"1-16"},
 {"name":"坏行","weekday":9,"periodStart":1,"periodEnd":2,"weeks":"1-16"},
 {"name":"线性代数","weekday":3,"periodStart":3,"periodEnd":4,
  "teacher":null,"location":"理工楼110","weeks":"1-16周(双)"}
]
```''');
      final extractor = EduAiExtractor(
        client: client,
        config: const LlmConfig(),
      );
      final courses = await extractor.extract('高等数学 ...');

      expect(client.calls, 1);
      expect(courses, hasLength(2));
      expect(courses[0].name, '高等数学A(1)');
      expect(courses[0].weekday, 1);
      expect(courses[0].teacher, '张教授');
      expect(courses[0].line, 1);
      expect(courses[1].name, '线性代数');
      expect(courses[1].weekRuleText, '1-16双');
      expect(parseWeekRuleText(courses[1].weekRuleText!)!.weeks(16), [
        2,
        4,
        6,
        8,
        10,
        12,
        14,
        16,
      ]);
      expect(client.lastMessages!.first['role'], 'system');
      expect(client.lastMessages!.first['content'], contains('JSON'));
    });

    test('throws LlmException for unusable answers', () async {
      final client = _FakeLlmClient('抱歉，我无法解析这段内容。');
      final extractor = EduAiExtractor(
        client: client,
        config: const LlmConfig(),
      );

      expect(
        () => extractor.extract('some content'),
        throwsA(isA<LlmException>()),
      );
    });

    test('throws LlmException for an empty request or empty reply', () async {
      final extractor = EduAiExtractor(
        client: _FakeLlmClient(null),
        config: const LlmConfig(),
      );

      expect(() => extractor.extract('  '), throwsA(isA<LlmException>()));
      expect(() => extractor.extract('content'), throwsA(isA<LlmException>()));
    });
  });
}
