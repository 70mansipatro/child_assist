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

  Future<AuthResponse> register({
    required String name,
    required String email,
    required String password,
  }) async {
    final json = await _client.post(
      '/api/auth/register',
      body: {'name': name, 'email': email, 'password': password},
    );
    return AuthResponse.fromJson(json);
  }

  Future<AuthResponse> login({required String email, required String password}) async {
    final json = await _client.post(
      '/api/auth/login',
      body: {'email': email, 'password': password},
    );
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
