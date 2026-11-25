import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'voice_config.dart';

/// Where the button currently is in the listen → transcribe → done cycle.
/// [VoiceInputButton] only needs the coarse busy state; the enum is kept for
/// future callers (settings test page, real-time waveform, …).
enum VoiceStatus { idle, listening, transcribing, done, error }

/// Outcome of one recognition attempt. Exactly one of [text] / [error] is
/// expected to be non-empty; failures are returned rather than thrown so a
/// widget never has to wrap the call in a try/catch.
class VoiceResult {
  const VoiceResult({this.text, this.error});

  final String? text;
  final String? error;
}

/// Readable ASR failure. [message] is always Chinese and never contains the
/// API key, a request header or any audio content.
class VoiceException implements Exception {
  VoiceException(this.message, {this.status});

  final String message;
  final int? status;

  @override
  String toString() => 'VoiceException(${status ?? '-'}): $message';
}

/// Injected audio source: returns the bytes of one recording (m4a) or null
/// when no audio could be captured.
typedef VoiceAudioRecorder = Future<List<int>?> Function();

/// One speech-recognition backend. Both implementations time out and turn
/// every failure into a [VoiceResult] carrying a Chinese message.
abstract class VoiceRecognizer {
  /// True when the current platform/config can run this backend (the native
  /// channel answers, or the cloud endpoint is fully configured).
  Future<bool> get available;

  /// Records/listens and returns the recognised text ([VoiceResult.text]) or
  /// a user-facing error ([VoiceResult.error]).
  Future<VoiceResult> recognize({
    Duration maxDuration = const Duration(seconds: 30),
  });

  /// Stops an in-flight listen/recording. Safe to call when idle.
  Future<void> cancel();
}

/// System recognizer over the `course_planner/speech` method channel.
///
/// Protocol (implemented in `MainActivity.kt`):
/// * `listen` → `String?` recognised text, null when nothing was heard;
/// * `recordOnce` → `String?` absolute path of a temporary m4a (≤ 30 s);
/// * `cancel` → void;
/// * `isAvailable` → bool.
class SystemVoiceRecognizer implements VoiceRecognizer {
  SystemVoiceRecognizer({MethodChannel? channel, this.platformSupported})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'course_planner/speech';

  /// Extra headroom on top of the user's speaking budget: the system dialog
  /// owns the UI, so the channel only completes once it closes.
  static const _listenHeadroom = Duration(seconds: 15);

  static const _availabilityTimeout = Duration(seconds: 5);

  final MethodChannel _channel;

  /// Test seam: null means "ask the real platform".
  final bool? platformSupported;

  bool get _supported => platformSupported ?? (!kIsWeb && Platform.isAndroid);

  @override
  Future<bool> get available async {
    if (!_supported) return false;
    try {
      final value = await _channel
          .invokeMethod<bool>('isAvailable')
          .timeout(_availabilityTimeout);
      return value ?? false;
    } on Object {
      // MissingPluginException on a platform without the bridge, a wedged
      // engine, … — all mean "not available" rather than a crash.
      return false;
    }
  }

  @override
  Future<VoiceResult> recognize({
    Duration maxDuration = const Duration(seconds: 30),
  }) async {
    if (!_supported) {
      return const VoiceResult(error: '当前平台不支持系统语音识别，可在设置中配置云端语音 API');
    }
    try {
      final text = await _channel
          .invokeMethod<String>('listen')
          .timeout(maxDuration + _listenHeadroom);
      final trimmed = text?.trim() ?? '';
      if (trimmed.isEmpty) {
        return const VoiceResult(error: '没有听清，请再说一次');
      }
      return VoiceResult(text: trimmed);
    } on TimeoutException {
      // Leave the native dialog in a clean state for the next attempt.
      await cancel();
      return const VoiceResult(error: '语音识别超时，请重试');
    } on PlatformException catch (e) {
      return VoiceResult(error: _messageFor(e));
    } on MissingPluginException {
      return const VoiceResult(error: '当前平台不支持系统语音识别，可在设置中配置云端语音 API');
    } on Object {
      return const VoiceResult(error: '语音识别失败，请重试');
    }
  }

  @override
  Future<void> cancel() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('cancel');
    } on Object {
      // Nothing to stop, or no bridge: deliberately ignored.
    }
  }

  static String _messageFor(PlatformException e) {
    final message = e.message?.trim();
    if (message != null && message.isNotEmpty) return message;
    switch (e.code) {
      case 'permission_denied':
        return '未授予麦克风权限，无法录音';
      case 'unavailable':
        return '当前设备没有可用的语音识别服务';
      case 'busy':
        return '语音识别正在进行中，请稍候';
      default:
        return '语音识别失败，请重试';
    }
  }
}

/// OpenAI-compatible `POST {baseUrl}/audio/transcriptions` client.
///
/// The request is multipart (`file` = m4a, `model`) and carries only the ASR
/// key — never the app's authenticated transport. Audio usually comes from the
/// native `recordOnce` bridge; tests inject [recordAudio].
class CloudWhisperRecognizer implements VoiceRecognizer {
  CloudWhisperRecognizer({
    required this.config,
    VoiceAudioRecorder? recordAudio,
    Dio? dio,
  }) : _recordAudio = recordAudio ?? _recordOnceViaChannel,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: defaultTimeout,
               receiveTimeout: defaultTimeout,
               sendTimeout: defaultTimeout,
             ),
           );

  static const defaultTimeout = Duration(seconds: 30);

  /// Native recording may run the full user budget before the upload starts.
  static const _recordingHeadroom = Duration(seconds: 15);

  static const _filename = 'speech.m4a';

  final VoiceConfig config;
  final VoiceAudioRecorder _recordAudio;
  final Dio _dio;

  CancelToken _cancelToken = CancelToken();

  @override
  Future<bool> get available async => config.cloudConfigured;

  @override
  Future<VoiceResult> recognize({
    Duration maxDuration = const Duration(seconds: 30),
  }) async {
    if (!config.cloudConfigured) {
      return const VoiceResult(
        error: '云端语音识别尚未配置，请在设置中填写 Base URL、API Key 与模型',
      );
    }

    final endpoint = transcriptionEndpoint(config.baseUrl);
    final uri = Uri.tryParse(endpoint);
    if (uri == null ||
        uri.host.isEmpty ||
        !(uri.isScheme('http') || uri.isScheme('https'))) {
      return const VoiceResult(error: '云端语音服务的 Base URL 无效，请检查设置');
    }

    List<int>? audio;
    try {
      audio = await _recordAudio().timeout(maxDuration + _recordingHeadroom);
    } on TimeoutException {
      return const VoiceResult(error: '录音超时，请重试');
    } on Object {
      return const VoiceResult(error: '无法录音，请检查麦克风权限后重试');
    }
    final bytes = audio;
    if (bytes == null || bytes.isEmpty) {
      return const VoiceResult(error: '无法获取录音，请检查麦克风权限');
    }

    // A cancelled request must not poison the next attempt.
    if (_cancelToken.isCancelled) _cancelToken = CancelToken();
    final token = _cancelToken;

    try {
      final response = await _dio
          .post<dynamic>(
            endpoint,
            data: buildForm(bytes: bytes, model: config.model.trim()),
            options: Options(
              headers: <String, dynamic>{
                'Authorization': 'Bearer ${config.apiKey.trim()}',
                'Accept': 'application/json',
              },
            ),
            cancelToken: token,
          )
          .timeout(defaultTimeout);
      return _parse(response.data);
    } on DioException catch (e) {
      return VoiceResult(error: _fromDio(e));
    } on TimeoutException {
      return const VoiceResult(error: '云端语音服务响应超时（30 秒），请稍后重试');
    } on VoiceException catch (e) {
      return VoiceResult(error: e.message);
    } on Object {
      // Never let the raw exception (with request headers) escape.
      return const VoiceResult(error: '云端语音识别失败，请检查网络与配置后重试');
    }
  }

  @override
  Future<void> cancel() async {
    _cancelToken.cancel('cancelled');
    // Also stops an in-flight native recording, if any.
    try {
      if (!kIsWeb && Platform.isAndroid) {
        await const MethodChannel(
          SystemVoiceRecognizer.channelName,
        ).invokeMethod<void>('cancel');
      }
    } on Object {
      // Nothing to stop.
    }
  }

  /// `{baseUrl}/audio/transcriptions`, tolerating trailing slashes and a
  /// pasted full endpoint.
  static String transcriptionEndpoint(String baseUrl) {
    var url = baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.isEmpty) return '';
    if (url.endsWith('/audio/transcriptions')) return url;
    return '$url/audio/transcriptions';
  }

  /// Builds the multipart body. Separated out so tests can assert the field
  /// names without a network round-trip.
  @visibleForTesting
  static FormData buildForm({required List<int> bytes, required String model}) {
    return FormData.fromMap(<String, dynamic>{
      'file': MultipartFile.fromBytes(
        bytes,
        filename: _filename,
        contentType: DioMediaType('audio', 'mp4'),
      ),
      'model': model,
    });
  }

  /// Default recorder: the native bridge writes a temporary m4a, which is read
  /// into memory and deleted immediately.
  static Future<List<int>?> _recordOnceViaChannel() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      final path = await const MethodChannel(SystemVoiceRecognizer.channelName)
          .invokeMethod<String>('recordOnce')
          .timeout(defaultTimeout + _recordingHeadroom);
      if (path == null || path.isEmpty) return null;
      final file = File(path);
      if (!await file.exists()) return null;
      try {
        return await file.readAsBytes();
      } finally {
        try {
          await file.delete();
        } on Object {
          // The OS cleans the cache dir eventually.
        }
      }
    } on Object {
      return null;
    }
  }

  static VoiceResult _parse(dynamic data) {
    final map = _asMap(data);
    if (map == null) {
      return const VoiceResult(error: '云端语音服务返回了无法识别的数据');
    }
    final text = map['text'];
    if (text is String && text.trim().isNotEmpty) {
      return VoiceResult(text: text.trim());
    }
    return const VoiceResult(error: '语音服务没有返回识别结果');
  }

  static Map<String, dynamic>? _asMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } on FormatException {
        return null;
      }
    }
    return null;
  }

  static String _fromDio(DioException e) {
    final response = e.response;
    if (response != null) {
      final status = response.statusCode;
      final serverMessage = _errorMessage(response.data);
      final suffix = serverMessage == null ? '' : '：$serverMessage';
      return '云端语音服务返回错误（HTTP ${status ?? '?'}）$suffix';
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return '云端语音服务响应超时，请检查网络或 Base URL 后重试';
      case DioExceptionType.connectionError:
        return '无法连接云端语音服务，请检查网络、Base URL 或代理设置';
      case DioExceptionType.badCertificate:
        return '无法验证云端语音服务的安全证书';
      case DioExceptionType.cancel:
        return '语音识别已取消';
      case DioExceptionType.badResponse:
        return '云端语音服务返回了异常响应';
      case DioExceptionType.unknown:
        return '无法连接云端语音服务，请检查网络与配置';
    }
  }

  /// Extracts `error.message` (or a short plain-text body) for the user.
  /// HTML error pages are dropped rather than shown.
  static String? _errorMessage(dynamic data) {
    final map = _asMap(data);
    if (map != null) {
      final error = map['error'];
      if (error is Map) {
        final message = error['message'];
        if (message is String && message.trim().isNotEmpty) {
          return message.trim();
        }
      }
      if (error is String && error.trim().isNotEmpty) return error.trim();
      for (final key in const ['message', 'detail']) {
        final value = map[key];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
      return null;
    }
    if (data is String) {
      final text = data.trim();
      if (text.isEmpty || text.length > 300) return null;
      if (text.toLowerCase().contains('<html')) return null;
      return text;
    }
    return null;
  }
}

/// The backend selected by [VoiceConfig.engine]. Rebuilds when the settings
/// change, so the button picks up a newly configured cloud endpoint.
final voiceRecognizerProvider = Provider<VoiceRecognizer>((ref) {
  final config = ref.watch(voiceConfigProvider);
  return switch (config.engine) {
    VoiceEngine.native => SystemVoiceRecognizer(),
    VoiceEngine.cloudWhisper => CloudWhisperRecognizer(config: config),
  };
});
