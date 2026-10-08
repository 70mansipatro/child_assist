import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:geocoding/geocoding.dart' show Placemark;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show DateTimeRange;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:child_assist/features/profile/services/profile_photo_service.dart';
import 'package:child_assist/app_services.dart';
import 'package:child_assist/core/api/api_client.dart';
import 'package:child_assist/core/permissions/permission_service.dart';
import 'package:child_assist/features/auth/data/token_storage.dart';
import 'package:child_assist/features/auth/services/google_auth_service.dart';
import 'package:child_assist/features/chat/services/text_to_speech_service.dart';
import 'package:child_assist/features/chat/services/voice_input.dart';
import 'package:child_assist/features/contacts/models/contact_item.dart';
import 'package:child_assist/features/contacts/services/contact_service.dart';
import 'package:child_assist/features/contacts/services/message_handoff.dart';
import 'package:child_assist/features/documents/services/document_service.dart';
import 'package:child_assist/features/location/models/automatic_tracking.dart';
import 'package:child_assist/features/location/services/background_location_source.dart';
import 'package:child_assist/features/location/services/location_service.dart';
import 'package:child_assist/features/photos/services/photo_gallery_service.dart';
import 'package:child_assist/core/notifications/notification_service.dart';
import 'package:child_assist/features/voice_assistant/data/wake_word_platform.dart';

import 'fake_notifications.dart';
import 'fake_wake_word.dart';

export 'fake_notifications.dart';
export 'fake_wake_word.dart';

const testPassword = 'password123';

/// In-memory backend with the auth, profile, permission and location endpoints. Like the real
/// server, it identifies the user only from the bearer token and keeps data per user.
class FakeBackend {
  /// u1 and u2 have already been through the permission walkthrough; accounts created with
  /// POST /api/auth/register (or [addUser]) have not.
  final Map<String, Map<String, dynamic>> users = {
    'u1': {
      'id': 'u1',
      'name': 'Mansi',
      'email': 'mansi@example.com',
      'profileImageUrl': null,
      'permissionOnboardingCompleted': true,
    },
    'u2': {
      'id': 'u2',
      'name': 'Ravi',
      'email': 'ravi@example.com',
      'profileImageUrl': null,
      'permissionOnboardingCompleted': true,
    },
  };
  int _nextUserId = 3;

  /// When > 0, that many of the next GET /api/profile calls fail with 503.
  int profileFailures = 0;

  /// When > 0, that many of the next PATCH /api/permissions/:permission calls fail with 503.
  int permissionFailures = 0;

  /// When > 0, that many of the next PATCH /api/profile/permission-onboarding calls fail with 503.
  int onboardingFailures = 0;

  /// Adds an account (as if it existed before onboarding was introduced) and returns its ID.
  String addUser(String name, String email, {bool onboardingCompleted = false}) {
    final id = 'u${_nextUserId++}';
    users[id] = {
      'id': id,
      'name': name,
      'email': email,
      'profileImageUrl': null,
      'permissionOnboardingCompleted': onboardingCompleted,
    };
    return id;
  }

  /// userId -> permission -> status, as stored by PATCH /api/permissions/:permission.
  final Map<String, Map<String, String>> permissions = {};

  /// Every PATCH received, e.g. "PATCH /api/permissions/LOCATION GRANTED (u1)".
  final List<String> patches = [];

  /// userId -> saved locations (JSON as the server returns them), oldest first.
  final Map<String, List<Map<String, dynamic>>> locations = {};
  int _nextLocationId = 1;

  /// When set, every /api/location call fails with this status.
  int? locationFailureStatus;

  /// While set and not completed, GET /api/location/history waits for it (to see loading states).
  Completer<void>? historyGate;

  /// The query parameters of every GET /api/location/history, in order.
  final List<Map<String, String>> historyQueries = [];

  /// Every POST /api/location body, in order.
  final List<Map<String, dynamic>> locationPosts = [];

  /// When true, the next POST /api/location is stored but the response is lost (network drop).
  bool dropNextLocationResponse = false;

  /// Adds a saved location for [userId] directly, as if saved earlier.
  Map<String, dynamic> seedLocation(
    String userId,
    DateTime capturedAt, {
    String? placeName,
    String? address,
    String source = 'MANUAL',
    double latitude = 20.2961,
    double longitude = 85.8245,
  }) {
    final record = <String, dynamic>{
      'id': 'loc${_nextLocationId++}',
      'latitude': latitude,
      'longitude': longitude,
      'accuracy': 10,
      for (final key in placeKeys) key: null,
      'placeName': placeName,
      'address': address,
      'city': placeName == null ? null : 'Bhubaneswar',
      'capturedAt': capturedAt.toUtc().toIso8601String(),
      'source': source,
    };
    (locations[userId] ??= []).add(record);
    return record;
  }

  /// userId -> conversations (JSON as the server returns them, plus their 'messages').
  final Map<String, List<Map<String, dynamic>>> chats = {};

  /// Every POST /api/chat body received.
  final List<Map<String, dynamic>> chatRequests = [];

  /// Status codes for the next POST /api/chat calls to fail with, in order.
  final List<int> chatFailures = [];

  /// When set, the next POST /api/chat waits for this (Child Assist is "thinking").
  Completer<void>? chatPending;

  /// Decides the assistant's reply. Defaults to the fixed name answer or an echo.
  FakeChatReply Function(String message)? chatResponder;

  /// Every action call, e.g. "confirm act1", "cancel act1", "recipient act1" or
  /// "handoff act1 whatsapp_opened".
  final List<String> chatActions = [];

  /// Every action request body, in order (to check that only one address is ever sent).
  final List<Map<String, dynamic>> chatActionBodies = [];

  /// actionId -> the action as this fake server keeps it, plus its owner ('userId').
  final Map<String, Map<String, dynamic>> chatActionStore = {};

  /// When true, confirmed emails fail as if SMTP were down.
  bool emailFails = false;

  /// Emails "sent" by confirmed actions: {'to': ..., 'subject': ..., 'message': ...}.
  final List<Map<String, String?>> sentEmails = [];

  int _nextChatId = 1;
  DateTime _chatClock = DateTime.utc(2026, 10, 6, 9);

  static const placeKeys = [
    'placeName', 'address', 'street', 'locality', 'city', 'state', 'postalCode', 'country', //
  ];

  static const supportedPermissions = [
    'LOCATION', 'MICROPHONE', 'CAMERA', 'PHOTOS', 'NOTIFICATIONS', 'DOCUMENTS', 'CONTACTS', //
  ];
  static const supportedStatuses = ['UNKNOWN', 'GRANTED', 'DENIED', 'RESTRICTED', 'LIMITED'];

  static String tokenFor(String userId) => 'tok-$userId';

  /// userId -> Google account ID, for accounts that sign in with Google. Like the server, never
  /// returned in any response.
  final Map<String, String> googleSubjects = {};

  /// Accounts created with Google have no password, so password login is refused for them.
  final Set<String> passwordless = {};

  /// Every ID token POST /api/auth/google received.
  final List<String> googleTokens = [];

  /// The Google identities the fake "verifies": ID token -> claims. Other tokens are rejected.
  final Map<String, ({String sub, String email, String name})> validGoogleTokens = {};

  /// Registers a Google account and returns the ID token Google would issue for it.
  String googleAccount({required String sub, required String email, required String name}) {
    final token = 'google-id-token-$sub';
    validGoogleTokens[token] = (sub: sub, email: email, name: name);
    return token;
  }

  /// Accounts registered with a password whose email has not been verified yet.
  final Set<String> unverified = {};

  /// email -> the latest 6-digit code "emailed" to it. Only the test reads this, as the user
  /// would read their inbox; no response ever contains a code.
  final Map<String, String> inbox = {};

  /// Codes that the next verification should treat as expired.
  final Set<String> expiredCodes = {};

  /// Every email a code was sent to, in order.
  final List<String> codeEmails = [];

  /// Every body POSTed to /api/auth/verify-email and /api/auth/resend-verification.
  final List<Map<String, dynamic>> verifyRequests = [];
  final List<Map<String, dynamic>> resendRequests = [];

  /// When true, every request fails as if the network were down.
  bool offline = false;

  /// When set, POST /api/auth/verify-email waits for this before answering.
  Completer<void>? verifyPending;

  int _nextCode = 0;

  /// email -> password, for accounts whose password is not [testPassword] (e.g. after a reset).
  final Map<String, String> passwords = {};

  /// email -> the latest password reset code "emailed" to it. Only tests read this.
  final Map<String, String> resetInbox = {};

  /// Every email a reset code was sent to, in order.
  final List<String> resetCodeEmails = [];

  /// Reset codes that the next verification should treat as expired.
  final Set<String> expiredResetCodes = {};

  /// Live reset tokens -> the email they reset. Removed once used.
  final Map<String, String> resetTokens = {};

  /// When true, POST /api/auth/reset-password treats every token as expired.
  bool resetTokensExpired = false;

  /// Bodies POSTed to the password reset endpoints.
  final List<Map<String, dynamic>> forgotRequests = [];
  final List<Map<String, dynamic>> resendResetRequests = [];
  final List<Map<String, dynamic>> verifyResetRequests = [];
  final List<Map<String, dynamic>> resetPasswordRequests = [];

  /// When set, POST /api/auth/verify-reset-code waits for this before answering.
  Completer<void>? verifyResetPending;

  int _nextResetToken = 1;

  static const resetRequested = 'If an account exists for this email, a password reset code has been sent.';
  static const invalidResetCode =
      'This code is invalid or has expired. Check your latest email or request a new code.';
  static const invalidResetToken = 'Your password reset session has expired. Please request a new code.';

  void _sendResetCode(String email) {
    final code = (731402 + 6113 * _nextCode++).remainder(1000000).toString().padLeft(6, '0');
    resetInbox[email] = code;
    resetCodeEmails.add(email);
  }

  /// Like the server: only accounts with a password get a code; the answer is always the same.
  http.Response _requestReset(Map<String, dynamic> body) {
    final user = users.values.where((u) => u['email'] == body['email']).firstOrNull;
    if (user != null && !passwordless.contains(user['id'])) _sendResetCode(body['email'] as String);
    return _json(200, {'message': resetRequested});
  }

  void _sendCode(String email) {
    // Deterministic but varied codes.
    final code = (482913 + 7919 * _nextCode++).remainder(1000000).toString().padLeft(6, '0');
    inbox[email] = code;
    codeEmails.add(email);
  }

  static const invalidCode =
      'This code is invalid or has expired. Check your latest email or request a new code.';

  late final MockClient client = MockClient(_handle);

  /// The notification endpoints: history, devices, preferences and tracking reports.
  final notificationsBackend = FakeNotificationsBackend();

  AppServices services(
    PermissionService permissionService, {
    GoogleAuthService? googleAuthService,
    LocationProvider? locationProvider,
    PlaceLookup? placeLookup,
    BackgroundLocationSource? backgroundLocationSource,
    PhotoLibrary? photoLibrary,
    DocumentPlatform? documentPlatform,
    ContactsSource? contactsSource,
    MessageHandoff? messageHandoff,
    VoiceInput? voiceInput,
    TextToSpeechService? textToSpeech,
    ProfilePhotoPlatform? profilePhotoPlatform,
    PushPlatform? pushPlatform,
    WakeWordPlatform? wakeWordPlatform,
  }) =>
      AppServices.create(
        apiClient: ApiClient(baseUrl: 'http://test', httpClient: client),
        tokenStorage: TokenStorage(),
        googleAuthService: googleAuthService ?? FakeGoogleAuthService(),
        permissionService: permissionService,
        locationProvider: locationProvider ?? FakeLocationProvider(),
        placeLookup: placeLookup ?? FakePlaceLookup(),
        backgroundLocationSource: backgroundLocationSource ?? FakeBackgroundLocationSource(),
        photoLibrary: photoLibrary ?? FakePhotoLibrary(),
        documentPlatform: documentPlatform ?? FakeDocumentPlatform(),
        contactsSource: contactsSource ?? FakeContactsSource(),
        messageHandoff: messageHandoff ?? FakeMessageHandoff(),
        voiceInput: voiceInput ?? FakeVoiceInput(),
        textToSpeech: textToSpeech ?? FakeTextToSpeech(),
        profilePhotoPlatform: profilePhotoPlatform ?? FakeProfilePhotoPlatform(),
        pushPlatform: pushPlatform ?? FakePushPlatform(),
        wakeWordPlatform: wakeWordPlatform ?? FakeWakeWordPlatform(),
      );

  Future<http.Response> _handle(http.Request req) async {
    if (offline) throw http.ClientException('Network is unreachable');
    final path = req.url.path;

    if (path == '/api/auth/login') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final user = users.values.where((u) => u['email'] == body['email']).firstOrNull;
      if (user != null && passwordless.contains(user['id'])) {
        return _json(401, {
          'message': 'This account uses Google Sign-In. Please continue with Google.',
          'code': 'USE_GOOGLE_SIGN_IN',
        });
      }
      if (user == null || body['password'] != (passwords[user['email']] ?? testPassword)) {
        return _json(401, {'message': 'Invalid email or password'});
      }
      if (unverified.contains(user['id'])) {
        // Like the server: the right password on an unverified account gets a fresh code, no JWT.
        _sendCode(user['email'] as String);
        return _json(403, {
          'requiresEmailVerification': true,
          'code': 'EMAIL_NOT_VERIFIED',
          'message': 'Please verify your email before logging in.',
        });
      }
      return _json(200, {'message': 'Login successful', 'user': _authUser(user), 'token': tokenFor(user['id'])});
    }

    if (path == '/api/auth/register') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final email = body['email'] as String;
      final existing = users.values.where((u) => u['email'] == email).firstOrNull;
      // The same answer whether or not the email is taken; only unverified accounts get a code.
      if (existing == null) {
        final id = addUser(body['name'] as String, email);
        unverified.add(id);
        _sendCode(email);
      } else if (unverified.contains(existing['id'])) {
        _sendCode(email);
      }
      return _json(201, {'requiresEmailVerification': true, 'message': 'Verification code sent to your email.'});
    }

    if (path == '/api/auth/verify-email') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      verifyRequests.add(body);
      if (verifyPending != null) await verifyPending!.future;
      if (body.keys.toSet().difference({'email', 'code'}).isNotEmpty) {
        return _json(400, {'message': 'Validation failed'});
      }
      final email = body['email'] as String;
      final code = inbox[email];
      final user = users.values.where((u) => u['email'] == email).firstOrNull;
      if (user == null || code == null || body['code'] != code || expiredCodes.contains(code)) {
        return _json(400, {'message': invalidCode, 'code': 'INVALID_VERIFICATION_CODE'});
      }
      inbox.remove(email);
      unverified.remove(user['id']);
      return _json(200, {'verified': true, 'message': 'Email verified successfully.'});
    }

    if (path == '/api/auth/resend-verification') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      resendRequests.add(body);
      final user = users.values.where((u) => u['email'] == body['email']).firstOrNull;
      if (user != null && unverified.contains(user['id'])) _sendCode(body['email'] as String);
      return _json(200, {'message': 'If verification is required, a new code has been sent.'});
    }

    if (path == '/api/auth/forgot-password') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      forgotRequests.add(body);
      return _requestReset(body);
    }

    if (path == '/api/auth/resend-reset-code') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      resendResetRequests.add(body);
      return _requestReset(body);
    }

    if (path == '/api/auth/verify-reset-code') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      verifyResetRequests.add(body);
      if (verifyResetPending != null) await verifyResetPending!.future;
      final email = body['email'] as String;
      final code = resetInbox[email];
      if (code == null || body['code'] != code || expiredResetCodes.contains(code)) {
        return _json(400, {'message': invalidResetCode, 'code': 'INVALID_RESET_CODE'});
      }
      resetInbox.remove(email);
      final token = 'reset-token-${_nextResetToken++}';
      resetTokens[token] = email;
      return _json(200, {
        'message': 'Code verified. You can now create a new password.',
        'resetToken': token,
        'expiresInSeconds': 600,
      });
    }

    if (path == '/api/auth/reset-password') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      resetPasswordRequests.add(body);
      final password = body['newPassword'] as String? ?? '';
      if (password.length < 8) {
        return _json(400, {
          'message': 'Validation failed',
          'errors': [
            {'field': 'newPassword', 'message': 'Password must be at least 8 characters'},
          ],
        });
      }
      if (body['confirmPassword'] != null && body['confirmPassword'] != password) {
        return _json(400, {
          'message': 'Validation failed',
          'errors': [
            {'field': 'confirmPassword', 'message': 'Passwords do not match'},
          ],
        });
      }
      final email = resetTokens.remove(body['resetToken']);
      if (email == null || resetTokensExpired) {
        return _json(400, {'message': invalidResetToken, 'code': 'INVALID_RESET_TOKEN'});
      }
      passwords[email] = password;
      return _json(200, {'message': 'Password reset successfully.'});
    }

    if (path == '/api/auth/google') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      // Like the server: only the token is accepted, and identity comes from it alone.
      if (body.keys.length != 1 || body['idToken'] is! String) {
        return _json(400, {'message': 'Validation failed'});
      }
      final idToken = body['idToken'] as String;
      googleTokens.add(idToken);
      final claims = validGoogleTokens[idToken];
      if (claims == null) {
        return _json(401, {'message': 'Google authentication failed.', 'code': 'GOOGLE_AUTH_FAILED'});
      }
      final linkedId = googleSubjects.entries.where((e) => e.value == claims.sub).firstOrNull?.key;
      if (linkedId != null) {
        final user = users[linkedId]!;
        return _json(200, {'message': 'Login successful', 'user': _authUser(user), 'token': tokenFor(linkedId)});
      }
      if (users.values.any((u) => u['email'] == claims.email)) {
        return _json(409, {
          'message': 'An account already exists with this email. Please sign in with your password '
              'first, then use the account-linking option.',
          'code': 'ACCOUNT_EXISTS_WITH_PASSWORD',
        });
      }
      final id = addUser(claims.name, claims.email);
      googleSubjects[id] = claims.sub;
      passwordless.add(id);
      return _json(200, {'message': 'Login successful', 'user': _authUser(users[id]!), 'token': tokenFor(id)});
    }

    final userId = _userFromToken(req.headers['Authorization']);
    if (userId == null) return _json(401, {'message': 'Invalid or expired token'});
    final user = users[userId]!;

    if (path == '/api/auth/me') return _json(200, {'user': _authUser(user)});
    if (path == '/api/auth/logout') return _json(200, {'message': 'Logout successful'});

    if (path == '/api/profile' && req.method == 'GET') {
      if (profileFailures > 0) {
        profileFailures--;
        return _json(503, {'message': 'Service unavailable'});
      }
      return _json(200, {'user': user});
    }
    if (path == '/api/profile/permission-onboarding' && req.method == 'PATCH') {
      if (onboardingFailures > 0) {
        onboardingFailures--;
        return _json(503, {'message': 'Service unavailable'});
      }
      final body = jsonDecode(req.body);
      if (body is! Map || body.length != 1 || body['completed'] is! bool) {
        return _json(400, {'message': 'Validation failed'});
      }
      patches.add('PATCH /api/profile/permission-onboarding ${body['completed']} ($userId)');
      user['permissionOnboardingCompleted'] = body['completed'];
      return _json(200, {'user': user});
    }
    if (path == '/api/profile' && req.method == 'PATCH') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final name = (body['name'] as String?)?.trim() ?? '';
      if (name.isEmpty || name.length > 100) {
        return _json(400, {
          'message': 'Validation failed',
          'errors': [
            {'field': 'name', 'message': 'Name cannot be empty'},
          ],
        });
      }
      patches.add('PATCH /api/profile $name ($userId)');
      user['name'] = name;
      return _json(200, {'user': user});
    }

    if (path == '/api/permissions' && req.method == 'GET') {
      final stored = permissions[userId] ?? {};
      return _json(200, {
        'permissions': [
          for (final p in supportedPermissions) {'permission': p, 'status': stored[p] ?? 'UNKNOWN'},
        ],
      });
    }
    if (path.startsWith('/api/permissions/') && req.method == 'PATCH') {
      if (permissionFailures > 0) {
        permissionFailures--;
        return _json(503, {'message': 'Service unavailable'});
      }
      final permission = path.substring('/api/permissions/'.length);
      final status = (jsonDecode(req.body) as Map<String, dynamic>)['status'];
      if (!supportedPermissions.contains(permission) || !supportedStatuses.contains(status)) {
        return _json(400, {'message': 'Validation failed'});
      }
      patches.add('PATCH /api/permissions/$permission $status ($userId)');
      (permissions[userId] ??= {})[permission] = status as String;
      return _json(200, {'permission': permission, 'status': status});
    }

    if (path == '/api/location/tracking-status' && req.method == 'POST') {
      return notificationsBackend.tracking(req, userId);
    }
    if (path.startsWith('/api/notifications')) return notificationsBackend.handle(req, userId);
    if (path.startsWith('/api/location')) {
      if (path == '/api/location/history' && req.method == 'GET') await historyGate?.future;
      return _handleLocation(req, userId);
    }
    if (path.startsWith('/api/chat')) return _handleChat(req, userId);

    return _json(404, {'message': 'Not found'});
  }

  http.Response _handleLocation(http.Request req, String userId) {
    if (locationFailureStatus != null) {
      return _json(locationFailureStatus!, {'message': 'Internal server error'});
    }
    final mine = locations[userId] ??= [];
    final path = req.url.path;

    if (path == '/api/location' && req.method == 'POST') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      locationPosts.add(body);
      const allowed = {'latitude', 'longitude', 'accuracy', 'capturedAt', 'source', ...placeKeys};
      if (body.keys.any((k) => !allowed.contains(k))) return _json(400, {'message': 'Validation failed'});
      final lat = body['latitude'], lng = body['longitude'];
      if (lat is! num || lat.abs() > 90) return _json(400, {'message': 'Validation failed'});
      if (lng is! num || lng.abs() > 180) return _json(400, {'message': 'Validation failed'});
      final source = body['source'] ?? 'MANUAL';
      if (source != 'MANUAL' && source != 'AUTOMATIC') return _json(400, {'message': 'Validation failed'});
      // Like the server: an automatic point within 100 m and 5 minutes of one already saved is skipped.
      if (source == 'AUTOMATIC') {
        final at = DateTime.parse(body['capturedAt'] as String);
        final point = TrackedPoint(latitude: lat.toDouble(), longitude: lng.toDouble(), capturedAt: at);
        final duplicate = mine.any((l) {
          final other = TrackedPoint(
            latitude: (l['latitude'] as num).toDouble(),
            longitude: (l['longitude'] as num).toDouble(),
            capturedAt: DateTime.parse(l['capturedAt'] as String),
          );
          return at.difference(other.capturedAt).abs() < const Duration(minutes: 5) &&
              distanceBetween(point, other) < 100;
        });
        if (duplicate) return _json(200, {'saved': false, 'reason': 'duplicate'});
      }
      final record = {
        'id': 'loc${_nextLocationId++}',
        'latitude': lat,
        'longitude': lng,
        'accuracy': body['accuracy'],
        for (final key in placeKeys) key: body[key],
        'capturedAt': body['capturedAt'],
        'source': source,
      };
      mine.add(record);
      if (dropNextLocationResponse) {
        dropNextLocationResponse = false;
        throw http.ClientException('Connection reset');
      }
      return _json(201, {'saved': true, 'location': record});
    }
    if (path == '/api/location/history' && req.method == 'GET') {
      final query = req.url.queryParameters;
      historyQueries.add(Map.of(query));
      if (query.containsKey('userId')) return _json(400, {'message': 'Validation failed'});
      // Like the server: at most 50, and a date search covers whole local days, oldest first.
      final limit = math.min(int.tryParse(query['limit'] ?? '50') ?? 50, 50);
      var matches = mine.reversed.toList();
      final source = query['source'];
      if (source != null) matches = matches.where((l) => l['source'] == source).toList();
      final start = query['startDate'];
      if (start != null) {
        final end = query['endDate'] ?? start;
        final days = RegExp(r'^\d{4}-\d{2}-\d{2}$');
        if (!days.hasMatch(start) || !days.hasMatch(end)) {
          return _json(400, {'message': 'Invalid date. Use the format YYYY-MM-DD.'});
        }
        if (end.compareTo(start) < 0) return _json(400, {'message': 'Invalid date range.'});
        final offset = Duration(minutes: int.parse(query['utcOffsetMinutes'] ?? '0'));
        String localDay(Map<String, dynamic> l) =>
            DateTime.parse(l['capturedAt'] as String).toUtc().add(offset).toIso8601String().substring(0, 10);
        matches = matches.where((l) => localDay(l).compareTo(start) >= 0 && localDay(l).compareTo(end) <= 0).toList()
          ..sort((a, b) => (a['capturedAt'] as String).compareTo(b['capturedAt'] as String));
      }
      return _json(200, {'locations': matches.take(limit).toList(), 'hasMore': matches.length > limit});
    }
    if (path == '/api/location/history' && req.method == 'DELETE') {
      final deleted = mine.length;
      mine.clear();
      return _json(200, {'deleted': deleted});
    }
    return _json(404, {'message': 'Not found'});
  }

  String _tick() => (_chatClock = _chatClock.add(const Duration(minutes: 1))).toIso8601String();

  Map<String, dynamic> _newConversation(String userId, String? title) {
    final now = _tick();
    final conversation = <String, dynamic>{
      'id': 'conv${_nextChatId++}',
      'title': title,
      'createdAt': now,
      'updatedAt': now,
      'messages': <Map<String, dynamic>>[],
    };
    (chats[userId] ??= []).add(conversation);
    return conversation;
  }

  static Map<String, dynamic> _publicConversation(Map<String, dynamic> c) =>
      {for (final e in c.entries) if (e.key != 'messages') e.key: e.value};

  Future<http.Response> _handleChat(http.Request req, String userId) async {
    final path = req.url.path;
    final mine = chats[userId] ??= [];
    Map<String, dynamic>? find(String id) => mine.where((c) => c['id'] == id).firstOrNull;

    if (path == '/api/chat' && req.method == 'POST') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      chatRequests.add(body);
      final wait = chatPending;
      chatPending = null;
      if (wait != null) await wait.future;
      if (body.containsKey('userId')) return _json(400, {'message': 'Validation failed'});
      if (chatFailures.isNotEmpty) {
        final status = chatFailures.removeAt(0);
        return _json(status, {'message': 'Child Assist is unavailable right now.', 'code': 'AI_UNAVAILABLE'});
      }
      final message = (body['message'] as String).trim();
      final conversationId = body['conversationId'] as String?;
      final conversation = conversationId == null ? _newConversation(userId, null) : find(conversationId);
      if (conversation == null) return _json(404, {'message': 'Conversation not found'});

      final reply = (chatResponder ?? FakeChatReply.standard)(message);
      final messages = conversation['messages'] as List<Map<String, dynamic>>;
      final userMessage = {'id': 'm${_nextChatId++}', 'role': 'CHAT_USER', 'content': message, 'createdAt': _tick()};
      final assistant = {'id': 'm${_nextChatId++}', 'role': 'CHAT_ASSISTANT', 'content': reply.text, 'createdAt': _tick()};
      messages.addAll([userMessage, assistant]);
      // A question about a document opens a read request, as on the real server.
      for (final event in reply.toolEvents) {
        final data = event['data'];
        if (event['kind'] == 'photos' && data is Map && data['requestId'] is String) {
          photoSearchStore[data['requestId'] as String] = {'userId': userId, 'conversationId': conversation['id'], 'status': 'PENDING'};
        }
        if (event['kind'] == 'photo_analysis' && data is Map && data['requestId'] is String) {
          photoAnalysisStore[data['requestId'] as String] = {
            'userId': userId,
            'conversationId': conversation['id'],
            'status': 'PENDING',
            'photoId': data['photoId'],
          };
        }
        if (event['kind'] == 'document_text' && data is Map && data['requestId'] is String) {
          documentReadStore[data['requestId'] as String] = {
            'userId': userId,
            'conversationId': conversation['id'],
            'status': 'PENDING',
          };
        }
      }
      for (final action in reply.pendingActions) {
        chatActionStore[action['id'] as String] = {
          'status': 'PENDING',
          'channel': 'EMAIL',
          ...action,
          'userId': userId,
          'conversationId': conversation['id'],
        };
      }
      conversation['title'] ??= reply.title ?? message.split(' ').take(4).join(' ');
      conversation['updatedAt'] = assistant['createdAt'];
      return _json(200, {
        'conversationId': conversation['id'],
        'title': conversation['title'],
        'response': reply.text,
        'userMessage': userMessage,
        'message': assistant,
        'pendingActions': reply.pendingActions,
        'toolsUsed': const [],
        'toolEvents': reply.toolEvents,
        'guardrail': null,
      });
    }
    if (path == '/api/chat/conversations' && req.method == 'POST') {
      return _json(201, {'conversation': _publicConversation(_newConversation(userId, null))});
    }
    if (path == '/api/chat/conversations' && req.method == 'GET') {
      final sorted = [...mine]..sort((a, b) => (b['updatedAt'] as String).compareTo(a['updatedAt'] as String));
      return _json(200, {'conversations': [for (final c in sorted) _publicConversation(c)]});
    }
    if (path.startsWith('/api/chat/conversations/')) {
      final conversation = find(path.substring('/api/chat/conversations/'.length));
      if (conversation == null) return _json(404, {'message': 'Conversation not found'});
      if (req.method == 'GET') {
        return _json(200, {'conversation': _publicConversation(conversation), 'messages': conversation['messages']});
      }
      if (req.method == 'DELETE') {
        mine.remove(conversation);
        return _json(200, {'success': true});
      }
    }
    final read = RegExp(r'^/api/chat/document-reads/([^/]+)/(answer|fail)$').firstMatch(path);
    if (read != null && req.method == 'POST') {
      return _handleDocumentRead(read.group(1)!, read.group(2)!, req.body.isEmpty ? {} : jsonDecode(req.body), userId);
    }
    final search = RegExp(r'^/api/chat/photo-searches/([^/]+)/results$').firstMatch(path);
    if (search != null && req.method == 'POST') {
      return _handlePhotoSearch(search.group(1)!, req.body.isEmpty ? {} : jsonDecode(req.body), userId);
    }
    final select = RegExp(r'^/api/chat/photos/([^/]+)/select$').firstMatch(path);
    if (select != null && req.method == 'POST') {
      final photo = photoStore[select.group(1)];
      photoCalls.add('select ${select.group(1)}');
      if (photo == null || photo['userId'] != userId) return _json(404, {'message': 'Photo not found'});
      photo['selected'] = true;
      return _json(200, {'photo': {'id': select.group(1), 'selected': true}});
    }
    final analysis = RegExp(r'^/api/chat/photo-analyses/([^/]+)/(answer|fail)$').firstMatch(path);
    if (analysis != null && req.method == 'POST') {
      return _handlePhotoAnalysis(analysis.group(1)!, analysis.group(2)!, req.body.isEmpty ? {} : jsonDecode(req.body), userId);
    }
    final action =
        RegExp(r'^/api/chat/actions/([^/]+)/(recipient|shared-contact|document|confirm|cancel|handoff)$').firstMatch(path);
    if (action != null && req.method == 'POST') {
      return _handleAction(action.group(1)!, action.group(2)!, req.body.isEmpty ? {} : jsonDecode(req.body), userId);
    }
    return _json(404, {'message': 'Not found'});
  }

  /// Photo searches and analyses opened by chat turns, and the photos the phone reported, by id.
  final Map<String, Map<String, dynamic>> photoSearchStore = {};
  final Map<String, Map<String, dynamic>> photoAnalysisStore = {};
  final Map<String, Map<String, dynamic>> photoStore = {};

  /// Every photo call ("results r1 found", "select photo_...", "answer a1", "fail a1 unavailable"),
  /// and every body the phone sent for searches and analyses.
  final List<String> photoCalls = [];
  final List<Map<String, dynamic>> photoBodies = [];

  /// The image bytes the phone sent for each analysis, in order.
  final List<Uint8List> analysedImages = [];

  /// Answers from the image the phone sent, like Gemini vision would from the real image. The
  /// default names the image's size, so tests can tell the answer came from that image.
  String Function(Uint8List image) photoAnswerer = (image) => 'This photo shows an image of ${image.length} bytes.';

  /// When true, the vision model fails like Vertex AI being down.
  bool photoVisionFails = false;

  int _nextPhotoId = 1;

  Map<String, dynamic> _note(String userId, String conversationId, String content) {
    final m = {'id': 'm${_nextChatId++}', 'role': 'CHAT_ASSISTANT', 'content': content, 'createdAt': _tick()};
    final conversation = chats[userId]!.firstWhere((c) => c['id'] == conversationId);
    (conversation['messages'] as List<Map<String, dynamic>>).add(m);
    return m;
  }

  /// Like the server: only metadata of shown photos (never a path, URI or file name), owner only,
  /// answered once; each shown photo gets an opaque id.
  http.Response _handlePhotoSearch(String id, Map<String, dynamic> body, String userId) {
    photoCalls.add('results $id ${body['outcome']}');
    photoBodies.add(body);
    final r = photoSearchStore[id];
    if (r == null || r['userId'] != userId) return _json(404, {'message': 'Request not found'});
    const allowed = {'outcome', 'photos', 'total', 'reason', 'limited', 'conversationId'};
    const photoKeys = {'capturedAt', 'width', 'height', 'place'};
    final photos = (body['photos'] as List? ?? const []).cast<Map<String, dynamic>>();
    if (body.keys.any((k) => !allowed.contains(k)) || photos.any((p) => p.keys.any((k) => !photoKeys.contains(k)))) {
      return _json(400, {'message': 'Validation failed'});
    }
    if (r['status'] != 'PENDING') return _json(409, {'message': 'This request has already been handled.'});
    r['status'] = 'COMPLETED';
    final ids = <String>[];
    for (var i = 0; i < photos.length; i++) {
      final photoId = 'photo_${(_nextPhotoId++).toRadixString(16).padLeft(20, '0')}';
      photoStore[photoId] = {'userId': userId, 'conversationId': r['conversationId'], 'selected': photos.length == 1};
      ids.add(photoId);
    }
    final note = switch (body['outcome']) {
      'found' when photos.length == 1 => 'I found a matching photo.',
      'found' => 'I found ${photos.length} matching photos. Which one would you like?',
      'permission_denied' => "I can't access your photos because Photos permission is turned off.",
      'failed' => "I couldn't read the photos on your phone right now. Please try again.",
      _ => "I couldn't find a matching photo in your available photos.",
    };
    return _json(200, {
      'photos': [for (final i in ids) {'id': i, 'selected': photos.length == 1}],
      'message': _note(userId, r['conversationId'] as String, note),
    });
  }

  http.Response _handlePhotoAnalysis(String id, String verb, Map<String, dynamic> body, String userId) {
    photoCalls.add(verb == 'fail' ? 'fail $id ${body['reason']}' : 'answer $id');
    photoBodies.add(body);
    final r = photoAnalysisStore[id];
    if (r == null || r['userId'] != userId) return _json(404, {'message': 'Request not found'});
    if (r['status'] != 'PENDING') return _json(409, {'message': 'This request has already been handled.'});
    final conversationId = r['conversationId'] as String;
    if (verb == 'fail') {
      const messages = {
        'not_found': "I couldn't find that photo on your phone, so I couldn't look at it.",
        'unavailable': 'This photo is no longer available on your device.',
        'permission': "I can't access your photos because Photos permission is turned off.",
        'unsupported': "I can't read this type of image.",
        'too_large': 'This image is too large for me to look at.',
        'cancelled': "Okay, I didn't look at the photo.",
      };
      r['status'] = 'FAILED';
      return _json(200, {'message': _note(userId, conversationId, messages[body['reason']] ?? '')});
    }
    const allowed = {'photoId', 'image', 'conversationId'};
    if (body.keys.any((k) => !allowed.contains(k)) || body['photoId'] != r['photoId'] || body['image'] is! String) {
      return _json(400, {'message': 'Validation failed'});
    }
    if (photoVisionFails) {
      r['status'] = 'FAILED';
      return _json(503, {
        'message': "Sorry, I couldn't look at the photo right now. Please try again in a moment.",
        'code': 'AI_UNAVAILABLE',
      });
    }
    final image = base64Decode(body['image'] as String);
    analysedImages.add(image);
    r['status'] = 'COMPLETED';
    return _json(200, {'message': _note(userId, conversationId, photoAnswerer(image))});
  }

  /// Read requests opened by document questions, by id.
  final Map<String, Map<String, dynamic>> documentReadStore = {};

  /// Every document-read call, e.g. "answer r1" or "fail r1 unavailable", and its body.
  final List<String> documentReadCalls = [];
  final List<Map<String, dynamic>> documentReadBodies = [];

  /// Writes the answer from the text the phone sent, like the model would from the real text.
  /// The default quotes the document's first line, so tests can tell the answer came from it.
  String Function(Map<String, dynamic> body) documentAnswerer =
      (body) => 'This document starts with: ${(body['text'] as String).trim().split('\n').first}';

  /// The document-read endpoints with the real server's rules: owner only, a strict body (an
  /// opaque id, a name, a type and the text; never a path or URI), answered once.
  http.Response _handleDocumentRead(String id, String verb, Map<String, dynamic> body, String userId) {
    documentReadCalls.add(verb == 'fail' ? 'fail $id ${body['reason']}' : 'answer $id');
    documentReadBodies.add(body);
    final r = documentReadStore[id];
    if (r == null || r['userId'] != userId) return _json(404, {'message': 'Request not found'});
    if (body['conversationId'] != null && body['conversationId'] != r['conversationId']) {
      return _json(404, {'message': 'Request not found'});
    }
    if (r['status'] != 'PENDING') {
      return _json(409, {'message': 'This request has already been handled.', 'code': 'REQUEST_ALREADY_HANDLED'});
    }
    Map<String, dynamic> message(String content) {
      final m = {'id': 'm${_nextChatId++}', 'role': 'CHAT_ASSISTANT', 'content': content, 'createdAt': _tick()};
      final conversation = chats[userId]!.firstWhere((c) => c['id'] == r['conversationId']);
      (conversation['messages'] as List<Map<String, dynamic>>).add(m);
      return m;
    }

    if (verb == 'fail') {
      const messages = {
        'not_found': "I couldn't find that document on your phone, so I couldn't read it.",
        'unavailable': 'This document is no longer available, so I couldn\'t read it.',
        'unsupported': "I can't read the text of this type of document yet. You can still open it from Documents.",
        'no_text': "I couldn't find any readable text in this document.",
        'encrypted': 'This document is password-protected, so I couldn\'t read it.',
        'unreadable': "I couldn't read this document.",
        'cancelled': "Okay, I didn't read the document.",
      };
      final text = messages[body['reason']];
      if (text == null || body.keys.any((k) => !const {'reason', 'conversationId'}.contains(k))) {
        return _json(400, {'message': 'Validation failed'});
      }
      r['status'] = body['reason'] == 'cancelled' ? 'CANCELLED' : 'FAILED';
      return _json(200, {'request': {'id': id, 'status': r['status']}, 'message': message(text)});
    }

    const allowed = {'documentId', 'name', 'type', 'text', 'truncated', 'conversationId'};
    final text = body['text'];
    if (body.keys.any((k) => !allowed.contains(k)) ||
        !RegExp(r'^doc_[a-z0-9]{4,60}$').hasMatch(body['documentId'] as String? ?? '') ||
        !const {'PDF', 'DOC', 'DOCX', 'TXT'}.contains(body['type']) ||
        text is! String ||
        text.trim().isEmpty ||
        text.length > 150000) {
      return _json(400, {'message': 'Validation failed'});
    }
    r['status'] = 'COMPLETED';
    return _json(200, {'request': {'id': id, 'status': 'COMPLETED'}, 'message': message(documentAnswerer(body))});
  }

  /// The action endpoints with the real server's rules: owner only, set the recipient once,
  /// confirm and cancel once, WhatsApp is only ever "opened", never sent.
  http.Response _handleAction(String id, String verb, Map<String, dynamic> body, String userId) {
    final result = body['result'];
    chatActions.add(result == null ? '$verb $id' : '$verb $id $result');
    chatActionBodies.add(body);
    final a = chatActionStore[id];
    if (a == null || a['userId'] != userId) return _json(404, {'message': 'Action not found'});
    if (body.containsKey('userId')) return _json(400, {'message': 'Validation failed'});
    if (body['conversationId'] != null && body['conversationId'] != a['conversationId']) {
      return _json(404, {'message': 'Action not found'});
    }
    final email = a['channel'] != 'WHATSAPP';
    final name = (a['recipientName'] ?? a['contactQuery']) as String?;
    http.Response view([String outcome = '', Map<String, dynamic>? handoff]) => _json(200, {
      'action': {
        for (final e in a.entries)
          if (e.key != 'userId') e.key: e.value,
        'outcomeMessage': outcome,
        'handoff': ?handoff,
      },
    });
    const handled = {'message': 'This action has already been handled', 'code': 'ACTION_ALREADY_HANDLED'};
    final document = a['type'] == 'SHARE_DOCUMENT';
    String documentSummary() {
      final who = a['recipientName'] == null
          ? (a['contactQuery'] ?? 'this contact')
          : a['recipientAddress'] == null
              ? a['recipientName']
              : '${a['recipientName']} (${a['recipientAddress']})';
      return 'Do you want to share this document with $who on WhatsApp?';
    }

    switch (verb) {
      case 'document':
        // Like the real server: only for SHARE_DOCUMENT, set once, and only an opaque id, a file
        // name and a type are accepted (never a path or URI).
        if (!document) return _json(404, {'message': 'Action not found'});
        if (a['status'] != 'PENDING') return _json(409, handled);
        if (a['documentId'] != null) {
          return _json(409, {'message': 'The document has already been chosen.', 'code': 'DOCUMENT_ALREADY_SET'});
        }
        final documentId = body['documentId'] as String? ?? '';
        final documentName = (body['name'] as String? ?? '').trim();
        if (!RegExp(r'^doc_[a-z0-9]{4,60}$').hasMatch(documentId) ||
            documentName.isEmpty ||
            RegExp(r'[/\\<>"\x00-\x1f]').hasMatch(documentName) ||
            !const {'PDF', 'DOC', 'DOCX', 'TXT'}.contains(body['type'])) {
          return _json(400, {'message': 'Validation failed'});
        }
        a['documentId'] = documentId;
        a['documentName'] = documentName;
        a['documentType'] = body['type'];
        a['dataSummary'] = 'Document: $documentName';
        return view();
      case 'shared-contact':
        // Like the real server: only for SHARE_CONTACT, set once, and the message is built here
        // from the picked name and number. The recipient is never touched.
        if (a['type'] != 'SHARE_CONTACT') return _json(404, {'message': 'Action not found'});
        if (a['status'] != 'PENDING') return _json(409, handled);
        if (a['sharedContactPhone'] != null) return _json(409, {'message': 'The contact to share has already been chosen.'});
        final phone = (body['phone'] as String? ?? '').trim();
        final contactName = (body['name'] as String? ?? '').trim();
        if (phone.replaceAll(RegExp(r'\D'), '').length < 7 || contactName.isEmpty) {
          return _json(400, {'message': "That phone number doesn't look right."});
        }
        a['sharedContactName'] = contactName;
        a['sharedContactPhone'] = phone;
        a['message'] = "Here is $contactName's phone number: $phone";
        a['dataSummary'] = "$contactName's phone number";
        return view();
      case 'recipient':
        if (a['status'] != 'PENDING') return _json(409, handled);
        if (a['recipientAddress'] != null) return _json(409, {'message': 'The recipient has already been chosen.'});
        final address = (body['address'] as String? ?? '').trim();
        final valid = email
            ? RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(address)
            : address.replaceAll(RegExp(r'\D'), '').length >= 7;
        if (!valid) {
          return _json(400, {'message': email ? "That email address doesn't look right." : "That phone number doesn't look right."});
        }
        a['recipientAddress'] = address;
        a['recipientName'] = body['name'] ?? name;
        final who = a['recipientName'] == null ? address : email ? '${a['recipientName']} <$address>' : '${a['recipientName']} ($address)';
        final via = email ? 'by email' : 'on WhatsApp';
        a['summary'] = switch (a['type']) {
          'SHARE_LOCATION' => 'Share your location with $who $via?',
          'SHARE_TRAVEL_HISTORY' => 'Share your travel history with $who $via?',
          'SHARE_DOCUMENT' => documentSummary(),
          _ => email ? 'Send an email to $who?' : 'Send this WhatsApp message to $who?',
        };
        return view();
      case 'confirm':
        if (a['status'] != 'PENDING') return _json(409, handled);
        if (a['type'] == 'SHARE_CONTACT' && a['sharedContactPhone'] == null) {
          return _json(409, {'message': 'Choose whose number to share first.', 'code': 'SHARED_CONTACT_REQUIRED'});
        }
        if (document && a['documentId'] == null) {
          return _json(409, {'message': 'Choose which document to share first.', 'code': 'DOCUMENT_REQUIRED'});
        }
        if (a['recipientAddress'] == null) return _json(409, {'message': 'Choose who to send it to first.'});
        if (email) {
          if (emailFails) {
            a['status'] = 'FAILED';
            return view("Sorry, I couldn't send the email to $name. Nothing was delivered.");
          }
          sentEmails.add({'to': a['recipientAddress'] as String?, 'subject': a['subject'] as String?, 'message': a['message'] as String?});
          a['status'] = 'COMPLETED';
          return view('Email sent to ${a['recipientName'] ?? name}.');
        }
        a['status'] = 'CONFIRMED';
        return view('Opening WhatsApp...', {
          'phone': a['recipientAddress'],
          'message': a['message'] ?? '',
          'documentQuery': a['documentQuery'],
          'documentId': a['documentId'],
          'photoId': a['photoId'],
        });
      case 'cancel':
        if (a['status'] != 'PENDING' && a['status'] != 'CONFIRMED') return _json(409, handled);
        a['status'] = 'CANCELLED';
        return view(document ? "Okay, I didn't share the document." : "Okay, I didn't send anything.");
      case 'handoff':
        if (a['status'] != 'CONFIRMED' || email) return _json(409, handled);
        if (result == 'unavailable') return view("WhatsApp isn't available on this device.");
        a['status'] = 'COMPLETED';
        if (a['type'] == 'SHARE_PHOTO') {
          return view(result == 'whatsapp_opened'
              ? 'WhatsApp opened. Tap Send to complete it.'
              : 'Share options opened. Nothing is sent until you send the photo from the app you choose.');
        }
        if (document) {
          return view(result == 'whatsapp_opened'
              ? 'WhatsApp opened. Please tap Send to send the document.'
              : 'Share options opened. Nothing is sent until you send the document from the app you choose.');
        }
        return view(result == 'whatsapp_opened'
            ? 'WhatsApp opened for ${a['recipientName']} with your message. Tap Send in WhatsApp to deliver it.'
            : 'Share options opened for ${a['recipientName']}. Nothing is sent until you send it from the app you choose.');
    }
    return _json(404, {'message': 'Not found'});
  }

  String? _userFromToken(String? header) {
    final token = header?.replaceFirst('Bearer ', '');
    for (final id in users.keys) {
      if (token == tokenFor(id)) return id;
    }
    return null;
  }

  static Map<String, dynamic> _authUser(Map<String, dynamic> u) =>
      {'id': u['id'], 'name': u['name'], 'email': u['email']};

  static http.Response _json(int status, Object body) => http.Response(jsonEncode(body), status,
      headers: {'content-type': 'application/json'});
}

/// Stands in for Google's account picker. [nextIdToken] is the ID token of the account the user
/// picks; [nextError] makes the picker fail instead (e.g. the user cancels).
class FakeGoogleAuthService implements GoogleAuthService {
  FakeGoogleAuthService({this.isAvailable = true});

  @override
  final bool isAvailable;

  String? nextIdToken;
  GoogleAuthException? nextError;
  int signInCalls = 0;
  int signOutCalls = 0;

  /// When set, the picker stays open until this completes.
  Completer<void>? pending;

  @override
  Future<String> signIn() async {
    signInCalls++;
    await pending?.future;
    final error = nextError;
    if (error != null) throw error;
    final token = nextIdToken;
    if (token == null) throw GoogleAuthException.notConfigured;
    return token;
  }

  @override
  Future<void> signOut() async => signOutCalls++;
}

/// Stands in for the OS: [os] is the current state, [onRequest] is what the user picks
/// in the system dialog. Records every dialog that would have been shown.
class FakePermissionService extends PermissionService {
  FakePermissionService() : super(isWeb: false, platform: TargetPlatform.android);

  final Map<AppPermission, PermissionState> os = {
    for (final p in AppPermission.values) p: PermissionState.denied,
  };
  final Map<AppPermission, PermissionState> onRequest = {};
  final List<AppPermission> dialogsShown = [];

  /// Every status check and request, in order, e.g. "status location", "request camera".
  final List<String> calls = [];
  int settingsOpened = 0;

  @override
  Future<PermissionState> status(AppPermission permission) async {
    calls.add('status ${permission.name}');
    return os[permission]!;
  }

  @override
  Future<PermissionState> request(AppPermission permission) async {
    calls.add('request ${permission.name}');
    if (os[permission] != PermissionState.denied) return os[permission]!;
    dialogsShown.add(permission);
    return os[permission] = onRequest[permission] ?? PermissionState.granted;
  }

  /// What the user picks when the dialog is shown again for a limited grant.
  PermissionState onRequestAgain = PermissionState.granted;

  @override
  Future<PermissionState> requestAgainIfLimited(AppPermission permission) async {
    calls.add('requestAgain ${permission.name}');
    if (os[permission] != PermissionState.limited) return os[permission]!;
    dialogsShown.add(permission);
    return os[permission] = onRequestAgain;
  }

  @override
  Future<bool> openSettings() async {
    settingsOpened++;
    return true;
  }

  int mediaLocationRequests = 0;

  @override
  Future<void> requestMediaLocation() async => mediaLocationRequests++;

  /// "Allow all the time" location: the OS state, and what the user picks when asked.
  PermissionState backgroundLocation = PermissionState.denied;
  PermissionState onBackgroundRequest = PermissionState.granted;
  int backgroundDialogs = 0;

  @override
  Future<PermissionState> backgroundLocationStatus() async {
    calls.add('status backgroundLocation');
    return backgroundLocation;
  }

  @override
  Future<PermissionState> requestBackgroundLocationPermission() async {
    calls.add('request backgroundLocation');
    if (backgroundLocation != PermissionState.denied) return backgroundLocation;
    backgroundDialogs++;
    return backgroundLocation = onBackgroundRequest;
  }

  /// Grants foreground and background location, as a user who chose "Allow all the time".
  void allowLocationAllTheTime() {
    os[AppPermission.location] = PermissionState.granted;
    backgroundLocation = PermissionState.granted;
  }
}

/// Stands in for background location (geolocator's foreground service). Tests push readings with
/// [emit]; [listening] tells whether the app is collecting (and the Android notification showing).
class FakeBackgroundLocationSource implements BackgroundLocationSource {
  @override
  bool isSupported = true;
  bool serviceEnabled = true;

  StreamController<TrackedPoint>? _controller;
  int starts = 0;

  /// What the next confirmation reading returns; null makes it fail.
  TrackedPoint? fresh;
  int freshReads = 0;

  bool get listening => _controller?.hasListener ?? false;

  @override
  Future<bool> isServiceEnabled() async => serviceEnabled;

  @override
  Stream<TrackedPoint> positions(AutomaticTrackingConfig config) {
    starts++;
    final controller = StreamController<TrackedPoint>();
    controller.onCancel = () {
      if (identical(_controller, controller)) _controller = null;
    };
    _controller = controller;
    return controller.stream;
  }

  @override
  Future<TrackedPoint> currentPosition(AutomaticTrackingConfig config) async {
    freshReads++;
    final point = fresh;
    if (point == null) throw TimeoutException('no fix');
    return point;
  }

  void emit(TrackedPoint point) {
    final controller = _controller;
    if (controller == null) throw StateError('not listening');
    controller.add(point);
  }

  /// The platform ends the stream with an error (e.g. permission revoked in Settings).
  void fail(Object error) => _controller?.addError(error);
}

/// Stands in for the GPS hardware.
class FakeLocationProvider implements LocationProvider {
  bool serviceEnabled = true;

  /// Returned by the next reads; set [error] to make them throw instead.
  DeviceLocation position = DeviceLocation(
    latitude: 20.2961,
    longitude: 85.8245,
    accuracy: 12.4,
    capturedAt: DateTime.now().toUtc(),
  );
  Object? error;

  /// When set, the next read waits for this instead of answering immediately.
  Completer<DeviceLocation>? pending;

  int reads = 0;
  int settingsOpened = 0;

  @override
  Future<bool> isServiceEnabled() async => serviceEnabled;

  @override
  Future<DeviceLocation> currentPosition({required Duration timeLimit}) async {
    reads++;
    if (error != null) throw error!;
    final wait = pending;
    pending = null;
    return wait?.future ?? position;
  }

  @override
  Future<bool> openLocationSettings() async {
    settingsOpened++;
    return true;
  }
}

/// Stands in for the device geocoder. Returns [placemark] (null = no match) or throws [error].
class FakePlaceLookup implements PlaceLookup {
  Placemark? placemark = const Placemark(
    name: 'Jayadev Vihar',
    street: 'Jayadev Vihar',
    locality: 'Bhubaneswar',
    subAdministrativeArea: 'Khordha',
    administrativeArea: 'Odisha',
    postalCode: '751013',
    country: 'India',
    isoCountryCode: 'IN',
  );
  Object? error;
  int lookups = 0;

  @override
  Future<Placemark?> placemarkAt(double latitude, double longitude) async {
    lookups++;
    if (error != null) throw error!;
    return placemark;
  }
}

/// Stands in for the device gallery. [photos] are newest first, like the real query.
class FakePhotoLibrary implements PhotoLibrary {
  FakePhotoLibrary([List<PhotoItem>? photos]) : photos = photos ?? [];

  /// [count] photos named IMG_0001.jpg (newest), IMG_0002.jpg, ..., one per day back from
  /// 6 Oct 2026.
  factory FakePhotoLibrary.withPhotos(int count) => FakePhotoLibrary([
        for (var i = 1; i <= count; i++)
          PhotoItem(
            id: 'p$i',
            name: 'IMG_${i.toString().padLeft(4, '0')}.jpg',
            width: 4032,
            height: 3024,
            createdAt: DateTime.utc(2026, 10, 6, 10, 30).subtract(Duration(days: i - 1)),
            modifiedAt: DateTime.utc(2026, 10, 6, 10, 30).subtract(Duration(days: i - 1)),
            mimeType: 'image/jpeg',
          ),
      ]);

  final List<PhotoItem> photos;

  /// Every page query, e.g. "page 0" or "page 0 2026-10-01..2026-10-03".
  final List<String> queries = [];

  /// Every image read as "id WxH".
  final List<String> imageReads = [];

  /// When > 0, that many of the next page queries throw.
  int pageFailures = 0;

  /// When set, the next page query waits for this.
  Completer<void>? pending;

  int resets = 0;
  int selectionPickerShown = 0;

  /// Whether this fake behaves like iOS (has its own limited-selection picker).
  bool hasSelectionPicker = false;

  static final Uint8List _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
  );

  @override
  Future<List<PhotoItem>> page(int page, int pageSize, {DateTimeRange? range}) async {
    queries.add(range == null
        ? 'page $page'
        : 'page $page ${_day(range.start)}..${_day(range.end)}');
    final wait = pending;
    pending = null;
    if (wait != null) await wait.future;
    if (pageFailures > 0) {
      pageFailures--;
      throw Exception('gallery unavailable');
    }
    final matching = range == null
        ? photos
        : photos
            .where((p) =>
                !p.createdAt.isBefore(range.start) &&
                p.createdAt.isBefore(range.end.add(const Duration(days: 1))))
            .toList();
    return matching.skip(page * pageSize).take(pageSize).toList();
  }

  /// GPS positions stored in photos (by id). Photos not listed have none, as on a real phone.
  final Map<String, PhotoPosition> positions = {};

  /// Photos deleted from the phone after they were listed.
  final Set<String> deleted = {};

  /// Every GPS read, by photo id.
  final List<String> locationReads = [];

  /// Every private share reference handed out, by photo id.
  final List<String> shareReferenceReads = [];

  /// The private reference this fake hands out for [id] (a content URI on a real phone).
  static String referenceFor(String id) => 'content://media/external/images/media/$id';

  @override
  Future<Uint8List?> image(String id, int width, int height) async {
    imageReads.add('$id ${width}x$height');
    if (deleted.contains(id)) return null;
    return _png;
  }

  @override
  Future<PhotoItem?> details(String id) async {
    if (deleted.contains(id)) return null;
    final photo = photos.where((p) => p.id == id).firstOrNull;
    return photo?.withDetails(fileSize: 2457600);
  }

  @override
  Future<PhotoPosition?> location(String id) async {
    locationReads.add(id);
    return positions[id];
  }

  @override
  Future<String?> shareReference(String id) async {
    shareReferenceReads.add(id);
    return deleted.contains(id) ? null : referenceFor(id);
  }

  @override
  Future<bool> changeLimitedSelection() async {
    if (!hasSelectionPicker) return false;
    selectionPickerShown++;
    return true;
  }

  @override
  void reset() => resets++;

  static String _day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// A file on the fake device.
class FakeDocumentFile {
  FakeDocumentFile({
    required this.reference,
    required this.name,
    this.mimeType,
    this.size,
    this.modifiedAt,
    this.content = '',
    this.encrypted = false,
  });

  final String reference;
  final String name;
  final String? mimeType;
  final int? size;
  final DateTime? modifiedAt;

  /// The file's text: what a TXT contains, or what text extraction finds in a PDF or DOCX
  /// (empty for a scanned PDF).
  final String content;

  /// A password-protected PDF.
  final bool encrypted;
}

/// A folder on the fake device.
class FakeFolder {
  FakeFolder({required this.reference, required this.name});

  final String reference;
  final String name;
  final List<String> files = [];

  /// Whether Child Assist holds read access to it (granted when picked).
  bool granted = false;
}

/// Stands in for the system file picker and the documents on the device.
///
/// Put files on the device with [addFile], choose what the user will pick next with
/// [willPick] (nothing set = the user cancels), and delete files with [deleteFile].
class FakeDocumentPlatform implements DocumentPlatform {
  final Map<String, FakeDocumentFile> files = {};
  int _nextFile = 1;

  /// References the user picks the next time the picker opens; null = they cancel.
  List<String>? _nextPick;

  /// When set, the next pick throws it.
  Object? pickError;

  /// When set, the next pick waits for this before returning (the picker is "open").
  Completer<void>? pendingPick;

  /// When > 0, that many of the next info / read / open calls throw.
  int infoFailures = 0;
  int readFailures = 0;
  int openFailures = 0;

  /// Whether a viewer app for the document's type is installed, and whether any app at all
  /// accepts files.
  bool hasViewer = true;
  bool hasAnyApp = true;

  int pickerShown = 0;
  final List<List<String>> pickedExtensions = [];

  /// For each pick, whether several files could be chosen.
  final List<bool> pickedMultiple = [];

  /// Every open, e.g. "content://fake/1 application/pdf" or "content://fake/1 any app".
  final List<String> opened = [];

  /// Every byte read: "reference maxBytes".
  final List<String> reads = [];
  final List<String> released = [];

  FakeDocumentFile addFile(
    String name, {
    String? mimeType,
    int? size,
    DateTime? modifiedAt,
    String content = '',
    bool encrypted = false,
  }) {
    final reference = 'content://fake/${_nextFile++}';
    return files[reference] = FakeDocumentFile(
      reference: reference,
      name: name,
      mimeType: mimeType,
      size: size,
      modifiedAt: modifiedAt,
      content: content,
      encrypted: encrypted,
    );
  }

  /// Every text extraction: "reference TYPE maxChars". Tests check only the chosen file is read.
  final List<String> extracted = [];

  @override
  Future<ExtractedText?> extractText(String reference, DocumentType type, int maxChars) async {
    extracted.add('$reference ${type.label} $maxChars');
    final file = files[reference];
    if (file == null) return null;
    if (file.encrypted) return const ExtractedText.failed(DocumentTextProblem.encrypted);
    final text = file.content;
    return text.length > maxChars
        ? ExtractedText.ok(text.substring(0, maxChars), truncated: true)
        : ExtractedText.ok(text);
  }

  void willPick(List<FakeDocumentFile> picked) => _nextPick = [for (final f in picked) f.reference];

  // Folders granted in the system folder picker (Android's document tree access).

  @override
  bool supportsFolders = true;

  /// Folder references (still granted) and the files in each.
  final Map<String, FakeFolder> folders = {};
  int _nextFolder = 1;
  FakeFolder? _nextFolderPick;
  int folderPickerShown = 0;
  final List<String> releasedFolders = [];

  /// A folder on the device. Put files in it with [addFileTo].
  FakeFolder addFolder(String name) {
    final folder = FakeFolder(reference: 'content://fake-tree/${_nextFolder++}', name: name);
    return folders[folder.reference] = folder;
  }

  /// A file inside [folder] (or a subfolder of it), as the folder listing would find it.
  FakeDocumentFile addFileTo(
    FakeFolder folder,
    String name, {
    String? mimeType,
    int? size,
    DateTime? modifiedAt,
    String content = '',
  }) {
    final file = addFile(name, mimeType: mimeType, size: size, modifiedAt: modifiedAt, content: content);
    folder.files.add(file.reference);
    return file;
  }

  /// The folder the user chooses the next time the folder picker opens; none = they cancel.
  void willPickFolder(FakeFolder folder) => _nextFolderPick = folder;

  /// The user removed the folder's access in Android settings (or deleted the folder).
  void revokeFolder(FakeFolder folder) => folder.granted = false;

  @override
  Future<PickedFolder?> pickFolder() async {
    folderPickerShown++;
    final folder = _nextFolderPick;
    _nextFolderPick = null;
    if (folder == null) return null;
    folder.granted = true;
    return PickedFolder(reference: folder.reference, name: folder.name);
  }

  @override
  Future<FolderListing?> listFolder(String reference) async {
    final folder = folders[reference];
    if (folder == null || !folder.granted) return null;
    return FolderListing(
      folderName: folder.name,
      documents: [
        for (final ref in folder.files)
          if (files[ref] != null) PickedDocument(reference: ref, name: files[ref]!.name, info: _info(files[ref]!)),
      ],
    );
  }

  @override
  Future<void> releaseFolder(String reference) async => releasedFolders.add(reference);

  void deleteFile(FakeDocumentFile file) => files.remove(file.reference);

  @override
  Future<List<PickedDocument>> pick(List<String> extensions, {bool multiple = true}) async {
    pickerShown++;
    pickedExtensions.add(extensions);
    pickedMultiple.add(multiple);
    final wait = pendingPick;
    pendingPick = null;
    if (wait != null) await wait.future;
    final error = pickError;
    pickError = null;
    if (error != null) throw error;
    var picked = _nextPick ?? [];
    _nextPick = null;
    // The single-file picker only lets the user choose one.
    if (!multiple && picked.length > 1) picked = picked.sublist(0, 1);
    return [
      for (final reference in picked)
        PickedDocument(reference: reference, name: files[reference]!.name, info: _info(files[reference]!)),
    ];
  }

  @override
  Future<DocumentInfo?> info(String reference) async {
    if (infoFailures > 0) {
      infoFailures--;
      throw Exception('provider crashed');
    }
    final file = files[reference];
    return file == null ? null : _info(file);
  }

  @override
  Future<DocumentOpenResult> open(String reference, {required String mimeType, bool anyApp = false}) async {
    if (openFailures > 0) {
      openFailures--;
      throw Exception('activity crashed');
    }
    if (!files.containsKey(reference)) return DocumentOpenResult.unavailable;
    if (!(anyApp ? hasAnyApp : hasViewer)) return DocumentOpenResult.noViewer;
    opened.add(anyApp ? '$reference any app' : '$reference $mimeType');
    return DocumentOpenResult.opened;
  }

  @override
  Future<Uint8List?> read(String reference, int maxBytes) async {
    if (readFailures > 0) {
      readFailures--;
      throw Exception('read failed');
    }
    reads.add('$reference $maxBytes');
    final file = files[reference];
    if (file == null) return null;
    final bytes = utf8.encode(file.content);
    return Uint8List.fromList(bytes.take(maxBytes).toList());
  }

  @override
  Future<void> release(String reference) async => released.add(reference);

  static DocumentInfo _info(FakeDocumentFile f) =>
      DocumentInfo(name: f.name, mimeType: f.mimeType, size: f.size, modifiedAt: f.modifiedAt);
}

/// Stands in for the phone's address book. Counts reads, so tests can check that nothing is
/// read without the Contacts permission.
class FakeContactsSource implements ContactsSource {
  FakeContactsSource([List<ContactItem>? contacts]) : contacts = contacts ?? [];

  final List<ContactItem> contacts;
  int reads = 0;

  /// When set, reading the contacts fails with this.
  Object? error;

  @override
  Future<List<ContactItem>> readAll() async {
    reads++;
    if (error != null) throw error!;
    return List.of(contacts);
  }
}

/// Stands in for WhatsApp and the share sheet. Nothing is ever sent from the app itself.
class FakeMessageHandoff implements MessageHandoff {
  bool whatsAppInstalled = true;
  bool canShare = true;

  /// Every handoff, e.g. "whatsapp 9876543210: Hi" or "share: Hi".
  final List<String> calls = [];

  @override
  Future<HandoffResult> openWhatsApp({required String phone, required String text}) async {
    calls.add('whatsapp $phone: $text');
    return whatsAppInstalled ? HandoffResult.opened : HandoffResult.unavailable;
  }

  @override
  Future<HandoffResult> shareText(String text) async {
    calls.add('share: $text');
    return canShare ? HandoffResult.opened : HandoffResult.unavailable;
  }

  @override
  Future<HandoffResult> shareDocument({
    required String reference,
    required String mimeType,
    String? text,
    String? phone,
    bool toWhatsApp = false,
  }) async {
    calls.add('${toWhatsApp ? 'whatsapp-document $phone' : 'share-document'}: $reference');
    return (toWhatsApp ? whatsAppInstalled : canShare) ? HandoffResult.opened : HandoffResult.unavailable;
  }
}

/// A scripted reply from the fake Child Assist.
class FakeChatReply {
  const FakeChatReply(this.text, {this.toolEvents = const [], this.pendingActions = const [], this.title});

  final String text;
  final List<Map<String, dynamic>> toolEvents;
  final List<Map<String, dynamic>> pendingActions;
  final String? title;

  static FakeChatReply standard(String message) => message.toLowerCase().contains('your name')
      ? const FakeChatReply('My name is Child Assist.')
      : FakeChatReply('You said: $message');
}

/// Stands in for the device speech recogniser. A test drives one utterance with [hear],
/// [finish], [fail] or [silence]; nothing touches a real microphone.
class FakeVoiceInput implements VoiceInput {
  FakeVoiceInput({this.available = true, this.initializes = true});

  bool available;
  bool initializes;

  /// Every call, in order, e.g. "initialize", "listen", "stop", "cancel".
  final List<String> calls = [];
  Completer<String?>? _pending;
  ValueChanged<String>? _onPartial;
  String _heard = '';

  @override
  bool get isAvailable => available;

  @override
  bool get isListening => _pending != null;

  @override
  Future<bool> initialize() async {
    calls.add('initialize');
    return available && initializes;
  }

  @override
  Future<String?> listen({ValueChanged<String>? onPartialResult, String? localeId}) {
    calls.add('listen');
    if (!available || !initializes) return Future.error(const VoiceInputException(VoiceErrorKind.unavailable));
    _heard = '';
    _onPartial = onPartialResult;
    return (_pending = Completer<String?>()).future;
  }

  /// The user is speaking: a partial result.
  void hear(String words) {
    _heard = words;
    _onPartial?.call(words);
  }

  /// The recogniser's final result.
  void finish(String words) => _complete(words);

  /// The user said nothing.
  void silence() => _complete('');

  void fail(VoiceErrorKind kind) {
    final pending = _pending;
    _pending = null;
    pending?.completeError(VoiceInputException(kind));
  }

  @override
  Future<void> stopListening() async {
    calls.add('stop');
    _complete(_heard);
  }

  @override
  Future<void> cancelListening() async {
    if (_pending == null) return;
    calls.add('cancel');
    final pending = _pending;
    _pending = null;
    pending?.complete(null);
  }

  void _complete(String words) {
    final pending = _pending;
    _pending = null;
    pending?.complete(words.trim());
  }

  @override
  Future<List<VoiceLocale>> locales() async => const [VoiceLocale('en_US', 'English (United States)')];

  @override
  Future<void> dispose() => cancelListening();
}

/// Stands in for the device text-to-speech engine. Speech "plays" until [finishSpeaking] or stop.
class FakeTextToSpeech extends TextToSpeechService {
  FakeTextToSpeech({this.available = true});

  bool available;
  final List<String> spoken = [];
  int stops = 0;
  bool _enabled = false;
  bool _speaking = false;

  @override
  bool get isAvailable => available;

  @override
  bool get repliesEnabled => _enabled;

  @override
  set repliesEnabled(bool value) {
    _enabled = value;
    notifyListeners();
  }

  @override
  bool get isSpeaking => _speaking;

  @override
  Future<void> speak(String text) async {
    final speakable = speakableText(text);
    if (speakable.isEmpty) return;
    spoken.add(speakable);
    _speaking = true;
    notifyListeners();
  }

  void finishSpeaking() {
    _speaking = false;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    stops++;
    if (!_speaking) return;
    _speaking = false;
    notifyListeners();
  }

  @override
  Future<void> pause() async => stop();

  @override
  Future<void> resume() async {}
}

/// The phone's photo picker and private storage for profile photos, in memory.
class FakeProfilePhotoPlatform implements ProfilePhotoPlatform {
  /// What the next pick returns; null means the user cancels.
  Uint8List? nextPick;

  /// userId -> saved photo bytes.
  final Map<String, Uint8List> saved = {};

  @override
  Future<Uint8List?> pickImage() async => nextPick;

  @override
  Future<Uint8List?> read(String userId) async => saved[userId];

  @override
  Future<void> write(String userId, Uint8List bytes) async => saved[userId] = bytes;

  @override
  Future<void> delete(String userId) async => saved.remove(userId);
}
