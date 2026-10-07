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

  /// Tells the server which contact the user picked on this phone for an action: only that one
  /// email address or phone number, never anything else from the address book.
  Future<PendingAction> chooseRecipient(
    String token,
    String id, {
    required String address,
    String? name,
    String? conversationId,
  }) async {
    final json = await _client.post(
      '/api/chat/actions/${Uri.encodeComponent(id)}/recipient',
      token: token,
      body: {'address': address, 'name': ?name, 'conversationId': ?conversationId},
    );
    final action = PendingAction.tryParse(json['action'] as Map<String, dynamic>? ?? const {});
    if (action == null) throw ApiException('Something went wrong. Please try again.');
    return action;
  }

  /// For sharing a contact's number: the contact and number the user picked on this phone. The
  /// server builds the message from exactly these; nothing else from the address book is sent.
  Future<PendingAction> chooseSharedContact(
    String token,
    String id, {
    required String name,
    required String phone,
    String? conversationId,
  }) async {
    final json = await _client.post(
      '/api/chat/actions/${Uri.encodeComponent(id)}/shared-contact',
      token: token,
      body: {'name': name, 'phone': phone, 'conversationId': ?conversationId},
    );
    final action = PendingAction.tryParse(json['action'] as Map<String, dynamic>? ?? const {});
    if (action == null) throw ApiException('Something went wrong. Please try again.');
    return action;
  }

  /// Runs an action the user explicitly confirmed. Returns the server's outcome.
  Future<ActionOutcome> confirmAction(String token, String id, {String? conversationId}) =>
      _action(token, id, 'confirm', {'conversationId': ?conversationId});

  /// Declines an action so it can never run.
  Future<ActionOutcome> cancelAction(String token, String id, {String? conversationId}) =>
      _action(token, id, 'cancel', {'conversationId': ?conversationId});

  /// Reports what happened after a confirmed WhatsApp action: WhatsApp or the share sheet was
  /// opened (the user sends it there), or WhatsApp isn't on this phone.
  Future<ActionOutcome> reportHandoff(String token, String id, String result, {String? conversationId}) =>
      _action(token, id, 'handoff', {'result': result, 'conversationId': ?conversationId});

  Future<ActionOutcome> _action(String token, String id, String verb, Map<String, Object?> body) async {
    final json = await _client.post(
      '/api/chat/actions/${Uri.encodeComponent(id)}/$verb',
      token: token,
      timeout: replyTimeout,
      body: body,
    );
    final action = json['action'] as Map<String, dynamic>? ?? const {};
    return ActionOutcome(
      status: action['status'] as String? ?? '',
      message: action['outcomeMessage'] as String? ?? '',
      handoff: ActionHandoff.tryParse(action['handoff']),
    );
  }
}

/// The server's answer to Confirm, Cancel or a WhatsApp handoff report.
class ActionOutcome {
  const ActionOutcome({required this.status, required this.message, this.handoff});

  /// PENDING, CONFIRMED, CANCELLED, COMPLETED, FAILED or EXPIRED.
  final String status;
  final String message;

  /// For a confirmed WhatsApp action: what this phone should open.
  final ActionHandoff? handoff;

  bool get completed => status == 'COMPLETED';
  bool get cancelled => status == 'CANCELLED';
  bool get confirmed => status == 'CONFIRMED';
}
