import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What the native education-system browser captured.
///
/// The payload fields are filled by the in-page extractor:
///  * [extractedData] — vendor JSON (`kbList`, `arrangedList`, `activities`,
///    Qiangzhi `el-table` rows, …) as a JSON string, empty when no endpoint
///    matched;
///  * [bestTableHtml] — the single highest-scoring timetable `<table>`,
///    compressed to `class` / `title` / `rowspan` / `colspan`, or the page's
///    plain text when the page uses `<div>`s;
///  * [rawHtml] — the concatenated HTML of the page and every same-origin
///    iframe, capped by the script;
///  * [vendorType] — `zf`, `qz-vue`, `shuwei`, `jinzhi`, `chaoxing` or
///    `unknown`.
class EduWebViewResult {
  const EduWebViewResult({
    required this.pageUrl,
    required this.schoolName,
    required this.vendorType,
    required this.extractedData,
    required this.bestTableHtml,
    required this.rawHtml,
  });

  /// URL of the page the user extracted from.
  final String pageUrl;

  /// School the user launched the browser for; empty for a custom URL.
  final String schoolName;

  /// Vendor fingerprint reported by the page script, never empty.
  final String vendorType;

  /// Vendor JSON payload as a string (empty when nothing matched).
  final String extractedData;

  /// Compressed best timetable HTML, or plain page text as a fallback.
  final String bestTableHtml;

  /// Concatenated HTML of the page and its same-origin frames.
  final String rawHtml;

  /// True when the capture carries something worth parsing.
  bool get hasData =>
      extractedData.trim().isNotEmpty ||
      bestTableHtml.trim().isNotEmpty ||
      rawHtml.trim().isNotEmpty;

  /// Reads the map produced by `EduWebViewActivity`'s bridge. Unknown or
  /// null values become empty strings; values that are not strings are
  /// JSON-encoded so a vendor payload passed as an object still survives.
  factory EduWebViewResult.fromJson(Map<String, dynamic> json) {
    String text(Object? value) {
      if (value == null) return '';
      if (value is String) return value;
      try {
        return jsonEncode(value);
      } on Object {
        return value.toString();
      }
    }

    final dataJson = text(json['dataJson']);
    final vendor = text(json['vendor']).trim();
    return EduWebViewResult(
      pageUrl: text(json['pageUrl']),
      schoolName: text(json['schoolName']),
      vendorType: vendor.isEmpty ? 'unknown' : vendor,
      extractedData: dataJson.isNotEmpty
          ? dataJson
          : text(json['extractedData']),
      bestTableHtml: text(json['bestTableHtml']),
      rawHtml: text(json['rawHtml']),
    );
  }
}

/// Opens the native education-system WebView and returns its capture.
///
/// Only Android implements the channel; every other platform (and any failure)
/// returns null so the settings page can fall back to paste / URL import.
class EduWebViewBridge {
  const EduWebViewBridge({MethodChannel? channel, TargetPlatform? platform})
    // Named parameters cannot be private, so the test seams are copied into
    // private fields instead of naming the fields after them.
    // ignore: prefer_initializing_formals
    : _channel = channel,
      // ignore: prefer_initializing_formals
      _platform = platform;

  /// Channel implemented by `MainActivity.kt`.
  static const channelName = 'course_planner/edu_webview';

  /// Method invoked on [channelName].
  static const methodOpen = 'openEduWebView';

  final MethodChannel? _channel;
  final TargetPlatform? _platform;

  /// Launches `EduWebViewActivity` and waits for the user to extract.
  ///
  /// Returns null when the platform is unsupported, the user closed the
  /// browser, the page script reported an error, or the channel failed.
  Future<EduWebViewResult?> open({
    required String url,
    String schoolName = '',
    String parserType = '',
    bool desktopMode = false,
  }) async {
    final target = url.trim();
    if (target.isEmpty) return null;
    if (kIsWeb) return null;
    if ((_platform ?? defaultTargetPlatform) != TargetPlatform.android) {
      return null;
    }

    final channel = _channel ?? const MethodChannel(channelName);
    try {
      final payload = await channel.invokeMethod<Object?>(methodOpen, {
        'url': target,
        'schoolName': schoolName,
        'parserType': parserType,
        'desktopMode': desktopMode,
      });
      return _decode(payload);
    } on MissingPluginException {
      debugPrint('EduWebViewBridge: channel is unavailable');
      return null;
    } on PlatformException catch (e) {
      debugPrint('EduWebViewBridge: open failed (${e.code})');
      return null;
    } on Object {
      debugPrint('EduWebViewBridge: open failed');
      return null;
    }
  }

  /// Accepts the two shapes the Kotlin side may hand over: the extractor's JSON
  /// string, or an already decoded map. Empty / error payloads become null.
  static EduWebViewResult? _decode(Object? payload) {
    if (payload == null) return null;
    Object? decoded = payload;
    if (payload is String) {
      final text = payload.trim();
      if (text.isEmpty) return null;
      try {
        decoded = jsonDecode(text);
      } on Object {
        // Not JSON: the native side sent something unexpected.
        return null;
      }
    }
    if (decoded is! Map) return null;

    final map = <String, dynamic>{};
    decoded.forEach((key, value) => map['$key'] = value);

    final status = map['status'];
    if (status is String && status.toLowerCase() == 'error') {
      debugPrint('EduWebViewBridge: page extraction reported an error');
      return null;
    }
    return EduWebViewResult.fromJson(map);
  }
}

final eduWebViewBridgeProvider = Provider<EduWebViewBridge>(
  (ref) => const EduWebViewBridge(),
);
