import '../../../core/api/api_client.dart';
import '../models/user.dart';

class AuthResponse {
  const AuthResponse({required this.user, required this.token});

  final User user;
  final String token;

  factory AuthResponse.fromJson(Map<String, dynamic> json) {
    return AuthResponse(
      user: User.fromJson(json['user'] as Map<String, dynamic>),
      token: json['token'] as String,
    );
  }
}

/// Raw calls to the backend's /api/auth endpoints.
class AuthApi {
  AuthApi(this._client);

  final ApiClient _client;

  /// Creates an unverified account; the server emails it a 6-digit code. No session is returned:
  /// the user verifies the code, then logs in. The answer is the same whether or not the email
  /// was already registered. Returns the server's message.
  Future<String> register({
    required String name,
    required String email,
    required String password,
  }) async {
    final json = await _client.post(
      '/api/auth/register',
      body: {'name': name, 'email': email, 'password': password},
    );
    return json['message'] as String? ?? 'Verification code sent to your email.';
  }

  /// Checks the emailed code. Throws [ApiException] (code `INVALID_VERIFICATION_CODE`) if it is
  /// wrong, expired, already used or out of attempts.
  Future<void> verifyEmail({required String email, required String code}) async {
    await _client.post('/api/auth/verify-email', body: {'email': email, 'code': code});
  }

  /// Asks for a new code. The server answers the same whether or not one was sent (it rate-limits
  /// resends and never reveals whether the email has an account). Returns its message.
  Future<String> resendVerification({required String email}) async {
    final json = await _client.post('/api/auth/resend-verification', body: {'email': email});
    return json['message'] as String? ?? 'If verification is required, a new code has been sent.';
  }

  Future<AuthResponse> login({required String email, required String password}) async {
    final json = await _client.post(
      '/api/auth/login',
      body: {'email': email, 'password': password},
    );
    return AuthResponse.fromJson(json);
  }

  /// Exchanges a Google ID token for a Child Assist session. Only the token is sent: the server
  /// takes the name, email and Google account ID from it after verifying it.
  Future<AuthResponse> google({required String idToken}) async {
    final json = await _client.post('/api/auth/google', body: {'idToken': idToken});
    return AuthResponse.fromJson(json);
  }

  Future<User> me(String token) async {
    final json = await _client.get('/api/auth/me', token: token);
    return User.fromJson(json['user'] as Map<String, dynamic>);
  }

  Future<void> logout(String token) async {
    await _client.post('/api/auth/logout', token: token);
  }
}
