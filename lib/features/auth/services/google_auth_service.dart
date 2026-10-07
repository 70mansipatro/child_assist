import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Why Google sign-in did not produce an ID token. [message] is safe to show to the user.
class GoogleAuthException implements Exception {
  const GoogleAuthException(this.message, {this.cancelled = false});

  static const cancelledByUser = GoogleAuthException('Google sign-in was cancelled.', cancelled: true);
  static const notConfigured =
      GoogleAuthException('Google Sign-In is not configured correctly.\nPlease try again later.');

  final String message;

  /// The user closed the account picker. Not an error worth alarming them about.
  final bool cancelled;

  @override
  String toString() => 'GoogleAuthException: $message';
}

/// Google is only the identity provider: this returns a Google ID token for the backend to verify,
/// which then issues the Child Assist JWT. The ID token is never stored, logged or kept here.
abstract class GoogleAuthService {
  /// Whether "Continue with Google" can be offered on this platform.
  bool get isAvailable;

  /// Shows Google's account picker and returns an ID token issued to the Child Assist server.
  /// Throws [GoogleAuthException] (with `cancelled` set if the user backed out).
  Future<String> signIn();

  /// Clears this app's Google sign-in state so the next sign-in shows the account picker again.
  /// It does not remove the Google account from the device or revoke anything. Never throws.
  Future<void> signOut();
}

/// The real implementation, using the official `google_sign_in` plugin.
///
/// Configuration is passed at build time, never committed:
///   `--dart-define=GOOGLE_SERVER_CLIENT_ID=<Web application OAuth client ID>`
/// The backend's GOOGLE_WEB_CLIENT_ID must be the same value: ID tokens are issued to it. Android
/// itself is identified by package name + signing SHA-1 registered on an Android OAuth client,
/// so no Android client ID or any client secret is in the app.
/// iOS (not set up yet) additionally needs --dart-define=GOOGLE_IOS_CLIENT_ID=... and the reversed
/// client ID URL scheme in ios/Runner/Info.plist; until then the button is hidden there.
class PlatformGoogleAuthService implements GoogleAuthService {
  PlatformGoogleAuthService({String? serverClientId, String? iosClientId})
      : _serverClientId = serverClientId ?? const String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID'),
        _iosClientId = iosClientId ?? const String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

  final String _serverClientId;
  final String _iosClientId;
  Future<void>? _initialized;

  GoogleSignIn get _google => GoogleSignIn.instance;

  @override
  bool get isAvailable {
    // Web needs its own OAuth flow (Google's rendered button), which Child Assist does not use.
    if (kIsWeb) return false;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => true,
      TargetPlatform.iOS => _iosClientId.isNotEmpty,
      _ => false,
    };
  }

  Future<void> _ensureInitialized() {
    return _initialized ??= _google
        .initialize(
          clientId: _iosClientId.isEmpty ? null : _iosClientId,
          serverClientId: _serverClientId,
        )
        .catchError((Object e) {
      _initialized = null; // Allow a retry.
      throw e;
    });
  }

  @override
  Future<String> signIn() async {
    if (!isAvailable || _serverClientId.isEmpty) {
      _debugLog('GOOGLE_SERVER_CLIENT_ID was not provided with --dart-define.');
      throw GoogleAuthException.notConfigured;
    }
    try {
      await _ensureInitialized();
      if (!_google.supportsAuthenticate()) throw GoogleAuthException.notConfigured;
      final account = await _google.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null || idToken.isEmpty) {
        // Happens when the server client ID is missing or wrong.
        _debugLog('Google returned no ID token; check GOOGLE_SERVER_CLIENT_ID.');
        throw GoogleAuthException.notConfigured;
      }
      return idToken;
    } on GoogleSignInException catch (e) {
      _debugLog('GoogleSignInException ${e.code.name}: ${e.description}');
      throw switch (e.code) {
        GoogleSignInExceptionCode.canceled => GoogleAuthException.cancelledByUser,
        GoogleSignInExceptionCode.interrupted =>
          const GoogleAuthException('Google sign-in was interrupted. Please try again.'),
        GoogleSignInExceptionCode.clientConfigurationError ||
        GoogleSignInExceptionCode.providerConfigurationError =>
          GoogleAuthException.notConfigured,
        GoogleSignInExceptionCode.uiUnavailable =>
          const GoogleAuthException("Google sign-in isn't available on this device right now."),
        // Android Credential Manager reports this when the device has no Google account.
        _ when (e.description ?? '').contains('No credential') => const GoogleAuthException(
            'No Google account found on this device. Add one in Settings > Accounts, then try again.'),
        _ => const GoogleAuthException('Google sign-in failed. Please try again.'),
      };
    } on GoogleAuthException {
      rethrow;
    } catch (e) {
      // e.g. a PlatformException from a misconfigured project.
      _debugLog('Google sign-in error: ${e.runtimeType}');
      throw GoogleAuthException.notConfigured;
    }
  }

  @override
  Future<void> signOut() async {
    if (!isAvailable) return;
    try {
      await _ensureInitialized();
      await _google.signOut();
    } catch (e) {
      _debugLog('Google sign-out failed: ${e.runtimeType}');
    }
  }

  /// Technical details for developers only; never includes tokens.
  static void _debugLog(String message) {
    if (kDebugMode) debugPrint('[GoogleAuth] $message');
  }
}
