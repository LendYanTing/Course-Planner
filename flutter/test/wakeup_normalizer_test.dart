import 'dart:convert';

import 'package:course_planner/core/util/week_text.dart';
import 'package:course_planner/domain/edu_import/edu_html_parser.dart';
import 'package:course_planner/domain/edu_import/wakeup_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

const _iclassesJson = '''
[
  {
    "courseName": "高等数学",
    "classTimeLoc": [
      {"teacher": "张老师", "location": "A101", "weekDay": 1,
       "weekNums": [1,2,3,4,5,6,7,8], "classTimeDailyIdxList": [1,2]},
      {"teacher": "张老师", "location": "A101", "weekDay": 0,
       "weekNums": [1,3,5,7,9], "classTimeDailyIdxList": [3,4]}
    ]
  },
  {
    "courseName": "大学英语",
    "classTimeLoc": [
      {"teacher": "李老师", "location": "B202", "weekDay": 7,
       "weekNums": [], "classTimeDailyIdxList": []}
    ]
  }
]
''';

const _jinzhiJson = '''
{"datas": {"getMyScheduleDetail": {"arrangedList": [
  {"courseCode": "CS1", "courseName": "数据结构", "dayOfWeek": 2,
   "beginSection": 1, "endSection": 2, "placeName": "A101;A102",
   "weeksAndTeachers": "1-8周/张教授;9-16周/李老师"},
  {"courseCode": "CS2", "courseName": "操作系统", "dayOfWeek": 7,
   "beginSection": 3, "endSection": 4, "placeName": "B201",
   "ZCBH": "1010100000000000", "JSXM": "王老师"}
]}}}
''';

const _jinzhiLegacyJson = '''
{"rows": [
  {"KCMC": "线性代数", "XQ": "3", "KSJC": 5, "JSJC": 6,
   "ZCBH": "1110000000000000", "JSXM": "赵六", "JASMC": "C301"}
]}
''';

const _shuweiJson = '''
{"studentTableVms": [{"activities": [
  {"courseName": "计算机网络", "weekday": 4, "startUnit": 3, "endUnit": 4,
   "weekIndexes": [1,2,3,4,6,8], "teachers": [{"nameZh": "孙老师"}],
   "room": "D401"},
  {"course": {"nameZh": "体育"}, "weekday": 5, "startUnit": 7, "endUnit": 8,
   "weeksStr": "1-16周", "teachers": ["周老师", "吴老师"], "campus": "东区"}
]}]}
''';

const _qiangzhiVueJson = '''
[{
  "xsjc": "0102",
  "xq1": [{"kcname": "*高等数学", "lsname": "张老师", "js": "A101",
           "zc": "1-16周"}],
  "xq2": "<div>大学英语</div><br>李老师<br>B202<br>1-8周(单)第1-2节"
},{
  "jcsj": "0304",
  "xq3": [{"ktname": "线性代数", "lsname": "王老师", "js": "C301",
           "zc": "1-16(周)[03-04节]"}]
}]
''';

const _chaoxingJson = '''
{"sdpkkbList": [
  {"kcmc": "<a href='#'>大学物理</a>", "xingqi": 2, "zcstr": "1,2,3,4",
   "djc": "第3-4节", "tmc": "<span>钱老师</span>", "croommc": "<span>E101</span>"},
  {"kcmc": "", "jxbmc": "形势与政策", "xingqi": 6, "zcstr": "5,7,10",
   "djc": "1-2", "tmc": "郑老师", "croommc": "F102"}
]}
''';

const _qiangzhiHtml = '''
<table id="kbtable">
<tr><th>节次</th><th>星期一</th><th>星期二</th><th>星期三</th>
<th>星期四</th><th>星期五</th><th>星期六</th><th>星期日</th></tr>
<tr><td>第1-2节</td>
<td class="kbcontent">高等数学A<br><font title="教师">张老师</font><br>
<font title="教室">逸夫楼201</font><br>
<font title="周次(节次)">1-16(周)[01-02节]</font></td>
<td></td><td></td><td></td><td></td><td></td><td></td></tr>
<tr><td>第3-4节</td><td></td>
<td class="kbcontent">线性代数<br><font title="教师">李老师</font><br>
<font title="教室">理工楼110</font><br>
<font title="周次(节次)">1-8(周)[03-04节]</font>
-----大学物理<br><font title="教师">王五</font><br>
<font title="教学楼">文成楼</font><font title="教室">125</font><br>
<font title="周次(节次)">9-16(周)[03-04节]</font></td>
<td></td><td></td><td></td><td></td><td></td></tr>
</table>
''';

void main() {
  group('compressWeekNumsToText', () {
    test('compresses runs, parity runs and singles', () {
      expect(WakeupFormatNormalizer.compressWeekNumsToText([1, 2, 3, 4, 5, 6, 7, 8]), '1-8');
      expect(WakeupFormatNormalizer.compressWeekNumsToText([1, 3, 5, 7, 9]), '1-9单');
      expect(WakeupFormatNormalizer.compressWeekNumsToText([2, 4, 6, 8, 12, 13, 14]), '2-8双,12-14');
    });

    test('deduplicates, ignores zero and keeps two-week parity runs apart', () {
      expect(WakeupFormatNormalizer.compressWeekNumsToText([0, 4, 4, 5]), '4-5');
      expect(WakeupFormatNormalizer.compressWeekNumsToText([1, 3]), '1,3');
      expect(WakeupFormatNormalizer.compressWeekNumsToText(const []), '');
    });

    test('output is always accepted by parseWeekRuleText', () {
      for (final weeks in [
        [1, 2, 3, 4],
        [1, 3, 5, 7],
        [2, 4, 6, 8, 12, 13, 14],
      ]) {
        expect(parseWeekRuleText(
          WakeupFormatNormalizer.compressWeekNumsToText(weeks),
        ), isNotNull);
      }
    });
  });

  group('weekNumsFromZcbh', () {
    test('maps a 01 bitmap to 1-based weeks', () {
      expect(
        WakeupFormatNormalizer.weekNumsFromZcbh('1010100000000000'),
        [1, 3, 5],
      );
      expect(WakeupFormatNormalizer.weekNumsFromZcbh(''), isEmpty);
    });
  });

  group('fromIClassesItems', () {
    test('converts weekDay 0 to Sunday and splits classTimeLoc rows', () {
      final courses = WakeupFormatNormalizer.fromIClassesItems(
        jsonDecode(_iclassesJson),
      );

      expect(courses, hasLength(3));
      expect(courses[0].line, 1);
      expect(courses[0].name, '高等数学');
      expect(courses[0].weekday, 1);
      expect(courses[0].periodStart, 1);
      expect(courses[0].periodEnd, 2);
      expect(courses[0].weekRuleText, '1-8');

      expect(courses[1].weekday, 7);
      expect(courses[1].periodStart, 3);
      expect(courses[1].periodEnd, 4);
      expect(courses[1].weekRuleText, '1-9单');

      expect(courses[2].name, '大学英语');
      expect(courses[2].weekday, 7);
      expect(courses[2].weekRuleText, isNull);
    });

    test('falls back to the supplied period text', () {
      final courses = WakeupFormatNormalizer.fromIClassesItems(
        jsonDecode(_iclassesJson),
        fallbackPeriods: ['第5-6节'],
      );

      expect(courses[2].periodStart, 5);
      expect(courses[2].periodEnd, 6);
    });

    test('accepts a map wrapping the list', () {
      final courses = WakeupFormatNormalizer.fromIClassesItems(
        jsonDecode('{"classes": $_iclassesJson}'),
      );
      expect(courses, hasLength(3));
    });

    test('bad input yields no courses and never throws', () {
      expect(WakeupFormatNormalizer.fromIClassesItems(null), isEmpty);
      expect(WakeupFormatNormalizer.fromIClassesItems('oops'), isEmpty);
      expect(
        WakeupFormatNormalizer.fromIClassesItems([
          {'courseName': '', 'classTimeLoc': []},
          {'classTimeLoc': []},
          42,
        ]),
        isEmpty,
      );
    });
  });

  group('fromJinZhi', () {
    test('splits weeksAndTeachers and maps fields', () {
      final courses = WakeupFormatNormalizer.fromJinZhi(
        jsonDecode(_jinzhiJson),
      );

      expect(courses, hasLength(3));
      expect(courses[0].name, '数据结构');
      expect(courses[0].weekday, 2);
      expect(courses[0].periodStart, 1);
      expect(courses[0].periodEnd, 2);
      expect(courses[0].teacher, '张教授');
      expect(courses[0].location, 'A101');
      expect(courses[0].weekRuleText, '1-8');

      expect(courses[1].teacher, '李老师');
      expect(courses[1].location, 'A102');
      expect(courses[1].weekRuleText, '9-16');

      expect(courses[2].name, '操作系统');
      expect(courses[2].weekday, 7);
      expect(courses[2].teacher, '王老师');
      expect(courses[2].location, 'B201');
      expect(courses[2].weekRuleText, '1-5单');
    });

    test('reads the legacy KCMC/ZCBH/KSJC shape', () {
      final courses = WakeupFormatNormalizer.fromJinZhi(
        jsonDecode(_jinzhiLegacyJson),
      );

      expect(courses, hasLength(1));
      expect(courses.single.name, '线性代数');
      expect(courses.single.weekday, 3);
      expect(courses.single.periodStart, 5);
      expect(courses.single.periodEnd, 6);
      expect(courses.single.teacher, '赵六');
      expect(courses.single.location, 'C301');
      expect(courses.single.weekRuleText, '1-3');
    });
  });

  group('fromShuWei', () {
    test('reads activities, nested course names and teacher lists', () {
      final courses = WakeupFormatNormalizer.fromShuWei(
        jsonDecode(_shuweiJson),
      );

      expect(courses, hasLength(2));
      expect(courses[0].name, '计算机网络');
      expect(courses[0].weekday, 4);
      expect(courses[0].periodStart, 3);
      expect(courses[0].periodEnd, 4);
      expect(courses[0].teacher, '孙老师');
      expect(courses[0].location, 'D401');
      expect(courses[0].weekRuleText, '1-4,6,8');

      expect(courses[1].name, '体育');
      expect(courses[1].weekday, 5);
      expect(courses[1].teacher, '周老师,吴老师');
      expect(courses[1].location, '东区');
      expect(courses[1].weekRuleText, '1-16');
    });

    test('reads a bare lessons list', () {
      final courses = WakeupFormatNormalizer.fromShuWei(jsonDecode('''
[{"courseName": "离散数学", "weekday": 1, "startUnit": 1, "endUnit": 2,
  "weekIndexes": [1,2,3], "teacherNames": "钱老师", "room": "E201"}]
'''));

      expect(courses, hasLength(1));
      expect(courses.single.weekRuleText, '1-3');
      expect(courses.single.teacher, '钱老师');
    });
  });

  group('fromQiangzhiVue', () {
    test('reads xq1..xq7 maps and HTML cells with zc/jcsj periods', () {
      final courses = WakeupFormatNormalizer.fromQiangzhiVue(
        jsonDecode(_qiangzhiVueJson),
      );

      expect(courses, hasLength(3));
      expect(courses[0].name, '高等数学');
      expect(courses[0].weekday, 1);
      expect(courses[0].periodStart, 1);
      expect(courses[0].periodEnd, 2);
      expect(courses[0].teacher, '张老师');
      expect(courses[0].location, 'A101');
      expect(courses[0].weekRuleText, '1-16');

      expect(courses[1].name, '大学英语');
      expect(courses[1].weekday, 2);
      expect(courses[1].teacher, '李老师');
      expect(courses[1].location, 'B202');
      expect(courses[1].weekRuleText, '1-7单');

      expect(courses[2].name, '线性代数');
      expect(courses[2].weekday, 3);
      expect(courses[2].periodStart, 3);
      expect(courses[2].periodEnd, 4);
      expect(courses[2].weekRuleText, '1-16');
    });
  });

  group('fromChaoxing', () {
    test('strips HTML and reads zcstr/djc', () {
      final courses = WakeupFormatNormalizer.fromChaoxing(
        jsonDecode(_chaoxingJson),
      );

      expect(courses, hasLength(2));
      expect(courses[0].name, '大学物理');
      expect(courses[0].weekday, 2);
      expect(courses[0].periodStart, 3);
      expect(courses[0].periodEnd, 4);
      expect(courses[0].teacher, '钱老师');
      expect(courses[0].location, 'E101');
      expect(courses[0].weekRuleText, '1-4');

      expect(courses[1].name, '形势与政策');
      expect(courses[1].weekday, 6);
      expect(courses[1].periodStart, 1);
      expect(courses[1].periodEnd, 2);
      expect(courses[1].weekRuleText, '5,7,10');
    });
  });

  group('fromAnyJson', () {
    test('detects wrapped vendor lists and reports the source', () {
      final iclasses = WakeupFormatNormalizer.fromAnyJsonWithSource(
        jsonDecode('{"data": $_iclassesJson}'),
      );
      expect(iclasses.source, 'iclasses-json');
      expect(iclasses.courses, hasLength(3));

      final jinzhi = WakeupFormatNormalizer.fromAnyJsonWithSource(
        jsonDecode(_jinzhiLegacyJson),
      );
      expect(jinzhi.source, 'jinzhi-json');
      expect(jinzhi.courses, hasLength(1));

      final chaoxing = WakeupFormatNormalizer.fromAnyJsonWithSource(
        jsonDecode('{"data": [{"kcmc": "Z", "xingqi": 2, '
            '"zcstr": "1,2", "djc": "1-2"}]}'),
      );
      expect(chaoxing.source, 'chaoxing-json');
      expect(chaoxing.courses, hasLength(1));
    });

    test('returns [] for unknown or non-JSON shapes', () {
      expect(WakeupFormatNormalizer.fromAnyJson(jsonDecode('{"foo": 1}')), isEmpty);
      expect(WakeupFormatNormalizer.fromAnyJson(null), isEmpty);
      expect(WakeupFormatNormalizer.fromAnyJson('text'), isEmpty);
      expect(
        WakeupFormatNormalizer.fromAnyJson(jsonDecode(
          '{"kbList": [{"kcmc": "高等数学", "xqj": 1, "jcs": "1-2", "zcd": "1-16"}]}',
        )),
        isEmpty,
      );
    });
  });

  group('EduHtmlParser — Qiangzhi <font title> tables', () {
    test('parses font titles and ----- separated courses', () {
      final result = EduHtmlParser.parse(_qiangzhiHtml);

      expect(result.source, 'table');
      expect(result.courses, hasLength(3));

      final math = result.courses[0];
      expect(math.name, '高等数学A');
      expect(math.weekday, 1);
      expect(math.periodStart, 1);
      expect(math.periodEnd, 2);
      expect(math.teacher, '张老师');
      expect(math.location, '逸夫楼201');
      expect(math.weekRuleText, '1-16');

      final linear = result.courses[1];
      expect(linear.name, '线性代数');
      expect(linear.weekday, 2);
      expect(linear.periodStart, 3);
      expect(linear.periodEnd, 4);
      expect(linear.teacher, '李老师');
      expect(linear.location, '理工楼110');
      expect(linear.weekRuleText, '1-8');

      final physics = result.courses[2];
      expect(physics.name, '大学物理');
      expect(physics.weekday, 2);
      expect(physics.periodStart, 3);
      expect(physics.periodEnd, 4);
      expect(physics.teacher, '王五');
      expect(physics.location, '文成楼125');
      expect(physics.weekRuleText, '9-16');
    });

    test('parses vendor JSON embedded in an HTML script block', () {
      final html =
          '<html><body><script>var schedule = $_jinzhiLegacyJson;</script>'
          '</body></html>';
      final result = EduHtmlParser.parse(html);

      expect(result.source, 'jinzhi-json');
      expect(result.courses, hasLength(1));
      expect(result.courses.single.name, '线性代数');
      expect(result.courses.single.weekRuleText, '1-3');
    });

    test('keeps the existing header/table behaviour intact', () {
      const html = '''
<table>
<tr><th>节次</th><th>周一</th><th>周二</th></tr>
<tr><td>第1-2节</td>
<td>高等数学<br/>1-16周<br/>张教授@逸夫楼201</td><td></td></tr>
</table>''';
      final result = EduHtmlParser.parse(html);

      expect(result.source, 'table');
      expect(result.courses, hasLength(1));
      expect(result.courses.single.name, '高等数学');
      expect(result.courses.single.teacher, '张教授');
      expect(result.courses.single.location, '逸夫楼201');
    });
  });
}
