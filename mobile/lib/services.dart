import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'models.dart';
import 'store.dart';
import 'sync.dart';

/// Default server for development: the iOS simulator reaches the host as localhost, the Android emulator as 10.0.2.2.
String get defaultServerUrl =>
    !kIsWeb && Platform.isAndroid ? 'http://10.0.2.2:8000' : 'http://localhost:8000';

/// App-wide services, created once at startup and handed down the widget tree.
class Services extends ChangeNotifier {
  Services._(this.store, this.dataDir, this._secure);

  final LocalStore store;
  final Directory dataDir;
  final FlutterSecureStorage _secure;
  ApiClient? _api;
  SyncService? sync;
  AppUser? user;
  String serverUrl = defaultServerUrl;

  ApiClient get api => _api!;
  bool get signedIn => _api?.token != null && user != null;

  static Future<Services> init() async {
    final dir = await getApplicationSupportDirectory();
    final store = await LocalStore.open(p.join(dir.path, 'agripulse.db'));
    final s = Services._(store, dir, const FlutterSecureStorage());
    s.serverUrl = await s._secure.read(key: 'server') ?? defaultServerUrl;
    final token = await s._secure.read(key: 'token');
    final user = await s._secure.read(key: 'user');
    if (token != null && user != null) {
      s._start(token, AppUser.fromJson(jsonDecode(user)));
    }
    return s;
  }

  void _start(String token, AppUser user) {
    this.user = user;
    _api = ApiClient(baseUrl: serverUrl, token: token);
    sync?.dispose();
    sync = SyncService(store, api)..startPeriodic();
  }

  Future<void> signIn(String server, String email, String password) async {
    final (token, user) = await ApiClient(baseUrl: server).login(email, password);
    serverUrl = server;
    await _secure.write(key: 'server', value: server);
    await _secure.write(key: 'token', value: token);
    await _secure.write(key: 'user', value: jsonEncode(user.toJson()));
    _start(token, user);
    notifyListeners();
  }

  /// Unsynced notes stay in the local outbox and upload after the next sign-in.
  Future<void> signOut() async {
    await _secure.delete(key: 'token');
    await _secure.delete(key: 'user');
    sync?.dispose();
    sync = null;
    _api = null;
    user = null;
    notifyListeners();
  }

  Directory get photoDir => Directory(p.join(dataDir.path, 'photos'))..createSync(recursive: true);
  Directory get mapDir => Directory(p.join(dataDir.path, 'maps'))..createSync(recursive: true);
}

class ServicesScope extends InheritedNotifier<Services> {
  const ServicesScope({super.key, required Services services, required super.child}) : super(notifier: services);

  static Services of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ServicesScope>()!.notifier!;
}
