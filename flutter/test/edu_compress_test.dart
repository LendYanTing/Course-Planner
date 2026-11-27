import 'package:course_planner/domain/edu_import/edu_html_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const _navTable = '''
<table id="nav" class="nav" width="100%">
<tr><td><a href="/" onclick="go()" data-nav="1">导航</a></td><td>首页</td></tr>
<tr><td>教务</td><td>登录</td></tr>
</table>
''';

const _layoutTable = '''
<table class="layout" width="100%">
<tr><td>栏目</td><td>版权</td></tr>
<tr><td>联系</td><td>关于</td></tr>
</table>
''';

const _timetable = '''
<table id="kb" class="kb" width="100%" align="center">
<tr><th>节次</th><th>星期一</th><th>星期二</th><th>星期三</th><th>星期四</th><th>星期五</th><th>星期六</th><th>星期日</th></tr>
<tr><td>第1节</td>
<td rowspan="2" colspan="2" onclick="pick()" data-cell="math" id="c1"><font title="教师">张教授</font><br/><span class="course">高等数学</span><br/>1-16周<br/><font title="教室">逸夫楼201</font></td>
<td>大学物理</td><td></td><td></td><td></td><td></td><td></td></tr>
<tr><td>第2节</td><td>线性代数</td><td></td><td></td><td></td><td></td><td></td><td></td></tr>
</table>
''';

const _page = '''
<html><head><title>教务系统</title>
<script>var leak = 1;</script>
<style>.kb { color: red; }</style>
</head><body>
$_navTable
$_layoutTable
$_timetable
</body></html>
''';

void main() {
  group('EduHtmlParser.compressHtmlForAi', () {
    test('keeps only the timetable table and its contract attributes', () {
      final result = EduHtmlParser.compressHtmlForAi(_page);

      expect(result, contains('星期一'));
      expect(result, contains('高等数学'));
      expect(result, contains('title="教师"'));
      expect(result, contains('rowspan="2"'));
      expect(result, contains('colspan="2"'));
      expect(result, contains('class="kb"'));

      expect(result, isNot(contains('导航')));
      expect(result, isNot(contains('栏目')));
      expect(result, isNot(contains('onclick')));
      expect(result, isNot(contains('id=')));
      expect(result, isNot(contains('data-')));
      expect(result, isNot(contains('width=')));
      expect(result, isNot(contains('align=')));
      expect(result, isNot(contains('<script')));
      expect(result, isNot(contains('color: red')));
      expect(result.trimLeft(), startsWith('<table'));
    });

    test('falls back to plain text when the page has no table', () {
      const page =
          '<html><body><div>高等数学 周一第1-2节 1-16周 逸夫楼201</div>'
          '</body></html>';
      final result = EduHtmlParser.compressHtmlForAi(page);

      expect(result, contains('高等数学'));
      expect(result, contains('逸夫楼201'));
      expect(result, isNot(contains('<table')));
    });

    test('falls back to plain text when every table is navigation/layout', () {
      const page = '<html><body>$_navTable$_layoutTable</body></html>';
      final result = EduHtmlParser.compressHtmlForAi(page);

      expect(result, isNot(contains('<table')));
      expect(result, contains('栏目'));
    });

    test('truncates to maxChars without splitting a tag', () {
      final result = EduHtmlParser.compressHtmlForAi(_page, maxChars: 50);

      expect(result.length, lessThanOrEqualTo(50));
      expect(result.trimLeft(), startsWith('<table'));
      expect(result.endsWith('>'), isTrue);
    });

    test('empty and broken input is total', () {
      expect(EduHtmlParser.compressHtmlForAi(''), '');
      expect(EduHtmlParser.compressHtmlForAi('   '), '');
      expect(EduHtmlParser.compressHtmlForAi('<table><tr><td>'), '');
      expect(
        () => EduHtmlParser.compressHtmlForAi('\u0000<<<%%%'),
        returnsNormally,
      );
    });
  });
}
