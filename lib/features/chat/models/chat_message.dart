/// Who wrote a message. Only these two are shown; the server's system/tool records never are.
enum ChatRole { user, assistant }

/// Where a message is in its life on this device.
enum ChatMessageState {
  /// Saved by the server.
  sent,

  /// Shown immediately while the server is answering.
  sending,

  /// The server could not answer; the user can retry.
  failed,
}

/// One message in a conversation.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
    this.state = ChatMessageState.sent,
    this.toolEvents = const [],
    this.pendingActions = const [],
  });

  final String id;
  final ChatRole role;
  final String content;
  final DateTime createdAt;
  final ChatMessageState state;

  /// What Child Assist looked at for this reply (only on replies received in this session).
  final List<ChatToolEvent> toolEvents;

  /// Actions waiting for the user's confirmation, e.g. sending location details.
  final List<PendingAction> pendingActions;

  bool get isUser => role == ChatRole.user;

  ChatMessage copyWith({ChatMessageState? state, List<PendingAction>? pendingActions}) => ChatMessage(
        id: id,
        role: role,
        content: content,
        createdAt: createdAt,
        state: state ?? this.state,
        toolEvents: toolEvents,
        pendingActions: pendingActions ?? this.pendingActions,
      );

  /// A message from the server. Returns null for roles the app does not show.
  static ChatMessage? fromJson(
    Map<String, dynamic> json, {
    List<ChatToolEvent> toolEvents = const [],
    List<PendingAction> pendingActions = const [],
  }) {
    final role = switch (json['role']) {
      'CHAT_USER' => ChatRole.user,
      'CHAT_ASSISTANT' => ChatRole.assistant,
      _ => null,
    };
    final id = json['id'];
    final content = json['content'];
    final created = DateTime.tryParse(json['createdAt'] as String? ?? '');
    if (role == null || id is! String || content is! String || created == null) return null;
    return ChatMessage(
      id: id,
      role: role,
      content: content,
      createdAt: created,
      toolEvents: toolEvents,
      pendingActions: pendingActions,
    );
  }
}

/// The friendly category of something Child Assist checked. The server never sends internal
/// tool names, and the app never shows them.
enum ChatToolKind {
  profile,
  permissions,
  locationHistory,
  currentLocation,
  photos,
  documents,
  documentText,
  webSearch,
  contacts,
  sendAction,
  unknown;

  static ChatToolKind parse(Object? value) => switch (value) {
        'profile' => profile,
        'permissions' => permissions,
        'location_history' => locationHistory,
        'current_location' => currentLocation,
        'photos' => photos,
        'documents' => documents,
        'document_text' => documentText,
        'web_search' => webSearch,
        'contacts' => contacts,
        'send_action' => sendAction,
        _ => unknown,
      };
}

enum ChatToolStatus {
  success,

  /// The app searches the phone itself; photos and documents never leave the device.
  deviceLookup,
  permissionRequired,
  confirmationRequired,
  unavailable,
  notConfigured,
  invalid,
  failed;

  static ChatToolStatus parse(Object? value) => switch (value) {
        'success' => success,
        'device_lookup' => deviceLookup,
        'permission_required' => permissionRequired,
        'confirmation_required' => confirmationRequired,
        'not_configured' => notConfigured,
        'invalid' => invalid,
        'failed' => failed,
        _ => unavailable,
      };
}

/// A server permission name mapped to what the user sees.
enum ChatPermission {
  location('Location'),
  photos('Photos'),
  documents('Documents'),
  other('Required');

  const ChatPermission(this.label);

  final String label;

  static ChatPermission? parse(Object? value) => switch (value) {
        null => null,
        'LOCATION' => location,
        'PHOTOS' => photos,
        'DOCUMENTS' => documents,
        _ => other,
      };
}

/// One tool Child Assist used for a reply, with any data the app should display.
class ChatToolEvent {
  const ChatToolEvent({
    required this.kind,
    required this.status,
    this.permission,
    this.locations = const [],
    this.query = const ChatLookupQuery(),
  });

  final ChatToolKind kind;
  final ChatToolStatus status;
  final ChatPermission? permission;

  /// For a successful location-history lookup: the user's own saved places.
  final List<ChatPlace> locations;

  /// For a [ChatToolStatus.deviceLookup]: what to search for on this phone.
  final ChatLookupQuery query;

  factory ChatToolEvent.fromJson(Map<String, dynamic> json) {
    final data = json['data'] is Map<String, dynamic> ? json['data'] as Map<String, dynamic> : const {};
    final rawLocations = data['locations'];
    return ChatToolEvent(
      kind: ChatToolKind.parse(json['kind']),
      status: ChatToolStatus.parse(json['status']),
      permission: ChatPermission.parse(json['permission']),
      locations: rawLocations is List
          ? [for (final l in rawLocations.whereType<Map<String, dynamic>>()) ?ChatPlace.tryParse(l)]
          : const [],
      query: data['query'] is Map<String, dynamic>
          ? ChatLookupQuery.fromJson(data['query'] as Map<String, dynamic>)
          : const ChatLookupQuery(),
    );
  }
}

/// A saved place returned by a location-history lookup.
class ChatPlace {
  const ChatPlace({
    required this.capturedAt,
    required this.latitude,
    required this.longitude,
    this.placeName,
    this.address,
    this.city,
    this.state,
    this.country,
  });

  final DateTime capturedAt;
  final double latitude;
  final double longitude;
  final String? placeName;
  final String? address;
  final String? city;
  final String? state;
  final String? country;

  /// The best short name for the place, falling back to coordinates.
  String get title {
    for (final candidate in [placeName, city, address]) {
      if (candidate != null && candidate.trim().isNotEmpty) return candidate;
    }
    return '${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}';
  }

  /// The address line under the title, or null when there is nothing more to say.
  String? get subtitle {
    final parts = <String>[
      if (address != null && address!.trim().isNotEmpty && address != title) address!
      else ...[
        for (final p in [city, state, country])
          if (p != null && p.trim().isNotEmpty && p != title) p,
      ],
    ];
    return parts.isEmpty ? null : parts.join(', ');
  }

  static ChatPlace? tryParse(Map<String, dynamic> json) {
    final at = DateTime.tryParse(json['capturedAt'] as String? ?? '');
    final lat = json['latitude'], lng = json['longitude'];
    if (at == null || lat is! num || lng is! num) return null;
    String? text(String key) => json[key] is String ? json[key] as String : null;
    return ChatPlace(
      capturedAt: at,
      latitude: lat.toDouble(),
      longitude: lng.toDouble(),
      placeName: text('placeName'),
      address: text('address'),
      city: text('city'),
      state: text('state'),
      country: text('country'),
    );
  }
}

/// What to look for on the phone when the server hands a photo or document search to the app.
class ChatLookupQuery {
  const ChatLookupQuery({this.text, this.type, this.start, this.end, this.limit});

  /// Words the file name should contain.
  final String? text;

  /// Document type label, e.g. "PDF".
  final String? type;
  final DateTime? start;
  final DateTime? end;
  final int? limit;

  factory ChatLookupQuery.fromJson(Map<String, dynamic> json) => ChatLookupQuery(
        text: json['text'] is String && (json['text'] as String).trim().isNotEmpty ? json['text'] as String : null,
        type: json['type'] is String ? json['type'] as String : null,
        start: DateTime.tryParse(json['startDate'] as String? ?? ''),
        end: DateTime.tryParse(json['endDate'] as String? ?? ''),
        limit: (json['limit'] as num?)?.toInt(),
      );
}

enum PendingActionState { awaiting, confirming, cancelling, done, cancelled, failed }

/// An action with an outside effect (e.g. sending location details) that only runs after the
/// user taps Confirm. The summary is written by the server, not by the AI.
class PendingAction {
  const PendingAction({
    required this.id,
    required this.summary,
    this.state = PendingActionState.awaiting,
    this.resultMessage,
  });

  final String id;
  final String summary;
  final PendingActionState state;

  /// What happened after Confirm/Cancel, shown on the card.
  final String? resultMessage;

  bool get isOpen => state == PendingActionState.awaiting;

  PendingAction copyWith({PendingActionState? state, String? resultMessage}) => PendingAction(
        id: id,
        summary: summary,
        state: state ?? this.state,
        resultMessage: resultMessage ?? this.resultMessage,
      );

  static PendingAction? tryParse(Map<String, dynamic> json) {
    final id = json['id'], summary = json['summary'];
    if (id is! String || summary is! String) return null;
    return PendingAction(id: id, summary: summary);
  }
}

/// The server's answer to one message.
class ChatReply {
  const ChatReply({
    required this.conversationId,
    required this.title,
    required this.userMessage,
    required this.assistantMessage,
  });

  final String conversationId;
  final String? title;

  /// The user's message as the server stored it (secrets it contained are redacted).
  final ChatMessage userMessage;
  final ChatMessage assistantMessage;
}
