import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Thrown for any failed API call. [message] is safe to show to the user.
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.fieldErrors = const {}, this.code});

  final String message;

  /// HTTP status code, or null when the server could not be reached.
  final int? statusCode;

  /// Validation messages keyed by field name (from HTTP 400 responses).
  final Map<String, String> fieldErrors;

  /// Stable machine-readable reason from the server (e.g. "AI_UNAVAILABLE"), when it sent one.
  final String? code;

  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Thin JSON-over-HTTP client for the Child Assist backend.
class ApiClient {
  ApiClient({String? baseUrl, http.Client? httpClient})
      : baseUrl = baseUrl ?? defaultBaseUrl,
        _http = httpClient ?? http.Client();

  final String baseUrl;
  final http.Client _http;

  static const Duration _timeout = Duration(seconds: 15);

  /// Override at build time with `--dart-define=API_BASE_URL=http://<host>:3000`.
  /// Defaults: Android emulator reaches the host machine via 10.0.2.2.
  static String get defaultBaseUrl {
    const fromEnv = String.fromEnvironment('API_BASE_URL');
    if (fromEnv.isNotEmpty) return fromEnv;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:3000';
    }
    return 'http://localhost:3000';
  }

  Future<Map<String, dynamic>> get(String path, {String? token}) {
    return _send(() => _http.get(_uri(path), headers: _headers(token)));
  }

  /// [timeout] overrides the default for slow calls (e.g. an AI reply).
  Future<Map<String, dynamic>> post(String path, {Object? body, String? token, Duration? timeout}) {
    return _send(
      () => _http.post(
        _uri(path),
        headers: _headers(token),
        body: body == null ? null : jsonEncode(body),
      ),
      timeout: timeout,
    );
  }

  Future<Map<String, dynamic>> patch(String path, {Object? body, String? token}) {
    return _send(() => _http.patch(
          _uri(path),
          headers: _headers(token),
          body: body == null ? null : jsonEncode(body),
        ));
  }

  Future<Map<String, dynamic>> delete(String path, {String? token}) {
    return _send(() => _http.delete(_uri(path), headers: _headers(token)));
  }

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Map<String, String> _headers(String? token) => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<Map<String, dynamic>> _send(Future<http.Response> Function() request, {Duration? timeout}) async {
    final http.Response response;
    try {
      response = await request().timeout(timeout ?? _timeout);
    } on TimeoutException {
      throw ApiException('The server took too long to respond. Please try again.');
    } on http.ClientException {
      throw ApiException('Could not reach the server. Check your connection.');
    }

    final json = _decode(response.body);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return json;
    }

    final fieldErrors = <String, String>{};
    final errors = json['errors'];
    if (errors is List) {
      for (final e in errors) {
        if (e is Map && e['field'] is String && e['message'] is String) {
          fieldErrors.putIfAbsent(e['field'] as String, () => e['message'] as String);
        }
      }
    }
    final message = json['message'] is String
        ? json['message'] as String
        : 'Something went wrong (${response.statusCode}).';
    final code = json['code'] is String ? json['code'] as String : null;
    throw ApiException(message, statusCode: response.statusCode, fieldErrors: fieldErrors, code: code);
  }

  Map<String, dynamic> _decode(String body) {
    if (body.isEmpty) return {};
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : {};
    } on FormatException {
      return {};
    }
  }
}
