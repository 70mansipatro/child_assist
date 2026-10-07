import 'package:flutter/foundation.dart';

import '../../../core/api/api_client.dart';
import '../models/chat_message.dart';
import 'chat_service.dart';

/// Why the last request failed, so the screen can say something useful.
enum ChatErrorKind { offline, timeout, unavailable, conversationDeleted, server }

class ChatError {
  const ChatError(this.kind);

  final ChatErrorKind kind;

  /// The headline is always the same; this explains it in one short line.
  String get detail => switch (kind) {
        ChatErrorKind.offline => 'Check your internet connection.',
        ChatErrorKind.timeout => 'Child Assist took too long to answer.',
        ChatErrorKind.unavailable => 'Child Assist is unavailable right now.',
        ChatErrorKind.conversationDeleted => 'This conversation no longer exists, so a new chat was started.',
        ChatErrorKind.server => 'The server had a problem.',
      };

  static ChatError from(Object error) {
    if (error is ApiException) {
      return switch (error.statusCode) {
        null when error.message.contains('too long') => const ChatError(ChatErrorKind.timeout),
        null => const ChatError(ChatErrorKind.offline),
        404 => const ChatError(ChatErrorKind.conversationDeleted),
        504 => const ChatError(ChatErrorKind.timeout),
        503 => const ChatError(ChatErrorKind.unavailable),
        _ => const ChatError(ChatErrorKind.server),
      };
    }
    return const ChatError(ChatErrorKind.server);
  }
}

/// The conversation shown on the chat screen: its messages, whether Child Assist is answering,
/// and the last error. Typed and spoken messages both go through [send].
class ChatSession extends ChangeNotifier {
  ChatSession({required ChatService service}) : _service = service;

  final ChatService _service;

  String? _conversationId;
  String? _title;
  List<ChatMessage> _messages = const [];
  bool _sending = false;
  bool _loading = false;
  ChatToolKind? _activeTool;
  ChatError? _error;
  String? _failedText;
  int _localIds = 0;

  // Bumped by newChat/open, so a reply that arrives for an abandoned chat is ignored.
  int _generation = 0;

  String? get conversationId => _conversationId;
  String? get title => _title;
  List<ChatMessage> get messages => _messages;
  bool get isSending => _sending;
  bool get isLoading => _loading;

  /// The tool Child Assist is using right now, when the server reports it.
  ChatToolKind? get activeTool => _activeTool;
  ChatError? get error => _error;
  bool get canRetry => _failedText != null && !_sending;
  bool get isEmpty => _messages.isEmpty && !_loading;

  Future<void> send(String text) async {
    final message = text.trim();
    if (message.isEmpty || _sending) return;
    final generation = _generation;

    final local = ChatMessage(
      id: 'local-${_localIds++}',
      role: ChatRole.user,
      content: message,
      createdAt: DateTime.now(),
      state: ChatMessageState.sending,
    );
    _messages = [..._messages.where((m) => m.state != ChatMessageState.failed), local];
    _sending = true;
    _error = null;
    _failedText = null;
    _activeTool = null;
    notifyListeners();

    try {
      await for (final event in _service.send(message, conversationId: _conversationId)) {
        if (generation != _generation) return;
        switch (event) {
          case ChatToolProgress(:final kind):
            _activeTool = kind;
            notifyListeners();
          case ChatTurnCompleted(:final reply):
            _conversationId = reply.conversationId;
            _title = reply.title ?? _title;
            // Replace the local copy with what the server stored (secrets redacted).
            _messages = [
              for (final m in _messages)
                if (m.id != local.id) m,
              reply.userMessage,
              reply.assistantMessage,
            ];
        }
      }
    } catch (e) {
      if (generation != _generation) return;
      final error = ChatError.from(e);
      if (error.kind == ChatErrorKind.conversationDeleted) _resetConversation();
      _error = error;
      _failedText = message;
      _messages = [
        for (final m in _messages)
          if (m.id == local.id) m.copyWith(state: ChatMessageState.failed) else m,
      ];
    } finally {
      if (generation == _generation) {
        _sending = false;
        _activeTool = null;
        notifyListeners();
      }
    }
  }

  /// Sends the message that failed again. The server rolled the failed turn back, so this
  /// does not create a duplicate.
  Future<void> retry() async {
    final text = _failedText;
    if (text == null || _sending) return;
    _messages = _messages.where((m) => m.state != ChatMessageState.failed).toList();
    await send(text);
  }

  /// Starts a fresh chat. The previous conversation stays in History.
  void newChat() {
    _generation++;
    _resetConversation();
    _messages = const [];
    _sending = false;
    _loading = false;
    _error = null;
    _failedText = null;
    _activeTool = null;
    notifyListeners();
  }

  /// Loads an earlier conversation so the user can read and continue it.
  Future<void> open(String id) async {
    final generation = ++_generation;
    _resetConversation();
    _messages = const [];
    _sending = false;
    _loading = true;
    _error = null;
    _failedText = null;
    notifyListeners();
    try {
      final (conversation, messages) = await _service.getConversation(id);
      if (generation != _generation) return;
      _conversationId = conversation.id;
      _title = conversation.title;
      _messages = messages;
    } catch (e) {
      if (generation != _generation) return;
      _error = ChatError.from(e);
    } finally {
      if (generation == _generation) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  /// Called after a conversation was deleted from History.
  void conversationDeleted(String id) {
    if (id == _conversationId) newChat();
  }

  /// Runs an action after the user tapped Confirm. Nothing is ever sent without this.
  Future<void> confirmAction(String actionId) => _resolveAction(actionId, confirm: true);

  /// Declines an action; nothing is sent.
  Future<void> cancelAction(String actionId) => _resolveAction(actionId, confirm: false);

  Future<void> _resolveAction(String actionId, {required bool confirm}) async {
    _updateAction(
      actionId,
      (a) => a.copyWith(state: confirm ? PendingActionState.confirming : PendingActionState.cancelling),
    );
    try {
      final outcome = confirm ? await _service.confirmAction(actionId) : await _service.cancelAction(actionId);
      _updateAction(
        actionId,
        (a) => a.copyWith(
          state: outcome.cancelled
              ? PendingActionState.cancelled
              : outcome.succeeded
                  ? PendingActionState.done
                  : PendingActionState.failed,
          resultMessage: outcome.message,
        ),
      );
    } catch (e) {
      if (!confirm) {
        // Even if the server could not be told, nothing is sent without a confirmation.
        _updateAction(actionId, (a) => a.copyWith(state: PendingActionState.cancelled, resultMessage: 'Cancelled.'));
        return;
      }
      final message = e is ApiException && (e.statusCode == 409 || e.statusCode == 410)
          ? e.message
          : 'Something went wrong. Nothing was sent.';
      _updateAction(actionId, (a) => a.copyWith(state: PendingActionState.failed, resultMessage: message));
    }
  }

  void _updateAction(String actionId, PendingAction Function(PendingAction) update) {
    _messages = [
      for (final m in _messages)
        if (m.pendingActions.any((a) => a.id == actionId))
          m.copyWith(pendingActions: [for (final a in m.pendingActions) a.id == actionId ? update(a) : a])
        else
          m,
    ];
    notifyListeners();
  }

  void _resetConversation() {
    _conversationId = null;
    _title = null;
  }
}
