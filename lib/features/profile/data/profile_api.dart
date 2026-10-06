import '../../../core/api/api_client.dart';
import '../models/profile.dart';

/// Raw calls to the backend's /api/profile endpoints. The server identifies the user
/// from the token, so no user ID is ever sent.
class ProfileApi {
  ProfileApi(this._client);

  final ApiClient _client;

  Future<Profile> getProfile(String token) async {
    final json = await _client.get('/api/profile', token: token);
    return Profile.fromJson(json['user'] as Map<String, dynamic>);
  }

  Future<Profile> updateProfile(String token, {required String name}) async {
    final json = await _client.patch('/api/profile', token: token, body: {'name': name});
    return Profile.fromJson(json['user'] as Map<String, dynamic>);
  }

  Future<Profile> setPermissionOnboarding(String token, {required bool completed}) async {
    final json = await _client.patch(
      '/api/profile/permission-onboarding',
      token: token,
      body: {'completed': completed},
    );
    return Profile.fromJson(json['user'] as Map<String, dynamic>);
  }
}
