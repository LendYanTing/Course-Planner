import 'package:course_planner/domain/edu_import/school_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

SchoolEntry _entry({
  String name = '测试大学',
  String loginUrl = '',
  String type = 'ziyan',
  String mode = '',
  String strategy = 'local-parser',
  String parser = 'SomeParser',
}) {
  return SchoolEntry(
    name: name,
    loginUrl: loginUrl,
    type: type,
    mode: mode,
    strategy: strategy,
    parser: parser,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SchoolCatalog catalog;

  setUpAll(() async {
    catalog = await SchoolCatalog.load();
  });

  group('SchoolCatalog manifest', () {
    test('loads all 3570 schools from the bundled asset', () {
      expect(catalog.all.length, 3570);
    });

    test('known schools keep their name and type', () {
      final ahu = catalog.byName('安徽大学');
      expect(ahu, isNotNull);
      expect(ahu!.name, '安徽大学');
      expect(ahu.type, isNotEmpty);

      final thu = catalog.byName('清华大学');
      expect(thu, isNotNull);
      expect(thu!.name, '清华大学');
      expect(thu.type, isNotEmpty);
    });
  });

  group('SchoolCatalog search', () {
    test('matches school names containing the query', () {
      final results = catalog.search('理工');
      expect(results.length, greaterThan(1));
      expect(results.every((entry) => entry.name.contains('理工')), isTrue);
    });

    test('prefix matches rank first', () {
      final results = catalog.search('安徽');
      expect(results, isNotEmpty);
      expect(results.first.name.startsWith('安徽'), isTrue);
    });

    test('empty query returns the first entries', () {
      final results = catalog.search('  ', limit: 5);
      expect(results.length, 5);
      expect(results, catalog.all.take(5));
    });

    test('limit and deduplication are respected', () {
      final results = catalog.search('大学', limit: 10);
      expect(results.length, 10);
      final keys = results
          .map((entry) => '${entry.name}\u0000${entry.normalizedUrl}')
          .toSet();
      expect(keys.length, results.length);
    });
  });

  group('SchoolCatalog featured vendors', () {
    test('exposes eight vendor templates outside all', () {
      expect(catalog.featured.length, 8);
      final names = catalog.featured.map((entry) => entry.name).toList();
      expect(
        names,
        containsAll(<String>[
          '正方教务',
          '强智教务',
          '金智教务',
          '树维/EAMS 教务',
          '青果教务',
          '超星/学习通',
          '乘方教务',
          '其他/通用教务网页',
        ]),
      );
      expect(catalog.featured.every((entry) => entry.loginUrl.isEmpty), isTrue);
      expect(
        catalog.all.any(
          (entry) => catalog.featured.any((vendor) => identical(entry, vendor)),
        ),
        isFalse,
      );
      expect(catalog.all.every((entry) => entry.strategy != 'template'), isTrue);
    });

    test('templates map to the expected vendor labels', () {
      expect(catalog.featured[0].vendorLabel, '正方教务');
      expect(catalog.featured[1].vendorLabel, '强智教务');
      expect(catalog.featured[2].vendorLabel, '金智教务');
      expect(catalog.featured[3].vendorLabel, '树维教务');
      expect(catalog.featured[4].vendorLabel, '青果教务');
      expect(catalog.featured[5].vendorLabel, '超星学习通');
      expect(catalog.featured[6].vendorLabel, '乘方教务');
      expect(catalog.featured[7].vendorLabel, '教务系统');
    });
  });

  group('SchoolEntry URL handling', () {
    test('adds a scheme to host-only URLs', () {
      expect(
        _entry(loginUrl: 'jw.ahu.edu.cn').normalizedUrl,
        'https://jw.ahu.edu.cn',
      );
      expect(
        _entry(loginUrl: '10.100.101.6').normalizedUrl,
        'https://10.100.101.6',
      );
      expect(
        _entry(loginUrl: 'jw.ahu.edu.cn').hasUsableUrl,
        isTrue,
      );
    });

    test('keeps existing schemes, strips quotes and trims', () {
      expect(_entry(loginUrl: '  http://x  ').normalizedUrl, 'http://x');
      expect(
        _entry(loginUrl: '"https://jw.ahu.edu.cn"').normalizedUrl,
        'https://jw.ahu.edu.cn',
      );
    });

    test('keeps empty values empty and free text untouched', () {
      expect(_entry(loginUrl: '').normalizedUrl, '');
      expect(_entry(loginUrl: '   ').normalizedUrl, '');
      expect(_entry(loginUrl: '登录').normalizedUrl, '登录');
      expect(_entry(loginUrl: '登录').hasUsableUrl, isFalse);
      expect(_entry(loginUrl: '').hasUsableUrl, isFalse);
    });
  });

  group('SchoolEntry labels', () {
    test('byName reports misses without throwing', () {
      expect(catalog.byName('不存在的学校名字'), isNull);
      expect(catalog.byName('   '), isNull);
    });

    test('isAiFallback follows the strategy and GPT parser', () {
      expect(_entry(strategy: 'ai-fallback').isAiFallback, isTrue);
      expect(
        _entry(strategy: 'local-parser', parser: 'Parser_GPT').isAiFallback,
        isTrue,
      );
      expect(_entry(strategy: 'local-parser').isAiFallback, isFalse);
      expect(_entry(strategy: 'ai-fallback').vendorLabel, 'AI 智能解析');
    });

    test('vendorLabel maps every supported family', () {
      const expected = <String, String>{
        'zf': '正方教务',
        'qz': '强智教务',
        'jinzhi': '金智教务',
        'shuwei': '树维教务',
        'kingo': '青果教务',
        'chaoxing': '超星学习通',
        'chengfang': '乘方教务',
      };
      for (final entry in expected.entries) {
        expect(_entry(type: entry.key).vendorLabel, entry.value);
      }
      expect(_entry(type: 'ziyan').vendorLabel, '教务系统');
    });
  });
}
