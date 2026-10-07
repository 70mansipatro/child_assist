import 'package:flutter/foundation.dart';

import '../../../core/api/api_client.dart';
import '../data/auth_api.dart';
import '../data/token_storage.dart';
import '../models/user.dart';
import 'google_auth_service.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

/// The password was right, but the account's email address is not verified yet, so no session
/// was started. The server has emailed a code (unless it sent one moments ago).
class EmailNotVerifiedException implements Exception {
  const EmailNotVerifiedException(this.email, this.message);

  final String email;
  final String message;

  @override
  String toString() => 'EmailNotVerifiedException: $message';
}

/// Owns the signed-in state. Widgets listen to it to switch between login and home.
class AuthService extends ChangeNotifier {
  AuthService({required AuthApi api, required TokenStorage storage, GoogleAuthService? google})
      : _api = api,
        _storage = storage,
        _google = google ?? PlatformGoogleAuthService();

  final AuthApi _api;
  final TokenStorage _storage;
  final GoogleAuthService _google;

  /// Whether to offer "Continue with Google" on this platform.
  bool get googleSignInAvailable => _google.isAvailable;

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

  /// Creates an account and has a verification code emailed to it. Does not sign in: the user
  /// must verify the email and then log in. Returns the server's message.
  Future<String> register({
    required String name,
    required String email,
    required String password,
  }) {
    return _api.register(name: name, email: email, password: password);
  }

  /// Verifies the account's email with the 6-digit code. Does not sign in.
  Future<void> verifyEmail({required String email, required String code}) {
    return _api.verifyEmail(email: email, code: code);
  }

  /// Asks the server to email a new verification code. Returns its (deliberately generic) message.
  Future<String> resendVerification({required String email}) {
    return _api.resendVerification(email: email);
  }

  /// Asks for a password reset code. Returns the server's (deliberately generic) message.
  Future<String> forgotPassword({required String email}) => _api.forgotPassword(email: email);

  /// Asks for a new password reset code. Returns the server's generic message.
  Future<String> resendResetCode({required String email}) => _api.resendResetCode(email: email);

  /// Exchanges the emailed reset code for a single-use reset token. Does not sign in.
  Future<String> verifyResetCode({required String email, required String code}) =>
      _api.verifyResetCode(email: email, code: code);

  /// Sets a new password with the reset token. Does not sign in: the user logs in afterwards.
  Future<String> resetPassword({
    required String resetToken,
    required String newPassword,
    required String confirmPassword,
  }) =>
      _api.resetPassword(resetToken: resetToken, newPassword: newPassword, confirmPassword: confirmPassword);

  /// Throws [EmailNotVerifiedException] if the password is right but the email is not verified
  /// yet, or [ApiException] for any other failure.
  Future<void> login({required String email, required String password}) async {
    final AuthResponse result;
    try {
      result = await _api.login(email: email, password: password);
    } on ApiException catch (e) {
      if (e.code == 'EMAIL_NOT_VERIFIED') throw EmailNotVerifiedException(email, e.message);
      rethrow;
    }
    await _storage.write(result.token);
    _setSignedIn(result.user);
  }

  /// "Continue with Google": signs in to, or creates, the Child Assist account for the chosen
  /// Google account. Google only proves who the user is; the session is the backend's own JWT.
  /// Throws [GoogleAuthException] if no Google account was chosen (nothing changes), or
  /// [ApiException] if the backend refused (e.g. the email belongs to a password account).
  Future<void> loginWithGoogle() async {
    final idToken = await _google.signIn();
    final AuthResponse result;
    try {
      result = await _api.google(idToken: idToken);
    } catch (_) {
      // Let the user pick a different Google account on the next try.
      await _google.signOut();
      rethrow;
    }
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
      // Forget the app's Google sign-in so the account picker shows next time. The Google
      // account stays on the device. A no-op for password accounts.
      await _google.signOut();
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
