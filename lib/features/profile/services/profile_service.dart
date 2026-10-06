import '../../auth/services/auth_service.dart';
import '../data/profile_api.dart';
import '../models/profile.dart';

/// Loads and updates the signed-in user's profile.
class ProfileService {
  ProfileService({required ProfileApi api, required AuthService authService})
      : _api = api,
        _auth = authService;

  static const int maxNameLength = 100;

  final ProfileApi _api;
  final AuthService _auth;

  Future<Profile> load() => _auth.authorized(_api.getProfile);

  Future<Profile> updateName(String name) async {
    final profile = await _auth.authorized((token) => _api.updateProfile(token, name: name.trim()));
    _auth.updateCurrentUser(profile.toUser());
    return profile;
  }

  /// Records on the backend whether the first-time permission walkthrough is finished.
  Future<Profile> setPermissionOnboardingCompleted(bool completed) =>
      _auth.authorized((token) => _api.setPermissionOnboarding(token, completed: completed));
}
