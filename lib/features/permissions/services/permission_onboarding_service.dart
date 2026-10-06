import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/api/api_client.dart';
import '../../auth/services/auth_service.dart';
import '../../profile/services/profile_service.dart';

/// Where a signed-in user goes after authentication.
enum OnboardingGate {
  /// Still asking the backend whether the walkthrough was completed.
  checking,

  /// The backend could not be reached; the user can retry.
  failed,

  /// The walkthrough has not been completed: show it.
  required,

  /// Completed before (on any device): go straight to Home.
  completed,
}

/// Decides, for the signed-in user, whether the first-time permission walkthrough is needed.
///
/// The backend's `permissionOnboardingCompleted` flag is the source of truth, so the decision
/// survives logout, reinstall and new devices. Only the step reached inside an unfinished
/// walkthrough is kept on the device, so an interrupted walkthrough resumes where it stopped.
class PermissionOnboardingService extends ChangeNotifier {
  PermissionOnboardingService({
    required ProfileService profileService,
    required AuthService authService,
    OnboardingProgressStore? progressStore,
  }) : _profile = profileService,
       _auth = authService,
       _progress = progressStore ?? OnboardingProgressStore() {
    _auth.addListener(_onAuthChanged);
    _onAuthChanged();
  }

  final ProfileService _profile;
  final AuthService _auth;
  final OnboardingProgressStore _progress;

  /// The user [_gate] belongs to; null when signed out.
  String? _userId;
  OnboardingGate _gate = OnboardingGate.checking;
  String? _error;

  /// The gate for [userId]. Reports [OnboardingGate.checking] until it is known for that user,
  /// so a previous account's answer is never used.
  OnboardingGate gateFor(String userId) => _userId == userId ? _gate : OnboardingGate.checking;

  /// Why the last check failed, safe to show to the user.
  String? get error => _error;

  /// Asks the backend whether the current user has completed the walkthrough.
  Future<void> refresh() async {
    final userId = _userId;
    if (userId == null) return;
    _gate = OnboardingGate.checking;
    _error = null;
    notifyListeners();
    try {
      final profile = await _profile.load();
      if (_userId != userId) return;
      _gate = profile.permissionOnboardingCompleted
          ? OnboardingGate.completed
          : OnboardingGate.required;
    } on ApiException catch (e) {
      // A 401 has already signed the user out; anything else can be retried.
      if (_userId != userId) return;
      _gate = OnboardingGate.failed;
      _error = e.message;
    }
    notifyListeners();
  }

  /// Index of the first unfinished step saved on this device for the current user (0 if none).
  Future<int> savedStep() async {
    final userId = _userId;
    return userId == null ? 0 : _progress.read(userId);
  }

  /// Remembers that every step before [step] is done, in case the app is closed mid-way.
  Future<void> saveStep(int step) async {
    final userId = _userId;
    if (userId != null) await _progress.write(userId, step);
  }

  /// Marks the walkthrough completed on the backend. Throws [ApiException] if that cannot be
  /// confirmed, in which case nothing changes and the caller should offer a retry.
  Future<void> complete() async {
    final userId = _userId;
    if (userId == null) return;
    final profile = await _profile.setPermissionOnboardingCompleted(true);
    if (_userId != userId || !profile.permissionOnboardingCompleted) return;
    await _progress.clear(userId);
    _gate = OnboardingGate.completed;
    notifyListeners();
  }

  void _onAuthChanged() {
    final userId = _auth.status == AuthStatus.authenticated ? _auth.currentUser?.id : null;
    if (userId == _userId) return; // e.g. a profile name change: nothing to re-check
    _userId = userId;
    _gate = OnboardingGate.checking;
    _error = null;
    if (userId != null) unawaited(refresh());
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    super.dispose();
  }
}

/// Per-user walkthrough progress on this device. Only a step number is stored; whether the
/// walkthrough is completed is always read from the backend.
class OnboardingProgressStore {
  OnboardingProgressStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
          );

  final FlutterSecureStorage _storage;

  static String _key(String userId) => 'permission_onboarding_step_$userId';

  // Progress is a convenience: if storage fails, the walkthrough just starts from the top.
  Future<int> read(String userId) async {
    try {
      return int.tryParse(await _storage.read(key: _key(userId)) ?? '') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> write(String userId, int step) async {
    try {
      await _storage.write(key: _key(userId), value: '$step');
    } catch (_) {}
  }

  Future<void> clear(String userId) async {
    try {
      await _storage.delete(key: _key(userId));
    } catch (_) {}
  }
}
