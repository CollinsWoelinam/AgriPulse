import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  ApiException(this.status, this.message);

  final int status;
  final String message;

  /// Client errors other than auth won't succeed on retry (validation, forbidden, conflict).
  bool get isPermanent => status >= 400 && status < 500 && status != 401 && status != 408 && status != 429;

  @override
  String toString() => message;
}

class AuthExpired extends ApiException {
  AuthExpired() : super(401, 'Session expired. Sign in again.');
}

class ApiClient {
  ApiClient({required this.baseUrl, this.token, http.Client? client}) : _http = client ?? http.Client();

  final String baseUrl;
  String? token;
  final http.Client _http;
  static const _timeout = Duration(seconds: 30);

  Uri _uri(String path) => Uri.parse(baseUrl.replaceAll(RegExp(r'/+$'), '') + path);

  Map<String, String> get _auth => {if (token != null) 'Authorization': 'Bearer $token'};

  Future<dynamic> _send(String method, String path, {Object? body}) async {
    http.Request build() {
      final req = http.Request(method, _uri(path))..headers.addAll(_auth);
      if (body != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = jsonEncode(body);
      }
      return req;
    }

    final res = await _withRetry(method, () async => http.Response.fromStream(await _http.send(build()).timeout(_timeout)));
    _check(res);
    return res.body.isEmpty ? null : jsonDecode(res.body);
  }

  /// Retries GET/PUT once when the connection fails before a response: a pooled keep-alive socket the
  /// server already closed fails instantly. Both are idempotent here (PUTs carry device-generated ids).
  Future<T> _withRetry<T>(String method, Future<T> Function() send) async {
    try {
      return await send();
    } on Exception catch (e) {
      if ((method != 'GET' && method != 'PUT') || (e is! http.ClientException && e is! SocketException)) rethrow;
      return send();
    }
  }

  void _check(http.Response res) {
    if (res.statusCode == 401 && token != null) throw AuthExpired();
    if (res.statusCode >= 400) {
      String message = 'Server error ${res.statusCode}';
      try {
        final detail = jsonDecode(res.body)['detail'];
        if (detail is String) message = detail;
      } catch (_) {}
      throw ApiException(res.statusCode, message);
    }
  }

  Future<(String, AppUser)> login(String email, String password) async {
    final j = await _send('POST', '/api/auth/login', body: {'email': email, 'password': password});
    return (j['token'] as String, AppUser.fromJson(j['user']));
  }

  Future<List<Map<String, dynamic>>> fields() async =>
      (await _send('GET', '/api/fields') as List).cast<Map<String, dynamic>>();

  Future<Map<String, dynamic>> scouting(String fieldId) async =>
      await _send('GET', '/api/fields/$fieldId/scouting') as Map<String, dynamic>;

  /// Streams the MBTiles package to [dest] (written to a temp file first, so a failed download leaves nothing).
  Future<void> download(String path, File dest) async {
    final res = await _withRetry('GET', () => _http
        .send(http.Request('GET', _uri(path))..headers.addAll(_auth))
        .timeout(const Duration(minutes: 5)));
    if (res.statusCode != 200) _check(await http.Response.fromStream(res));
    final tmp = File('${dest.path}.part');
    final sink = tmp.openWrite();
    await res.stream.pipe(sink);
    await tmp.rename(dest.path);
  }

  Future<void> putNote(LocalNote note) => _send('PUT', '/api/notes/${note.id}', body: note.toApiJson());

  Future<void> putPhoto(String noteId, String photoId, File file) async {
    final ext = file.path.split('.').last.toLowerCase();
    final type = switch (ext) { 'png' => 'image/png', 'heic' => 'image/heic', 'webp' => 'image/webp', _ => 'image/jpeg' };
    final bytes = await file.readAsBytes();
    final res = await _withRetry('PUT', () => _http
        .put(_uri('/api/notes/$noteId/photos/$photoId'), headers: {..._auth, 'Content-Type': type}, body: bytes)
        .timeout(const Duration(minutes: 2)));
    _check(res);
  }
}
