import 'dart:convert';

import 'package:course_planner/core/edu/edu_webview_bridge.dart';
import 'package:course_planner/domain/edu_import/webview_extractor_script.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('webviewExtractorScript', () {
    test('is a self-contained IIFE with every extraction stage', () {
      expect(webviewExtractorScript, isNotEmpty);
      expect(webviewExtractorScript, startsWith('(function () {'));
      expect(webviewExtractorScript.trimRight(), endsWith('})();'));
      expect(webviewExtractorScript, contains('CoursePlannerBridge'));
      expect(webviewExtractorScript, contains('findTables'));
      expect(webviewExtractorScript, contains('getWeight'));
      expect(webviewExtractorScript, contains('compressHtml'));
      expect(webviewExtractorScript, contains('contentDocument'));
      expect(webviewExtractorScript, contains('kbcx/xskbcx_cxXsgrkb'));
      expect(webviewExtractorScript, contains('getMyScheduleDetail'));
      expect(webviewExtractorScript, contains('print-data'));
      expect(webviewExtractorScript, contains('__CP_EDU_HINT__'));
    });

    test('carries no analytics or upload endpoint', () {
      const forbidden = <String>[
        r'$track',
        'reportTableSnapshot',
        'reportAllWeeksRawData',
        '/wakeup/log/collect',
        '/wakeup/schedule/aiparse/submit',
        'api-bbb',
        'suanshubang',
      ];
      for (final needle in forbidden) {
        expect(
          webviewExtractorScript,
          isNot(contains(needle)),
          reason: 'the offline extractor must not contain "$needle"',
        );
      }
    });

    test('injects the school hint without breaking the IIFE', () {
      final script = buildWebviewExtractorScript(
        parserType: 'zf',
        schoolName: '安徽大学',
      );

      expect(script, contains('window.__CP_EDU_HINT__ = '));
      expect(script, contains('"parserType":"zf"'));
      expect(script, contains('"schoolName":"安徽大学"'));
      expect(script, contains('(function () {'));
      expect(script, contains('CoursePlannerBridge'));
      expect(script, endsWith(webviewExtractorScript));
    });

    test('JSON-escapes quotes and backslashes in the hint', () {
      final script = buildWebviewExtractorScript(schoolName: 'A"B\\C');

      expect(script, contains(r'"schoolName":"A\"B\\C"'));
      expect(script, contains('(function () {'));
    });

    test('an empty hint still produces a valid script', () {
      final script = buildWebviewExtractorScript();

      expect(script, contains('"parserType":""'));
      expect(script, contains('"schoolName":""'));
      expect(script, endsWith(webviewExtractorScript));
    });
  });

  group('EduWebViewBridge', () {
    const channel = MethodChannel(EduWebViewBridge.channelName);

    void mockChannel(Future<Object?> Function(MethodCall call) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
    }

    Map<String, Object?> payload() => <String, Object?>{
      'status': 'ok',
      'pageUrl': 'https://jw.example.edu.cn/kbcx/xskbcx_cxXskbcxIndex.html',
      'schoolName': '安徽大学',
      'vendor': 'zf',
      'dataJson': '{"kbList":[{"kcmc":"高等数学"}]}',
      'extractedData': '',
      'rawHtml':
          '<html><body><table><tr><td>课表</td></tr></table></body></html>',
      'bestTableHtml': '<table class="kb"><tr><td>高等数学</td></tr></table>',
    };

    test('parses the JSON string returned by the native activity', () async {
      mockChannel((call) async {
        expect(call.method, EduWebViewBridge.methodOpen);
        final args = call.arguments as Map<Object?, Object?>;
        expect(args['url'], 'https://jw.example.edu.cn');
        expect(args['schoolName'], '安徽大学');
        expect(args['parserType'], 'zf');
        expect(args['desktopMode'], isTrue);
        return jsonEncode(payload());
      });

      final result = await const EduWebViewBridge().open(
        url: ' https://jw.example.edu.cn ',
        schoolName: '安徽大学',
        parserType: 'zf',
        desktopMode: true,
      );

      expect(result, isNotNull);
      expect(result!.pageUrl, contains('xskbcx_cxXskbcxIndex'));
      expect(result.schoolName, '安徽大学');
      expect(result.vendorType, 'zf');
      expect(result.extractedData, contains('kbList'));
      expect(result.bestTableHtml, contains('高等数学'));
      expect(result.rawHtml, contains('<table'));
      expect(result.hasData, isTrue);
    });

    test('also accepts an already decoded map', () async {
      mockChannel((call) async => payload());

      final result = await const EduWebViewBridge().open(
        url: 'https://jw.example.edu.cn',
      );

      expect(result, isNotNull);
      expect(result!.vendorType, 'zf');
      expect(result.schoolName, '安徽大学');
      expect(result.extractedData, contains('高等数学'));
    });

    test('falls back to extractedData when dataJson is empty', () async {
      mockChannel(
        (call) async => <String, Object?>{
          'status': 'ok',
          'vendor': 'shuwei',
          'extractedData': '{"studentTableVms":[]}',
        },
      );

      final result = await const EduWebViewBridge().open(
        url: 'https://jw.example.edu.cn',
      );

      expect(result, isNotNull);
      expect(result!.vendorType, 'shuwei');
      expect(result.extractedData, contains('studentTableVms'));
      expect(result.hasData, isTrue);
    });

    test('returns null when the user closed the browser', () async {
      mockChannel((call) async => null);

      final result = await const EduWebViewBridge().open(
        url: 'https://jw.example.edu.cn',
      );

      expect(result, isNull);
    });

    test('returns null when the page script reported an error', () async {
      mockChannel(
        (call) async => jsonEncode(<String, Object?>{
          'status': 'error',
          'message': 'boom',
          'vendor': 'unknown',
        }),
      );

      final result = await const EduWebViewBridge().open(
        url: 'https://jw.example.edu.cn',
      );

      expect(result, isNull);
    });

    test('returns null on a platform error', () async {
      mockChannel((call) async => throw PlatformException(code: 'open_failed'));

      final result = await const EduWebViewBridge().open(
        url: 'https://jw.example.edu.cn',
      );

      expect(result, isNull);
    });

    test('returns null when the channel is missing', () async {
      mockChannel((call) async => throw MissingPluginException());

      final result = await const EduWebViewBridge().open(
        url: 'https://jw.example.edu.cn',
      );

      expect(result, isNull);
    });

    test('returns null for a blank url without touching the channel', () async {
      var called = false;
      mockChannel((call) async {
        called = true;
        return payload();
      });

      expect(await const EduWebViewBridge().open(url: '   '), isNull);
      expect(called, isFalse);
    });

    test('returns null on non-Android platforms', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      var called = false;
      mockChannel((call) async {
        called = true;
        return payload();
      });

      expect(
        await const EduWebViewBridge().open(url: 'https://jw.example.edu.cn'),
        isNull,
      );
      expect(called, isFalse);
    });

    test('the explicit platform seam wins over the host platform', () async {
      var called = false;
      mockChannel((call) async {
        called = true;
        return payload();
      });

      expect(
        await const EduWebViewBridge(
          platform: TargetPlatform.linux,
        ).open(url: 'https://jw.example.edu.cn'),
        isNull,
      );
      expect(called, isFalse);
    });
  });

  group('EduWebViewResult.fromJson', () {
    test('keeps object payloads as JSON text', () {
      final result = EduWebViewResult.fromJson(<String, dynamic>{
        'pageUrl': 'https://jw.example.edu.cn',
        'vendor': 'qz-vue',
        'dataJson': <String, Object?>{'xq1': <Object?>[]},
        'bestTableHtml': null,
      });

      expect(result.vendorType, 'qz-vue');
      expect(result.extractedData, contains('xq1'));
      expect(result.bestTableHtml, isEmpty);
      expect(result.rawHtml, isEmpty);
      expect(result.hasData, isTrue);
    });

    test('defaults an unknown vendor to "unknown"', () {
      final result = EduWebViewResult.fromJson(const <String, dynamic>{});

      expect(result.vendorType, 'unknown');
      expect(result.hasData, isFalse);
    });
  });
}
