import '../../../core/api/api_client.dart';
import '../models/chat_conversation.dart';
import '../models/chat_message.dart';

/// Raw calls to the backend's /api/chat endpoints. The server identifies the user from the
/// token, so no user ID is ever sent. All AI work (Gemini on Vertex AI) happens on the server;
/// the app holds no AI credentials.
class ChatApi {
  ChatApi(this._client);

  final ApiClient _client;

  /// The server may run several tool steps before answering, so a reply can take a while.
  static const replyTimeout = Duration(seconds: 60);

  Future<ChatReply> sendMessage(
    String token, {
    required String message,
    String? conversationId,
    int? utcOffsetMinutes,
  }) async {
    final json = await _client.post(
      '/api/chat',
      token: token,
      timeout: replyTimeout,
      body: {
        'message': message,
        'conversationId': ?conversationId,
        'utcOffsetMinutes': ?utcOffsetMinutes,
      },
    );

    final events = [
      for (final e in (json['toolEvents'] as List? ?? const []).whereType<Map<String, dynamic>>())
        ChatToolEvent.fromJson(e),
    ];
    final actions = [
      for (final a in (json['pendingActions'] as List? ?? const []).whereType<Map<String, dynamic>>())
        ?PendingAction.tryParse(a),
    ];
    final user = ChatMessage.fromJson(json['userMessage'] as Map<String, dynamic>? ?? const {});
    final assistant = ChatMessage.fromJson(
      json['message'] as Map<String, dynamic>? ?? const {},
      toolEvents: events,
      pendingActions: actions,
    );
    final conversationIdOut = json['conversationId'];
    if (user == null || assistant == null || conversationIdOut is! String) {
      throw ApiException('Something went wrong. Please try again.');
    }
    return ChatReply(
      conversationId: conversationIdOut,
      title: json['title'] as String?,
      userMessage: user,
      assistantMessage: assistant,
    );
  }

  Future<ChatConversation> createConversation(String token, {String? title}) async {
    final json = await _client.post('/api/chat/conversations', token: token, body: {'title': ?title});
    return ChatConversation.fromJson(json['conversation'] as Map<String, dynamic>);
  }

  /// The user's conversations, most recently active first.
  Future<List<ChatConversation>> listConversations(String token) async {
    final json = await _client.get('/api/chat/conversations', token: token);
    final result = <ChatConversation>[];
    for (final c in (json['conversations'] as List? ?? const []).whereType<Map<String, dynamic>>()) {
      try {
        result.add(ChatConversation.fromJson(c));
      } on FormatException {
        // Skip a malformed entry rather than hiding the whole history.
      }
    }
    return result;
  }

  /// One conversation and its messages, oldest first.
  Future<(ChatConversation, List<ChatMessage>)> getConversation(String token, String id) async {
    final json = await _client.get('/api/chat/conversations/${Uri.encodeComponent(id)}', token: token);
    final conversation = ChatConversation.fromJson(json['conversation'] as Map<String, dynamic>);
    final messages = [
      for (final m in (json['messages'] as List? ?? const []).whereType<Map<String, dynamic>>())
        ?ChatMessage.fromJson(m),
    ];
    return (conversation, messages);
  }

  Future<void> deleteConversation(String token, String id) async {
    await _client.delete('/api/chat/conversations/${Uri.encodeComponent(id)}', token: token);
  }

  /// Runs an action the user explicitly confirmed. Returns the server's outcome message.
  Future<ActionOutcome> confirmAction(String token, String id) =>
      _action(token, id, 'confirm');

  /// Declines an action so it can never run.
  Future<ActionOutcome> cancelAction(String token, String id) => _action(token, id, 'cancel');

  Future<ActionOutcome> _action(String token, String id, String verb) async {
    final json = await _client.post(
      '/api/chat/actions/${Uri.encodeComponent(id)}/$verb',
      token: token,
      timeout: replyTimeout,
    );
    final action = json['action'] as Map<String, dynamic>? ?? const {};
    return ActionOutcome(
      succeeded: action['status'] == 'SUCCEEDED',
      cancelled: action['status'] == 'CANCELLED',
      message: action['message'] as String? ?? '',
    );
  }
}

class ActionOutcome {
  const ActionOutcome({required this.succeeded, required this.cancelled, required this.message});

  final bool succeeded;
  final bool cancelled;
  final String message;
}
