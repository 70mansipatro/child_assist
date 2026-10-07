import 'package:flutter/foundation.dart';

import '../../../core/permissions/permission_service.dart';
import '../../auth/services/auth_service.dart';
import '../../permissions/services/permission_sync_service.dart';
import '../data/chat_api.dart';
import '../models/chat_conversation.dart';
import '../models/chat_message.dart';

/// Progress of one chat turn. Today the server answers in one response, so a turn is just
/// [ChatTurnCompleted]; a streaming transport can later emit [ChatToolProgress] (and partial
/// text) through the same stream without any change to the UI.
sealed class ChatTurnEvent {
  const ChatTurnEvent();
}

/// Child Assist started using a tool, e.g. checking the location history.
class ChatToolProgress extends ChatTurnEvent {
  const ChatToolProgress(this.kind);

  final ChatToolKind kind;
}

class ChatTurnCompleted extends ChatTurnEvent {
  const ChatTurnCompleted(this.reply);

  final ChatReply reply;
}

/// The signed-in user's conversations with Child Assist. Text chat and voice both
/// go through [send], so there is exactly one copy of the chat logic.
class ChatService {
  ChatService({
    required ChatApi api,
    required AuthService authService,
    required PermissionService permissionService,
    required PermissionSyncService permissionSyncService,
  })  : _api = api,
        _auth = authService,
        _permissions = permissionService,
        _sync = permissionSyncService;

  final ChatApi _api;
  final AuthService _auth;
  final PermissionService _permissions;
  final PermissionSyncService _sync;

  /// Sends [message] and reports the turn's progress. Throws ApiException on failure.
  Stream<ChatTurnEvent> send(String message, {String? conversationId}) async* {
    await syncDevicePermissions();
    final reply = await _auth.authorized(
      (token) => _api.sendMessage(
        token,
        message: message,
        conversationId: conversationId,
        utcOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
      ),
    );
    yield ChatTurnCompleted(reply);
  }

  /// The server decides what Child Assist may read from the permission statuses the app
  /// reported. Re-reports Location and Photos as the OS sees them now (a status check, never a
  /// dialog), so turning a permission off in Settings takes effect in chat right away.
  /// The microphone is deliberately not touched.
  Future<void> syncDevicePermissions() async {
    for (final permission in const [AppPermission.location, AppPermission.photos]) {
      try {
        final state = await _permissions.status(permission);
        await _sync.report(permission, state, fromRequest: false);
      } catch (e) {
        // Best effort: the server keeps its last known status.
        debugPrint('Permission sync before chat failed: ${e.runtimeType}');
      }
    }
  }

  Future<List<ChatConversation>> listConversations() => _auth.authorized(_api.listConversations);

  Future<(ChatConversation, List<ChatMessage>)> getConversation(String id) =>
      _auth.authorized((token) => _api.getConversation(token, id));

  Future<ChatConversation> createConversation({String? title}) =>
      _auth.authorized((token) => _api.createConversation(token, title: title));

  Future<void> deleteConversation(String id) =>
      _auth.authorized((token) => _api.deleteConversation(token, id));

  Future<ActionOutcome> confirmAction(String id) => _auth.authorized((token) => _api.confirmAction(token, id));

  Future<ActionOutcome> cancelAction(String id) => _auth.authorized((token) => _api.cancelAction(token, id));
}
