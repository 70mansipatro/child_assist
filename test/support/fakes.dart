import 'dart:async';
import 'dart:convert';

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
import 'package:child_assist/features/documents/services/document_service.dart';
import 'package:child_assist/features/location/services/location_service.dart';
import 'package:child_assist/features/photos/services/photo_gallery_service.dart';

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

  /// Every action call, e.g. "confirm act1" or "cancel act1".
  final List<String> chatActions = [];

  int _nextChatId = 1;
  DateTime _chatClock = DateTime.utc(2026, 10, 6, 9);

  static const placeKeys = [
    'placeName', 'address', 'street', 'locality', 'city', 'state', 'postalCode', 'country', //
  ];

  static const supportedPermissions = [
    'LOCATION', 'MICROPHONE', 'CAMERA', 'PHOTOS', 'NOTIFICATIONS', 'DOCUMENTS', //
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

  AppServices services(
    PermissionService permissionService, {
    GoogleAuthService? googleAuthService,
    LocationProvider? locationProvider,
    PlaceLookup? placeLookup,
    PhotoLibrary? photoLibrary,
    DocumentPlatform? documentPlatform,
    VoiceInput? voiceInput,
    TextToSpeechService? textToSpeech,
    ProfilePhotoPlatform? profilePhotoPlatform,
  }) =>
      AppServices.create(
        apiClient: ApiClient(baseUrl: 'http://test', httpClient: client),
        tokenStorage: TokenStorage(),
        googleAuthService: googleAuthService ?? FakeGoogleAuthService(),
        permissionService: permissionService,
        locationProvider: locationProvider ?? FakeLocationProvider(),
        placeLookup: placeLookup ?? FakePlaceLookup(),
        photoLibrary: photoLibrary ?? FakePhotoLibrary(),
        documentPlatform: documentPlatform ?? FakeDocumentPlatform(),
        voiceInput: voiceInput ?? FakeVoiceInput(),
        textToSpeech: textToSpeech ?? FakeTextToSpeech(),
        profilePhotoPlatform: profilePhotoPlatform ?? FakeProfilePhotoPlatform(),
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

    if (path.startsWith('/api/location')) return _handleLocation(req, userId);
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
      final lat = body['latitude'], lng = body['longitude'];
      if (lat is! num || lat.abs() > 90) return _json(400, {'message': 'Validation failed'});
      if (lng is! num || lng.abs() > 180) return _json(400, {'message': 'Validation failed'});
      final record = {
        'id': 'loc${_nextLocationId++}',
        'latitude': lat,
        'longitude': lng,
        'accuracy': body['accuracy'],
        for (final key in placeKeys) key: body[key],
        'capturedAt': body['capturedAt'],
      };
      mine.add(record);
      return _json(201, {'location': record});
    }
    if (path == '/api/location/history' && req.method == 'GET') {
      final limit = int.tryParse(req.url.queryParameters['limit'] ?? '50') ?? 50;
      return _json(200, {'locations': mine.reversed.take(limit).toList()});
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
    final action = RegExp(r'^/api/chat/actions/([^/]+)/(confirm|cancel)$').firstMatch(path);
    if (action != null && req.method == 'POST') {
      final verb = action.group(2)!;
      chatActions.add('$verb ${action.group(1)}');
      return _json(200, {
        'action': {
          'id': action.group(1),
          'status': verb == 'confirm' ? 'SUCCEEDED' : 'CANCELLED',
          'message': verb == 'confirm' ? 'Done! I sent it to Mansi.' : "Okay, I didn't send anything.",
        },
      });
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

  @override
  Future<Uint8List?> image(String id, int width, int height) async {
    imageReads.add('$id ${width}x$height');
    return _png;
  }

  @override
  Future<PhotoItem?> details(String id) async {
    final photo = photos.where((p) => p.id == id).firstOrNull;
    return photo?.withDetails(fileSize: 2457600);
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
  });

  final String reference;
  final String name;
  final String? mimeType;
  final int? size;
  final DateTime? modifiedAt;
  final String content;
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
  }) {
    final reference = 'content://fake/${_nextFile++}';
    return files[reference] = FakeDocumentFile(
      reference: reference,
      name: name,
      mimeType: mimeType,
      size: size,
      modifiedAt: modifiedAt,
      content: content,
    );
  }

  void willPick(List<FakeDocumentFile> picked) => _nextPick = [for (final f in picked) f.reference];

  void deleteFile(FakeDocumentFile file) => files.remove(file.reference);

  @override
  Future<List<PickedDocument>> pick(List<String> extensions) async {
    pickerShown++;
    pickedExtensions.add(extensions);
    final wait = pendingPick;
    pendingPick = null;
    if (wait != null) await wait.future;
    final error = pickError;
    pickError = null;
    if (error != null) throw error;
    final picked = _nextPick ?? [];
    _nextPick = null;
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
