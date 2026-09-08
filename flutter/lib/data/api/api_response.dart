import 'package:dio/dio.dart';

/// Small unwrap helpers for the `{data: ...}` envelope (docs/api.md §2).
Map<String, dynamic> unwrapDataObject(Response<dynamic> res) {
  final body = res.data;
  if (body is Map && body['data'] is Map) {
    return Map<String, dynamic>.from(body['data'] as Map);
  }
  throw const _BadEnvelope('object data');
}

List<dynamic> unwrapDataList(Response<dynamic> res) {
  final body = res.data;
  if (body is Map && body['data'] is List) {
    return body['data'] as List;
  }
  throw const _BadEnvelope('array data');
}

class _BadEnvelope implements Exception {
  const _BadEnvelope(this.expected);
  final String expected;
  @override
  String toString() => 'Malformed API response: expected $expected';
}
