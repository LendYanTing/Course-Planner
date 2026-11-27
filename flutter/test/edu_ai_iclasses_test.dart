import 'package:course_planner/agent/agent_config.dart';
import 'package:course_planner/agent/llm_client.dart';
import 'package:course_planner/core/util/week_text.dart';
import 'package:course_planner/domain/edu_import/edu_ai_extractor.dart';
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

const _iclassesReply = '''```json
[
  {
    "classDefId": "",
    "courseName": "高等数学",
    "classTimeLoc": [
      {"teacher":"张教授","location":"逸夫楼201","classTimeLocId":"",
       "weekDay":0,"dayPart":1,"weekNums":[1,3,5,7,9],
       "classTimeDailyIdxList":[1,2]},
      {"teacher":"李老师","location":"理工楼110","classTimeLocId":"",
       "weekDay":3,"dayPart":1,"weekNums":[2,4,6,8,12,13,14],
       "classTimeDailyIdxList":[3,4]}
    ]
  }
]
```''';

void main() {
  group('EduAiExtractor — IClassesItem[]', () {
    test('expands every classTimeLoc into a row', () async {
      final extractor = EduAiExtractor(
        client: _FakeLlmClient(_iclassesReply),
        config: const LlmConfig(),
      );
      final courses = await extractor.extract('压缩后的课表 HTML');

      expect(courses, hasLength(2));

      final sunday = courses[0];
      expect(sunday.name, '高等数学');
      expect(sunday.weekday, 7);
      expect(sunday.periodStart, 1);
      expect(sunday.periodEnd, 2);
      expect(sunday.weekRuleText, '1-9单');
      expect(sunday.teacher, '张教授');
      expect(sunday.location, '逸夫楼201');
      expect(sunday.line, 1);

      final wednesday = courses[1];
      expect(wednesday.name, '高等数学');
      expect(wednesday.weekday, 3);
      expect(wednesday.periodStart, 3);
      expect(wednesday.periodEnd, 4);
      expect(wednesday.weekRuleText, '2-8双,12-14');
      expect(wednesday.teacher, '李老师');
      expect(wednesday.location, '理工楼110');
      expect(wednesday.line, 2);

      expect(parseWeekRuleText(sunday.weekRuleText!)!.weeks(16), [
        1,
        3,
        5,
        7,
        9,
      ]);
      expect(parseWeekRuleText(wednesday.weekRuleText!)!.weeks(16), [
        2,
        4,
        6,
        8,
        12,
        13,
        14,
      ]);
    });

    test('accepts a mixed answer of IClassesItem and flat entries', () async {
      const reply = '''```json
[
  {"courseName":"线性代数","classTimeLoc":[
    {"teacher":"王五","location":"文成楼125","classTimeLocId":"",
     "weekDay":2,"dayPart":1,"weekNums":[1,2,3,4],
     "classTimeDailyIdxList":[5,6]}]},
  {"name":"大学物理","weekday":4,"periodStart":7,"periodEnd":8,
   "teacher":"赵六","location":"理科楼301","weeks":"1-16"}
]
```''';
      final extractor = EduAiExtractor(
        client: _FakeLlmClient(reply),
        config: const LlmConfig(),
      );
      final courses = await extractor.extract('课表');

      expect(courses, hasLength(2));
      expect(courses[0].name, '线性代数');
      expect(courses[0].weekday, 2);
      expect(courses[0].periodStart, 5);
      expect(courses[0].periodEnd, 6);
      expect(courses[0].weekRuleText, '1-4');
      expect(courses[0].line, 1);

      expect(courses[1].name, '大学物理');
      expect(courses[1].weekday, 4);
      expect(courses[1].periodStart, 7);
      expect(courses[1].periodEnd, 8);
      expect(courses[1].weekRuleText, '1-16');
      expect(courses[1].teacher, '赵六');
      expect(courses[1].location, '理科楼301');
      expect(courses[1].line, 2);
    });

    test('throws LlmException when every entry is unusable', () async {
      const reply = '''```json
[
  {"name":"坏行","weekday":9,"periodStart":1,"periodEnd":2,"weeks":"1-16"},
  {"foo":"bar"},
  {"courseName":"","classTimeLoc":[]}
]
```''';
      final client = _FakeLlmClient(reply);
      final extractor = EduAiExtractor(
        client: client,
        config: const LlmConfig(),
      );

      expect(
        () => extractor.extract('课表'),
        throwsA(isA<LlmException>()),
      );
      expect(client.calls, 1);
    });

    test('throws LlmException for an empty answer array', () async {
      final extractor = EduAiExtractor(
        client: _FakeLlmClient('[]'),
        config: const LlmConfig(),
      );

      expect(
        () => extractor.extract('课表'),
        throwsA(isA<LlmException>()),
      );
    });

    test('throws LlmException for an empty request or empty reply', () async {
      final unanswered = _FakeLlmClient(null);
      final extractor = EduAiExtractor(
        client: unanswered,
        config: const LlmConfig(),
      );

      expect(() => extractor.extract('  '), throwsA(isA<LlmException>()));
      expect(unanswered.calls, 0);

      final blank = _FakeLlmClient('   ');
      final blankExtractor = EduAiExtractor(
        client: blank,
        config: const LlmConfig(),
      );
      expect(
        () => blankExtractor.extract('content'),
        throwsA(isA<LlmException>()),
      );
    });

    test('sends the IClassesItem contract without upload fields', () async {
      final client = _FakeLlmClient('[]');
      final extractor = EduAiExtractor(
        client: client,
        config: const LlmConfig(),
      );
      try {
        await extractor.extract('课表');
      } on LlmException {
        // The empty answer is expected; only the prompt matters here.
      }

      final system = client.lastMessages!.first['content'] as String;
      expect(client.lastMessages!.first['role'], 'system');
      expect(system, contains('IClassesItem'));
      expect(system, contains('weekNums'));
      expect(system, contains('classTimeDailyIdxList'));
      expect(system, contains('weekDay'));
      expect(system, contains('dayPart'));
      expect(system, contains('JSON'));
      expect(system, isNot(contains('```')));

      // Parser_GPT upload-only fields must never be part of the prompt.
      for (final field in const [
        'fullData',
        'tableImage',
        'importType',
        'pageUrl',
        'schoolName',
        'request',
      ]) {
        expect(system, isNot(contains(field)), reason: field);
      }
    });
  });
}
