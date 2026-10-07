import 'package:flutter/foundation.dart';

import '../../../core/api/api_client.dart';
import '../../contacts/services/message_handoff.dart';
import '../../documents/services/document_service.dart';
import '../data/chat_api.dart' show ActionOutcome;
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

/// Where reading one document for a question to the assistant is.
enum DocumentReadPhase {
  /// Finding the document among the user's own documents on this phone.
  searching,

  /// Several documents match: the user picks one.
  choosing,

  /// Checking the document is still there and extracting its text on this phone.
  reading,

  /// The answer, written from the document's real text, was added to the chat.
  answered,

  /// It could not be read; [DocumentReadState.message] says why. Nothing was invented.
  failed,
}

class DocumentReadState {
  const DocumentReadState(this.phase, {this.result, this.document, this.message});

  final DocumentReadPhase phase;

  /// The matches to choose from while [DocumentReadPhase.choosing].
  final DocumentSearchResult? result;

  /// The document being read (once known).
  final DocumentItem? document;

  /// Why it failed, safe to show.
  final String? message;
}

/// The conversation shown on the chat screen: its messages, whether Child Assist is answering,
/// and the last error. Typed and spoken messages both go through [send].
class ChatSession extends ChangeNotifier {
  ChatSession({
    required ChatService service,
    MessageHandoff handoff = const NativeMessageHandoff(),
    DocumentService? documents,
  })  : _service = service,
        _handoff = handoff,
        _documentService = documents;

  final ChatService _service;
  final MessageHandoff _handoff;

  /// The signed-in user's own documents, for document shares. Without it, nothing is shared.
  final DocumentService? _documentService;

  static const documentUnavailableMessage = 'This document is no longer available. Nothing was shared.';

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

  /// Sets who an action goes to: the one contact address the user picked on this phone (or
  /// typed). Returns an error to show, or null when the server accepted it.
  Future<String?> chooseRecipient(String actionId, {required String address, String? name}) => _updateFromServer(
    actionId,
    () => _service.chooseRecipient(actionId, address: address, name: name, conversationId: _conversationId),
  );

  /// For sharing a contact's number: the contact and number the user picked on this phone. The
  /// server builds the message from them. Returns an error to show, or null on success.
  Future<String?> chooseSharedContact(String actionId, {required String name, required String phone}) =>
      _updateFromServer(
        actionId,
        () => _service.chooseSharedContact(actionId, name: name, phone: phone, conversationId: _conversationId),
      );

  /// For sharing a document: the one document the user picked (or the only strong match) among
  /// their own documents on this phone. Only its id, name and type go to the server. Returns an
  /// error to show, or null on success.
  Future<String?> chooseDocument(String actionId, DocumentItem document) => _updateFromServer(
    actionId,
    () => _service.chooseDocument(
      actionId,
      documentId: document.id,
      name: document.name,
      type: document.type.label,
      conversationId: _conversationId,
    ),
  );

  // -------------------------------------------------------------------------------------------
  // Reading one document for a question ("Python notes me kya hai?"). The assistant never sees
  // the user's documents: the server opens a read request, and this phone finds the document in
  // the signed-in user's own list, checks it is still there, extracts its text locally and sends
  // the text of that ONE document for the answer. Kept here, not in the card, so a card that is
  // rebuilt never reads or sends twice.

  final Map<String, DocumentReadState> _reads = {};

  /// The document being talked about, for "summarize it" / "this document" follow-ups.
  DocumentItem? _currentDocument;

  DocumentReadState? documentRead(String requestId) => _reads[requestId];

  /// Marks [document] as the one being talked about (it was found or picked in this chat).
  void rememberDocument(DocumentItem document) => _currentDocument = document;

  /// Starts reading for [requestId], once. [query] is what the user called the document; with
  /// no words and no type it means the document already being talked about.
  Future<void> startDocumentRead(String requestId, ChatLookupQuery query) async {
    if (_reads.containsKey(requestId)) return;
    _setRead(requestId, const DocumentReadState(DocumentReadPhase.searching));
    final service = _documentService;
    if (service == null) return _failRead(requestId, 'unreadable', "I couldn't read your documents.");
    final type = DocumentType.fromLabel(query.type);
    try {
      final current = _currentDocument;
      if (query.text == null && type == null && current != null) {
        // Looked up again in the user's own list: it may have been removed meanwhile.
        final document = await service.find(current.id);
        if (document == null) return _failRead(requestId, 'unavailable', documentGoneMessage);
        return _read(requestId, document);
      }
      final result = await service.search(query.text, type: type);
      switch (result.outcome) {
        case DocumentSearchOutcome.none:
          return _failRead(requestId, 'not_found', result.notFoundMessage);
        case DocumentSearchOutcome.single:
          final match = result.single!;
          if (!match.available) return _failRead(requestId, 'unavailable', documentGoneMessage, document: match.document);
          return _read(requestId, match.document);
        case DocumentSearchOutcome.multiple:
          _setRead(requestId, DocumentReadState(DocumentReadPhase.choosing, result: result));
      }
    } on DocumentException {
      return _failRead(requestId, 'unreadable', "I couldn't search your documents.");
    }
  }

  /// The user picked which of several documents they meant.
  Future<void> chooseDocumentToRead(String requestId, DocumentItem document) async {
    if (_reads[requestId]?.phase != DocumentReadPhase.choosing) return;
    await _read(requestId, document);
  }

  /// The user decided not to have a document read.
  Future<void> cancelDocumentRead(String requestId) async {
    if (_reads[requestId]?.phase != DocumentReadPhase.choosing) return;
    await _failRead(requestId, 'cancelled', "Okay, I didn't read the document.");
  }

  static const documentGoneMessage = 'This document is no longer available.';

  Future<void> _read(String requestId, DocumentItem document) async {
    final generation = _generation;
    _setRead(requestId, DocumentReadState(DocumentReadPhase.reading, document: document));
    final DocumentContent content;
    try {
      content = await _documentService!.readContent(document);
    } on DocumentUnavailableException {
      return _failRead(requestId, 'unavailable', documentGoneMessage, document: document);
    } on DocumentTextException catch (e) {
      return _failRead(requestId, e.problem.reason, e.problem.message, document: document);
    } on DocumentException {
      return _failRead(requestId, 'unreadable', "I couldn't read this document.", document: document);
    }
    _currentDocument = document;
    try {
      final answer = await _service.answerDocumentRead(
        requestId,
        documentId: document.id,
        name: document.name,
        type: document.type.label,
        text: content.text,
        truncated: content.truncated,
        conversationId: _conversationId,
      );
      if (generation != _generation) return;
      _messages = [..._messages, answer];
      _setRead(requestId, DocumentReadState(DocumentReadPhase.answered, document: document));
    } catch (e) {
      if (generation != _generation) return;
      final message = e is ApiException && e.statusCode != null
          ? e.message
          : "I couldn't get an answer about this document. Check your internet connection and ask again.";
      _setRead(requestId, DocumentReadState(DocumentReadPhase.failed, document: document, message: message));
    }
  }

  Future<void> _failRead(String requestId, String reason, String message, {DocumentItem? document}) async {
    _setRead(requestId, DocumentReadState(DocumentReadPhase.failed, document: document, message: message));
    try {
      // So the chat history says what happened too. Nothing about the file is sent.
      await _service.failDocumentRead(requestId, reason, conversationId: _conversationId);
    } catch (_) {}
  }

  void _setRead(String requestId, DocumentReadState state) {
    _reads[requestId] = state;
    notifyListeners();
  }

  Future<String?> _updateFromServer(String actionId, Future<PendingAction> Function() request) async {
    try {
      final server = await request();
      _updateAction(actionId, (a) => a.updatedFrom(server));
      return null;
    } on ApiException catch (e) {
      if (e.statusCode == 410) {
        _updateAction(actionId, (a) => a.copyWith(state: PendingActionState.failed, resultMessage: e.message));
      }
      return e.statusCode == null ? 'Check your internet connection and try again.' : e.message;
    }
  }

  /// Runs an action after the user tapped Confirm. Nothing is ever sent without this.
  ///
  /// An email is sent by the server. A WhatsApp message is opened in WhatsApp with the text
  /// ready, and the user sends it there: it is never reported as sent. A document share shares
  /// exactly the document the user confirmed, looked up in the signed-in user's own list; if it is
  /// no longer on the phone, nothing is confirmed or opened.
  Future<void> confirmAction(String actionId) async {
    final action = _findAction(actionId);
    if (action == null || !action.isOpen) return;
    _updateAction(actionId, (a) => a.copyWith(state: PendingActionState.confirming));

    DocumentItem? document;
    if (action.isDocumentShare) {
      final (found, problem) = await _confirmedDocument(action);
      if (found == null) {
        // Declined on the server too, so it can never run later.
        try {
          await _service.cancelAction(actionId, conversationId: _conversationId);
        } catch (_) {}
        _updateAction(actionId, (a) => a.copyWith(state: PendingActionState.failed, resultMessage: problem));
        return;
      }
      document = found;
    }

    final ActionOutcome outcome;
    try {
      outcome = await _service.confirmAction(actionId, conversationId: _conversationId);
    } catch (e) {
      _updateAction(actionId, (a) => a.copyWith(state: PendingActionState.failed, resultMessage: _failure(e)));
      return;
    }

    final handoff = outcome.handoff;
    if (!outcome.confirmed || handoff == null) {
      _updateAction(
        actionId,
        (a) => a.copyWith(
          state: outcome.completed ? PendingActionState.done : PendingActionState.failed,
          resultMessage: outcome.message.isNotEmpty ? outcome.message : 'Something went wrong. Nothing was sent.',
        ),
      );
      return;
    }
    if (document != null && handoff.documentId != document.id) {
      // The server confirmed a different document than the one checked here: share nothing.
      await _report(actionId, 'unavailable');
      _updateAction(
        actionId,
        (a) => a.copyWith(state: PendingActionState.failed, resultMessage: 'Something went wrong. Nothing was shared.'),
      );
      return;
    }

    _updateAction(actionId, (a) => a.copyWith(state: PendingActionState.handingOff, handoff: handoff));
    _documents[actionId] = document;
    final result = document != null
        ? await _handoff.shareDocument(
            reference: document.reference,
            mimeType: document.mimeType ?? document.type.mimeType,
            text: handoff.message.isEmpty ? null : handoff.message,
            phone: handoff.phone,
            toWhatsApp: true,
          )
        : await _handoff.openWhatsApp(phone: handoff.phone, text: handoff.message);

    if (result == HandoffResult.opened) {
      await _finishHandoff(actionId, 'whatsapp_opened', whatsApp: true);
    } else {
      await _report(actionId, 'unavailable');
      _updateAction(
        actionId,
        (a) => a.copyWith(
          state: PendingActionState.whatsAppUnavailable,
          resultMessage: "WhatsApp isn't available on this device.",
        ),
      );
    }
  }

  /// The document [action] shares, checked to still be on the phone, or null and why not. It is
  /// looked up by id in the signed-in user's own list only: an id that is not theirs finds nothing.
  Future<(DocumentItem?, String)> _confirmedDocument(PendingAction action) async {
    final service = _documentService;
    final id = action.documentId;
    if (service == null || id == null) return (null, 'Choose which document to share first.');
    try {
      final document = await service.find(id);
      if (document == null) return (null, documentUnavailableMessage);
      return (await service.refresh(document), '');
    } on DocumentUnavailableException {
      return (null, documentUnavailableMessage);
    } on DocumentException {
      return (null, "I couldn't check the document. Nothing was shared.");
    }
  }

  // The document picked for a WhatsApp share, kept for the share-sheet fallback.
  final Map<String, DocumentItem?> _documents = {};

  /// After WhatsApp was unavailable: offers the same confirmed message through the share sheet.
  Future<void> shareInstead(String actionId) async {
    final handoff = _findAction(actionId)?.handoff;
    if (handoff == null) return;
    _updateAction(actionId, (a) => a.copyWith(state: PendingActionState.handingOff));
    final document = _documents[actionId];
    final result = document != null
        ? await _handoff.shareDocument(
            reference: document.reference,
            mimeType: document.mimeType ?? document.type.mimeType,
            text: handoff.message.isEmpty ? null : handoff.message,
          )
        : await _handoff.shareText(handoff.message);
    if (result == HandoffResult.opened) {
      await _finishHandoff(actionId, 'share_opened', whatsApp: false);
    } else {
      _updateAction(
        actionId,
        (a) => a.copyWith(
          state: PendingActionState.failed,
          resultMessage: "Sharing isn't available on this device. Nothing was sent.",
        ),
      );
    }
  }

  /// Declines an action; nothing is sent.
  Future<void> cancelAction(String actionId) async {
    _updateAction(actionId, (a) => a.copyWith(state: PendingActionState.cancelling));
    try {
      final outcome = await _service.cancelAction(actionId, conversationId: _conversationId);
      _updateAction(
        actionId,
        (a) => a.copyWith(
          state: PendingActionState.cancelled,
          resultMessage: outcome.message.isNotEmpty
              ? outcome.message
              : a.isDocumentShare
                  ? "Okay, I didn't share the document."
                  : "Okay, I didn't send anything.",
        ),
      );
    } catch (e) {
      // Even if the server could not be told, nothing is sent without a confirmation.
      _updateAction(actionId, (a) => a.copyWith(state: PendingActionState.cancelled, resultMessage: 'Cancelled.'));
    }
  }

  /// Records that WhatsApp (or the share sheet) opened. Never says the message was sent: the
  /// user sends it there.
  Future<void> _finishHandoff(String actionId, String result, {required bool whatsApp}) async {
    final action = _findAction(actionId);
    final name = action?.recipientName ?? 'your contact';
    var message = action?.isDocumentShare == true
        ? whatsApp
            ? 'WhatsApp opened. Please tap Send to send the document.'
            : 'Share options opened. Nothing is sent until you send the document from the app you choose.'
        : whatsApp
            ? 'WhatsApp opened for $name with your message. Tap Send in WhatsApp to deliver it.'
            : 'Share options opened for $name. Nothing is sent until you send it from the app you choose.';
    try {
      final outcome = await _service.reportHandoff(actionId, result, conversationId: _conversationId);
      if (outcome.message.isNotEmpty) message = outcome.message;
    } catch (_) {
      // It did open; the report only updates the chat history.
    }
    _documents.remove(actionId);
    _updateAction(actionId, (a) => a.copyWith(state: PendingActionState.done, resultMessage: message));
  }

  Future<void> _report(String actionId, String result) async {
    try {
      await _service.reportHandoff(actionId, result, conversationId: _conversationId);
    } catch (_) {}
  }

  static String _failure(Object e) => e is ApiException && (e.statusCode == 409 || e.statusCode == 410)
      ? e.message
      : 'Something went wrong. Nothing was sent.';

  PendingAction? _findAction(String actionId) {
    for (final m in _messages) {
      for (final a in m.pendingActions) {
        if (a.id == actionId) return a;
      }
    }
    return null;
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
    _currentDocument = null;
  }
}
