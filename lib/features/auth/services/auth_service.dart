import 'package:flutter/foundation.dart';

import '../../../core/api/api_client.dart';
import '../data/auth_api.dart';
import '../data/token_storage.dart';
import '../models/user.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

/// Owns the signed-in state. Widgets listen to it to switch between login and home.
class AuthService extends ChangeNotifier {
  AuthService({required AuthApi api, required TokenStorage storage})
      : _api = api,
        _storage = storage;

  final AuthApi _api;
  final TokenStorage _storage;

  AuthStatus _status = AuthStatus.unknown;
  User? _user;

  AuthStatus get status => _status;
  User? get currentUser => _user;

  /// Called on app start: if a token is stored, validate it with GET /api/auth/me.
  Future<void> restoreSession() async {
    final token = await _storage.read();
    if (token == null) {
      _setSignedOut();
      return;
    }
    try {
      _setSignedIn(await _api.me(token));
    } on ApiException catch (e) {
      // Expired/invalid token or deleted account: discard it.
      if (e.isUnauthorized) await _storage.delete();
      _setSignedOut();
    }
  }

  Future<void> register({
    required String name,
    required String email,
    required String password,
  }) async {
    final result = await _api.register(name: name, email: email, password: password);
    await _storage.write(result.token);
    _setSignedIn(result.user);
  }

  Future<void> login({required String email, required String password}) async {
    final result = await _api.login(email: email, password: password);
    await _storage.write(result.token);
    _setSignedIn(result.user);
  }

  /// Reloads the current user from the server.
  Future<User?> refreshCurrentUser() async {
    final token = await _storage.read();
    if (token == null) return null;
    final user = await _api.me(token);
    _setSignedIn(user);
    return user;
  }

  /// Runs an authenticated API call with the stored token. A 401 means the session is no
  /// longer valid, so the user is signed out (the app returns to Login) and the error rethrown.
  Future<T> authorized<T>(Future<T> Function(String token) call) async {
    final token = await _storage.read();
    if (token == null) {
      _setSignedOut();
      throw ApiException('Your session has expired. Please log in again.', statusCode: 401);
    }
    try {
      return await call(token);
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        await _storage.delete();
        _setSignedOut();
      }
      rethrow;
    }
  }

  /// Replaces the cached user after a profile change, so e.g. the Home greeting updates.
  void updateCurrentUser(User user) {
    if (_status != AuthStatus.authenticated || _user?.id != user.id) return;
    _setSignedIn(user);
  }

  /// JWTs are stateless, so the server cannot invalidate them; signing out means
  /// deleting the locally stored token. The token is removed even if the call fails.
  Future<void> logout() async {
    final token = await _storage.read();
    try {
      if (token != null) await _api.logout(token);
    } on ApiException {
      // Ignore: being offline must not prevent signing out locally.
    } finally {
      await _storage.delete();
      _setSignedOut();
    }
  }

  void _setSignedIn(User user) {
    _user = user;
    _status = AuthStatus.authenticated;
    notifyListeners();
  }

  void _setSignedOut() {
    _user = null;
    _status = AuthStatus.unauthenticated;
    notifyListeners();
  }
}
