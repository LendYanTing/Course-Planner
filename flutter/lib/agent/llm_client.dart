import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'agent_config.dart';

/// One tool call the model asked for. [argumentsJson] is kept as the raw JSON
/// string from the wire so it can be echoed back unchanged in the next turn.
class LlmToolCall {
  const LlmToolCall({
    required this.id,
    required this.name,
    required this.argumentsJson,
  });

  final String id;
  final String name;
  final String argumentsJson;
}

/// One assistant turn from an OpenAI-compatible `chat/completions` response.
class LlmReply {
  const LlmReply({this.content, this.toolCalls = const [], this.finishReason});

  final String? content;
  final List<LlmToolCall> toolCalls;
  final String? finishReason;
}

/// Readable failure of one model request. [message] is always Chinese and
/// never contains the API key.
class LlmException implements Exception {
  LlmException(this.message, {this.status});

  final String message;
  final int? status;

  @override
  String toString() => 'LlmException(${status ?? '-'}): $message';
}

/// Minimal OpenAI Chat Completions client with function calling.
///
/// No global Dio singleton: the transport is injectable so tests (and callers
/// with custom adapters) can supply their own. Requests deliberately carry
/// only the model's own credential — they never go through [servicesProvider]
/// or the app's authenticated transport.
class LlmClient {
  LlmClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: _timeout,
              sendTimeout: _timeout,
            ),
          );

  static const _timeout = Duration(seconds: 60);

  final Dio _dio;

  Future<LlmReply> complete({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
  }) async {
    final baseUrl = config.baseUrl.trim();
    if (baseUrl.isEmpty) {
      throw LlmException('模型服务地址为空，请先在设置中填写 Base URL');
    }
    final model = config.model.trim();
    if (model.isEmpty) {
      throw LlmException('模型名称为空，请先在设置中填写 Model');
    }
    final body = <String, dynamic>{
      'model': model,
      'messages': messages,
      'temperature': config.temperature,
      if (tools.isNotEmpty) 'tools': tools,
      if (tools.isNotEmpty) 'tool_choice': 'auto',
    };
    final headers = <String, dynamic>{
      'Content-Type': 'application/json',
      // A local Ollama needs no key; never send a bare `Bearer `.
      if (config.apiKey.trim().isNotEmpty)
        'Authorization': 'Bearer ${config.apiKey.trim()}',
    };
    try {
      final res = await _dio
          .post<dynamic>(
            _endpoint(baseUrl),
            data: body,
            options: Options(headers: headers),
          )
          .timeout(_timeout);
      return _parse(res.data);
    } on DioException catch (e) {
      throw _fromDio(e);
    } on TimeoutException {
      throw LlmException('模型服务响应超时（60 秒），请稍后重试');
    } on LlmException {
      rethrow;
    } on Object {
      // Never let the raw exception (and its request headers) escape.
      throw LlmException('模型请求失败，请检查网络与配置后重试');
    }
  }

  /// `{baseUrl}/chat/completions`, tolerating a pasted full endpoint.
  static String _endpoint(String baseUrl) {
    var url = baseUrl;
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/chat/completions')) return url;
    return '$url/chat/completions';
  }

  static LlmReply _parse(dynamic data) {
    final decoded = _asMap(data);
    if (decoded == null) {
      throw LlmException('模型服务返回了无法识别的数据');
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw LlmException('模型服务没有返回任何结果');
    }
    final choice = choices.first;
    if (choice is! Map) throw LlmException('模型服务返回了无法识别的数据');
    final message = choice['message'];
    if (message is! Map) throw LlmException('模型服务返回了无法识别的数据');

    final rawContent = message['content'];
    final content = rawContent is String && rawContent.isNotEmpty
        ? rawContent
        : null;

    final toolCalls = <LlmToolCall>[];
    final rawCalls = message['tool_calls'];
    if (rawCalls is List) {
      for (var i = 0; i < rawCalls.length; i++) {
        final call = rawCalls[i];
        if (call is! Map) continue;
        final fn = call['function'];
        if (fn is! Map) continue;
        final name = fn['name'];
        if (name is! String || name.isEmpty) continue;
        final rawArgs = fn['arguments'];
        final args = rawArgs is String
            ? rawArgs
            : rawArgs == null
            ? '{}'
            : jsonEncode(rawArgs);
        final rawId = call['id'];
        toolCalls.add(
          LlmToolCall(
            id: rawId is String && rawId.isNotEmpty ? rawId : 'call_$i',
            name: name,
            argumentsJson: args,
          ),
        );
      }
    }
    final reason = choice['finish_reason'];
    return LlmReply(
      content: content,
      toolCalls: toolCalls,
      finishReason: reason is String ? reason : null,
    );
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

  static LlmException _fromDio(DioException e) {
    final res = e.response;
    if (res != null) {
      final status = res.statusCode;
      final serverMessage = _errorMessage(res.data);
      final suffix = serverMessage == null ? '' : '：$serverMessage';
      return LlmException(
        '模型服务返回错误（HTTP ${status ?? '?'}）$suffix',
        status: status,
      );
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return LlmException('模型服务响应超时，请检查网络或 Base URL 后重试');
      case DioExceptionType.connectionError:
        return LlmException('无法连接模型服务，请检查网络、Base URL 或本地服务是否已启动');
      case DioExceptionType.badCertificate:
        return LlmException('无法验证模型服务的安全证书');
      case DioExceptionType.cancel:
        return LlmException('模型请求已取消');
      case DioExceptionType.badResponse:
        return LlmException('模型服务返回了异常响应');
      case DioExceptionType.unknown:
        return LlmException('无法连接模型服务，请检查网络与配置');
    }
  }

  /// Extracts `error.message` (or a short plain-text body). HTML error pages
  /// are dropped rather than shown to the user.
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
