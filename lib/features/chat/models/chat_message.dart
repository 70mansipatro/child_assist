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
  contacts('Contacts'),
  other('Required');

  const ChatPermission(this.label);

  final String label;

  static ChatPermission? parse(Object? value) => switch (value) {
        null => null,
        'LOCATION' => location,
        'PHOTOS' => photos,
        'DOCUMENTS' => documents,
        'CONTACTS' => contacts,
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
    this.requestId,
  });

  final ChatToolKind kind;
  final ChatToolStatus status;
  final ChatPermission? permission;

  /// For reading a document on this phone: the server's request to answer with its text.
  final String? requestId;

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
      requestId: data['requestId'] is String ? data['requestId'] as String : null,
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
    this.automatic = false,
  });

  final DateTime capturedAt;

  /// Saved by Automatic Location History rather than "Get Current Location".
  final bool automatic;
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
      automatic: json['source'] == 'AUTOMATIC',
    );
  }
}

/// Which contact detail the user asked for.
enum ContactField {
  phone,
  email,
  any;

  static ContactField parse(Object? value) => switch (value) {
        'phone' => phone,
        'email' => email,
        _ => any,
      };
}

/// What to look for on the phone when the server hands a photo, document or contact search to
/// the app. Nothing found on the phone is sent back to the server.
class ChatLookupQuery {
  const ChatLookupQuery({this.text, this.type, this.start, this.end, this.limit, this.name, this.field = ContactField.any});

  /// Words the file name should contain.
  final String? text;

  /// Document type label, e.g. "PDF".
  final String? type;
  final DateTime? start;
  final DateTime? end;
  final int? limit;

  /// For a contact search: the name the user said, e.g. "Mansi".
  final String? name;

  /// For a contact search: the number, the email, or either.
  final ContactField field;

  factory ChatLookupQuery.fromJson(Map<String, dynamic> json) => ChatLookupQuery(
        text: json['text'] is String && (json['text'] as String).trim().isNotEmpty ? json['text'] as String : null,
        type: json['type'] is String ? json['type'] as String : null,
        start: DateTime.tryParse(json['startDate'] as String? ?? ''),
        end: DateTime.tryParse(json['endDate'] as String? ?? ''),
        limit: (json['limit'] as num?)?.toInt(),
        name: json['name'] is String && (json['name'] as String).trim().isNotEmpty ? (json['name'] as String).trim() : null,
        field: ContactField.parse(json['field']),
      );
}

/// Where an action is on this device. Nothing leaves the app before the user confirms it.
enum PendingActionState {
  /// Waiting for the user (and, for a contact given by name, for them to pick the contact).
  awaiting,
  confirming,
  cancelling,

  /// Confirmed: WhatsApp (or the share sheet) is being opened.
  handingOff,

  /// Confirmed, but WhatsApp isn't on this phone: the user can still use the share sheet.
  whatsAppUnavailable,
  done,
  cancelled,
  failed,
}

/// How a confirmed action reaches the recipient.
enum ActionChannel {
  /// Sent by the Child Assist server with its own email account.
  email,

  /// Opened in WhatsApp on this phone; the user sends it there.
  whatsApp,
}

/// What the phone opens after a WhatsApp action was confirmed.
class ActionHandoff {
  const ActionHandoff({required this.phone, required this.message, this.documentQuery, this.documentId});

  final String phone;
  final String message;
  final String? documentQuery;

  /// For a document share: the document the user confirmed, which is exactly what is shared.
  final String? documentId;

  static ActionHandoff? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final phone = json['phone'], message = json['message'];
    if (phone is! String || message is! String) return null;
    return ActionHandoff(
      phone: phone,
      message: message,
      documentQuery: json['documentQuery'] as String?,
      documentId: json['documentId'] as String?,
    );
  }
}

/// An action with an outside effect (an email, a WhatsApp message) that only runs after the user
/// taps Confirm. Everything shown (recipient, subject, message, data summary) comes from the
/// server, which stored exactly that, so what the user confirms is what is sent.
class PendingAction {
  const PendingAction({
    required this.id,
    required this.summary,
    this.channel = ActionChannel.email,
    this.type,
    this.contactQuery,
    this.recipientName,
    this.recipientAddress,
    this.subject,
    this.message,
    this.dataSummary,
    this.documentQuery,
    this.documentId,
    this.documentName,
    this.documentType,
    this.sharedContactQuery,
    this.sharedContactName,
    this.sharedContactPhone,
    this.expiresAt,
    this.state = PendingActionState.awaiting,
    this.resultMessage,
    this.handoff,
  });

  final String id;

  /// The confirmation question, e.g. "Send this WhatsApp message to Rahul?".
  final String summary;
  final ActionChannel channel;

  /// The server's action type, e.g. SEND_EMAIL or SHARE_LOCATION.
  final String? type;

  /// The contact name to find on this phone while [recipientAddress] is not chosen yet.
  final String? contactQuery;
  final String? recipientName;

  /// An email address or phone number; null until the user picks the contact.
  final String? recipientAddress;
  final String? subject;
  final String? message;

  /// What sensitive data is included, e.g. "Today's location (3 saved locations)".
  final String? dataSummary;

  /// For a document share: words from the document's name, matched on this phone.
  final String? documentQuery;

  /// For a document share: the document the user picked on this phone (its id in the user's own
  /// document list, its file name and type label). Null until picked.
  final String? documentId;
  final String? documentName;
  final String? documentType;

  /// For sharing a contact's number: the contact whose number is shared (never the recipient),
  /// as the user named it. Found on this phone; the user picks the contact and the number.
  final String? sharedContactQuery;
  final String? sharedContactName;
  final String? sharedContactPhone;
  final DateTime? expiresAt;
  final PendingActionState state;

  /// What happened after Confirm/Cancel, shown on the card.
  final String? resultMessage;

  /// After a WhatsApp action is confirmed: what to open.
  final ActionHandoff? handoff;

  bool get isOpen => state == PendingActionState.awaiting;
  bool get isWhatsApp => channel == ActionChannel.whatsApp;
  bool get isDocumentShare => type == 'SHARE_DOCUMENT';
  bool get isContactShare => type == 'SHARE_CONTACT';

  /// The document to share still has to be picked on the phone.
  bool get needsDocument => isDocumentShare && documentId == null;

  /// The contact whose number is shared still has to be picked on the phone.
  bool get needsSharedContact => isContactShare && sharedContactPhone == null;

  /// The contact still has to be found on the phone and picked by the user.
  bool get needsRecipient => recipientAddress == null;

  /// Which contact detail the recipient needs.
  ContactField get recipientField => isWhatsApp ? ContactField.phone : ContactField.email;

  PendingAction copyWith({PendingActionState? state, String? resultMessage, ActionHandoff? handoff}) => PendingAction(
    id: id,
    summary: summary,
    channel: channel,
    type: type,
    contactQuery: contactQuery,
    recipientName: recipientName,
    recipientAddress: recipientAddress,
    subject: subject,
    message: message,
    dataSummary: dataSummary,
    documentQuery: documentQuery,
    documentId: documentId,
    documentName: documentName,
    documentType: documentType,
    sharedContactQuery: sharedContactQuery,
    sharedContactName: sharedContactName,
    sharedContactPhone: sharedContactPhone,
    expiresAt: expiresAt,
    state: state ?? this.state,
    resultMessage: resultMessage ?? this.resultMessage,
    handoff: handoff ?? this.handoff,
  );

  /// The server's latest view of this action (e.g. after the recipient was chosen), keeping
  /// what only this device knows.
  PendingAction updatedFrom(PendingAction server) => PendingAction(
    id: id,
    summary: server.summary,
    channel: server.channel,
    type: server.type,
    contactQuery: server.contactQuery,
    recipientName: server.recipientName,
    recipientAddress: server.recipientAddress,
    subject: server.subject,
    message: server.message,
    dataSummary: server.dataSummary,
    documentQuery: server.documentQuery,
    documentId: server.documentId,
    documentName: server.documentName,
    documentType: server.documentType,
    sharedContactQuery: server.sharedContactQuery,
    sharedContactName: server.sharedContactName,
    sharedContactPhone: server.sharedContactPhone,
    expiresAt: server.expiresAt,
    state: state,
    resultMessage: resultMessage,
    handoff: handoff,
  );

  static PendingAction? tryParse(Map<String, dynamic> json) {
    final id = json['id'], summary = json['summary'];
    if (id is! String || summary is! String) return null;
    String? text(String key) => json[key] is String && (json[key] as String).isNotEmpty ? json[key] as String : null;
    return PendingAction(
      id: id,
      summary: summary,
      channel: json['channel'] == 'WHATSAPP' ? ActionChannel.whatsApp : ActionChannel.email,
      type: text('type'),
      contactQuery: text('contactQuery'),
      recipientName: text('recipientName'),
      recipientAddress: text('recipientAddress'),
      subject: text('subject'),
      message: text('message'),
      dataSummary: text('dataSummary'),
      documentQuery: text('documentQuery'),
      documentId: text('documentId'),
      documentName: text('documentName'),
      documentType: text('documentType'),
      sharedContactQuery: text('sharedContactQuery'),
      sharedContactName: text('sharedContactName'),
      sharedContactPhone: text('sharedContactPhone'),
      expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? ''),
    );
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
