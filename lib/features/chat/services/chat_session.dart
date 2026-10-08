import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show DateTimeRange, DateUtils;

import '../../../core/api/api_client.dart';
import '../../../core/permissions/permission_service.dart' show PermissionState;
import '../../contacts/services/message_handoff.dart';
import '../../documents/services/document_service.dart';
import '../../photos/services/photo_gallery_service.dart';
import '../../photos/services/photo_matcher.dart';
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

/// Where a photo search on this phone is.
enum PhotoSearchPhase { searching, found, none, permission, failed }

class PhotoSearchState {
  const PhotoSearchState(
    this.phase, {
    this.photos = const [],
    this.total = 0,
    this.message,
    this.limited = false,
    this.selectedId,
    this.contentHint = false,
    this.analyses = const {},
  });

  final PhotoSearchPhase phase;

  /// The strong matches shown, strongest first, each with the server's opaque id.
  final List<ChatPhoto> photos;
  final int total;

  /// What to tell the user when nothing was found or something failed.
  final String? message;

  /// The OS only lets Child Assist see the photos the user selected.
  final bool limited;

  /// The photo the user picked among several.
  final String? selectedId;

  /// The user described what is IN the photo, which cannot be searched for.
  final bool contentHint;

  /// Photos being looked at automatically because the user asked about them: photo id to the
  /// analysis request id. Such a photo shows the analysis instead of an Analyze button.
  final Map<String, String> analyses;

  PhotoSearchState selecting(String id, {PhotoAnalysisTicket? analysis}) => PhotoSearchState(
        phase,
        photos: photos,
        total: total,
        message: message,
        limited: limited,
        selectedId: id,
        contentHint: contentHint,
        analyses: analysis == null ? analyses : {...analyses, analysis.photoId: analysis.requestId},
      );
}

/// Where looking at one photo for a question is.
enum PhotoAnalysisPhase { analyzing, answered, failed }

class PhotoAnalysisState {
  const PhotoAnalysisState(this.phase, {this.photo, this.message});

  final PhotoAnalysisPhase phase;
  final ChatPhoto? photo;
  final String? message;
}

/// The conversation shown on the chat screen: its messages, whether Child Assist is answering,
/// and the last error. Typed and spoken messages both go through [send].
class ChatSession extends ChangeNotifier {
  ChatSession({
    required ChatService service,
    MessageHandoff handoff = const NativeMessageHandoff(),
    DocumentService? documents,
    PhotoGalleryService? photos,
  })  : _service = service,
        _handoff = handoff,
        _documentService = documents,
        _gallery = photos;

  final ChatService _service;
  final MessageHandoff _handoff;

  /// The signed-in user's own documents, for document shares. Without it, nothing is shared.
  final DocumentService? _documentService;

  /// The phone's own gallery, for photo searches, analysis and shares. Without it, none run.
  final PhotoGalleryService? _gallery;

  static const documentUnavailableMessage = 'This document is no longer available. Nothing was shared.';

  /// Called with an answer that arrives after its turn, such as what a photo shows once the phone
  /// sent it, so it can be read aloud like any other reply.
  void Function(ChatMessage message)? onLateReply;

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

  // -------------------------------------------------------------------------------------------
  // Photos. The gallery never leaves the phone: the server asks this phone to search it, this
  // phone shows the strong matches and reports only their metadata, and the server gives each an
  // opaque id (photo_...). This map from those ids to gallery entries stays on this phone. For a
  // question about a photo, only that ONE photo is sent, scaled down, for Gemini vision.

  static const photoUnavailableMessage = 'This photo is no longer available on your device.';
  static const photoNotFoundMessage = "I couldn't find a matching photo in your available photos.";

  final Map<String, ChatPhoto> _photos = {};
  final Map<String, PhotoSearchState> _photoSearches = {};
  final Map<String, PhotoAnalysisState> _photoAnalyses = {};

  /// Pages of the gallery read for one search at most (the newest photos first).
  static const _maxSearchPages = 10;

  /// Photos whose GPS position is read for one location search at most.
  static const _maxPositions = 300;

  PhotoSearchState? photoSearch(String requestId) => _photoSearches[requestId];
  PhotoAnalysisState? photoAnalysis(String requestId) => _photoAnalyses[requestId];

  /// A photo shown in this chat, by the server's opaque id.
  ChatPhoto? photo(String photoId) => _photos[photoId];

  /// Searches this phone's gallery for [requestId], once, and reports what it shows.
  Future<void> startPhotoSearch(String requestId, PhotoSearchQuery query) async {
    if (_photoSearches.containsKey(requestId)) return;
    _setPhotoSearch(requestId, const PhotoSearchState(PhotoSearchPhase.searching));
    final gallery = _gallery;
    final contentHint = query.visualHint != null;
    if (gallery == null) return _photoSearchFailed(requestId, "I couldn't read the photos on your phone.");

    final permission = await gallery.permissionStatus();
    if (!permission.isUsable) {
      await _reportPhotoSearch(requestId, 'permission_denied');
      _setPhotoSearch(requestId, const PhotoSearchState(PhotoSearchPhase.permission));
      return;
    }
    final limited = permission == PermissionState.limited;

    final PhotoMatchResult result;
    try {
      // Every search reads the gallery as it is now: photos taken, added or deleted since the
      // last one count, and nothing listed earlier is trusted.
      gallery.reset();
      final photos = await _loadCandidates(gallery, query);
      final positions = <String, PhotoPosition?>{};
      if (query.locationContext && query.visits.isNotEmpty) {
        for (final p in photos.take(_maxPositions)) {
          positions[p.id] = await gallery.location(p);
        }
      }
      result = await _readableMatches(gallery, photos, query, positions);
    } on PhotoGalleryException {
      await _reportPhotoSearch(requestId, 'failed');
      return _photoSearchFailed(requestId, "I couldn't read the photos on your phone.");
    }

    if (result.matches.isEmpty) {
      await _reportPhotoSearch(requestId, 'none', reason: result.reason?.wire, limited: limited);
      _setPhotoSearch(
        requestId,
        PhotoSearchState(
          PhotoSearchPhase.none,
          message: _noMatchMessage(result.reason, limited),
          limited: limited,
          contentHint: contentHint,
        ),
      );
      return;
    }

    final ({List<String> ids, PhotoAnalysisTicket? analysis}) reported;
    try {
      reported = await _service.reportPhotoSearch(
        requestId,
        outcome: 'found',
        photos: [for (final m in result.matches) m.toReport()],
        total: result.total,
        limited: limited,
        conversationId: _conversationId,
      );
    } catch (e) {
      return _photoSearchFailed(
        requestId,
        e is ApiException && e.statusCode != null
            ? e.message
            : "I couldn't finish finding your photo. Check your internet connection and ask again.",
      );
    }
    final shown = [for (final (i, m) in result.matches.indexed) m.withId(reported.ids[i])];
    for (final p in shown) {
      _photos[p.id!] = p;
    }
    final analysis = reported.analysis;
    _setPhotoSearch(
      requestId,
      PhotoSearchState(
        PhotoSearchPhase.found,
        photos: shown,
        total: result.total,
        limited: limited,
        selectedId: shown.length == 1 ? shown.single.id : null,
        contentHint: contentHint,
        analyses: analysis == null ? const {} : {analysis.photoId: analysis.requestId},
      ),
    );
    // "Find it and explain it": the one photo found is looked at now, no Analyze tap.
    if (analysis != null) await startPhotoAnalysis(analysis.requestId, analysis.photoId);
  }

  /// The user picked one of several photos: it becomes the photo being talked about.
  /// Returns an error to show, or null.
  Future<String?> choosePhoto(String requestId, ChatPhoto photo) async {
    final state = _photoSearches[requestId];
    if (state == null || photo.id == null) return null;
    final PhotoAnalysisTicket? analysis;
    try {
      analysis = await _service.selectPhoto(photo.id!, conversationId: _conversationId);
    } on ApiException catch (e) {
      return e.statusCode == null ? 'Check your internet connection and try again.' : e.message;
    }
    _setPhotoSearch(requestId, (_photoSearches[requestId] ?? state).selecting(photo.id!, analysis: analysis));
    // They had asked about the photo ("explain it"): the one they picked is looked at now.
    if (analysis != null) unawaited(startPhotoAnalysis(analysis.requestId, analysis.photoId));
    return null;
  }

  /// "Analyze" on a photo card: makes it the photo being talked about, then asks about it.
  Future<void> analyzePhoto(ChatPhoto photo) async {
    if (photo.id == null || _sending) return;
    PhotoAnalysisTicket? analysis;
    try {
      analysis = await _service.selectPhoto(photo.id!, conversationId: _conversationId);
    } catch (_) {
      // The question still goes through; the server then uses the photo it last knew about.
    }
    // A question about this photo was already waiting: answer that one instead of asking again.
    if (analysis != null) return startPhotoAnalysis(analysis.requestId, analysis.photoId);
    await send('What is in this photo?');
  }

  /// Sends the one photo [photoId] for [requestId], once, so the answer comes from the image.
  Future<void> startPhotoAnalysis(String requestId, String photoId) async {
    if (_photoAnalyses.containsKey(requestId)) return;
    final generation = _generation;
    final photo = _photos[photoId];
    _setPhotoAnalysis(requestId, PhotoAnalysisState(PhotoAnalysisPhase.analyzing, photo: photo));
    final gallery = _gallery;
    // Not shown on this phone in this session (e.g. after the app restarted): never guessed.
    if (photo == null || gallery == null) return _failAnalysis(requestId, 'unavailable', photoUnavailableMessage);

    if (!(await gallery.permissionStatus()).isUsable) {
      return _failAnalysis(requestId, 'permission', "I can't access your photos because Photos permission is turned off.", photo: photo);
    }
    if (!await gallery.exists(photo.item)) return _failAnalysis(requestId, 'unavailable', photoUnavailableMessage, photo: photo);
    final bytes = await gallery.analysisImage(photo.item);
    if (bytes == null || bytes.isEmpty) return _failAnalysis(requestId, 'unavailable', photoUnavailableMessage, photo: photo);

    try {
      final answer = await _service.answerPhotoAnalysis(
        requestId,
        photoId: photoId,
        imageBase64: base64Encode(bytes),
        conversationId: _conversationId,
      );
      if (generation != _generation) return;
      _messages = [..._messages, answer];
      _setPhotoAnalysis(requestId, PhotoAnalysisState(PhotoAnalysisPhase.answered, photo: photo));
      onLateReply?.call(answer);
    } catch (e) {
      if (generation != _generation) return;
      final message = e is ApiException && e.statusCode != null
          ? e.message
          : "I couldn't look at the photo. Check your internet connection and ask again.";
      _setPhotoAnalysis(requestId, PhotoAnalysisState(PhotoAnalysisPhase.failed, photo: photo, message: message));
    }
  }

  /// Shares [photo] after the user confirmed on its card: WhatsApp or the share sheet opens and
  /// the user sends it there. Returns what to show; never says it was sent.
  Future<String> sharePhoto(ChatPhoto photo, {required bool toWhatsApp, String? phone, String? text}) async {
    final gallery = _gallery;
    if (gallery == null || !await gallery.exists(photo.item)) return photoUnavailableMessage;
    final reference = await gallery.shareReference(photo.item);
    if (reference == null) return photoUnavailableMessage;
    final result = await _handoff.shareDocument(
      reference: reference,
      mimeType: photo.item.mimeType ?? 'image/jpeg',
      text: text,
      phone: phone,
      toWhatsApp: toWhatsApp,
    );
    return switch ((result, toWhatsApp)) {
      (HandoffResult.opened, true) => 'WhatsApp opened. Tap Send to complete it.',
      (HandoffResult.opened, false) => 'Share options opened. Nothing is sent until you send the photo from the app you choose.',
      (_, true) => "WhatsApp isn't available on this device. Nothing was shared.",
      (_, false) => "Sharing isn't available on this device. Nothing was shared.",
    };
  }

  Future<List<PhotoItem>> _loadCandidates(PhotoGalleryService gallery, PhotoSearchQuery query) async {
    final start = query.start?.toLocal();
    final end = query.end?.toLocal();
    DateTimeRange? range;
    if (start != null && end != null && end.isAfter(start)) {
      // The gallery's range end is a whole day; the exact bounds are applied by the matcher.
      range = DateTimeRange(start: start, end: DateUtils.dateOnly(end.subtract(const Duration(microseconds: 1))));
    }
    final deep = range != null || query.fileName != null || query.locationContext;
    // "My latest / recent photo": the newest by when each photo was actually taken.
    if (!deep) return gallery.loadNewest();
    const pages = _maxSearchPages;
    final photos = <PhotoItem>[];
    for (var i = 0; i < pages; i++) {
      final page = await gallery.loadPage(i, range: range);
      photos.addAll(page);
      if (page.length < gallery.pageSize) break;
    }
    return photos;
  }

  /// The matches for [query], leaving out photos that can no longer be read (deleted since, or
  /// listed by the OS but unreadable), so "the latest photo" is the newest one that can be shown.
  Future<PhotoMatchResult> _readableMatches(
    PhotoGalleryService gallery,
    List<PhotoItem> photos,
    PhotoSearchQuery query,
    Map<String, PhotoPosition?> positions,
  ) async {
    final gone = <String>{};
    var result = PhotoMatcher.match(photos, query, positions: positions);
    for (var attempt = 0; attempt < _maxReadableRetries; attempt++) {
      final unreadable = <String>{
        for (final m in result.matches)
          if (!await gallery.isReadable(m.item)) m.item.id,
      };
      if (unreadable.isEmpty) return result;
      gone.addAll(unreadable);
      result = PhotoMatcher.match([for (final p in photos) if (!gone.contains(p.id)) p], query, positions: positions);
    }
    // Still finding unreadable ones: show only those that could be read, never a broken one.
    final readable = [
      for (final m in result.matches)
        if (await gallery.isReadable(m.item)) m,
    ];
    return PhotoMatchResult(readable, total: readable.isEmpty ? 0 : result.total, reason: result.reason);
  }

  /// Rounds of skipping unreadable photos for one search at most.
  static const _maxReadableRetries = 5;

  static String _noMatchMessage(PhotoNoMatchReason? reason, bool limited) {
    final parts = [
      photoNotFoundMessage,
      switch (reason) {
        PhotoNoMatchReason.noVisits => 'There are no saved locations for that time, so I couldn\'t match a photo to where you went.',
        PhotoNoMatchReason.contentOnly =>
          "I can search your photos by date, by the places you saved, or by file name, but I can't look inside every photo. Open a photo and ask me what's in it.",
        PhotoNoMatchReason.noNameMatch => 'None of the photo names match that.',
        null => null,
      },
      if (limited) 'Child Assist can only see the photos you allowed it to access.',
    ];
    return parts.whereType<String>().join(' ');
  }

  Future<void> _reportPhotoSearch(String requestId, String outcome, {String? reason, bool limited = false}) async {
    try {
      // So the chat history says what happened too. No photo data is sent.
      await _service.reportPhotoSearch(requestId, outcome: outcome, reason: reason, limited: limited, conversationId: _conversationId);
    } catch (_) {}
  }

  void _photoSearchFailed(String requestId, String message) =>
      _setPhotoSearch(requestId, PhotoSearchState(PhotoSearchPhase.failed, message: message));

  Future<void> _failAnalysis(String requestId, String reason, String message, {ChatPhoto? photo}) async {
    _setPhotoAnalysis(requestId, PhotoAnalysisState(PhotoAnalysisPhase.failed, photo: photo, message: message));
    try {
      await _service.failPhotoAnalysis(requestId, reason, conversationId: _conversationId);
    } catch (_) {}
  }

  void _setPhotoSearch(String requestId, PhotoSearchState state) {
    _photoSearches[requestId] = state;
    notifyListeners();
  }

  void _setPhotoAnalysis(String requestId, PhotoAnalysisState state) {
    _photoAnalyses[requestId] = state;
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

    ChatPhoto? photo;
    if (action.isPhotoShare) {
      photo = action.photoId == null ? null : _photos[action.photoId!];
      final gallery = _gallery;
      if (photo == null || gallery == null || !await gallery.exists(photo.item)) {
        // Declined on the server too, so it can never run later.
        try {
          await _service.cancelAction(actionId, conversationId: _conversationId);
        } catch (_) {}
        _updateAction(actionId, (a) => a.copyWith(state: PendingActionState.failed, resultMessage: photoUnavailableMessage));
        return;
      }
    }

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

    if (photo != null && handoff.photoId != photo.id) {
      // The server confirmed a different photo than the one checked here: share nothing.
      await _report(actionId, 'unavailable');
      _updateAction(
        actionId,
        (a) => a.copyWith(state: PendingActionState.failed, resultMessage: 'Something went wrong. Nothing was shared.'),
      );
      return;
    }

    _updateAction(actionId, (a) => a.copyWith(state: PendingActionState.handingOff, handoff: handoff));
    _documents[actionId] = document;
    if (photo != null) {
      _photoShares[actionId] = photo;
      final reference = await _gallery!.shareReference(photo.item);
      final opened = reference != null &&
          await _handoff.shareDocument(
                reference: reference,
                mimeType: photo.item.mimeType ?? 'image/jpeg',
                text: handoff.message.isEmpty ? null : handoff.message,
                phone: handoff.phone,
                toWhatsApp: true,
              ) ==
              HandoffResult.opened;
      if (opened) {
        await _finishHandoff(actionId, 'whatsapp_opened', whatsApp: true);
      } else {
        await _report(actionId, 'unavailable');
        _updateAction(
          actionId,
          (a) => a.copyWith(state: PendingActionState.whatsAppUnavailable, resultMessage: "WhatsApp isn't available on this device."),
        );
      }
      return;
    }
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

  // Likewise the photo of a confirmed photo share.
  final Map<String, ChatPhoto> _photoShares = {};

  /// After WhatsApp was unavailable: offers the same confirmed message through the share sheet.
  Future<void> shareInstead(String actionId) async {
    final handoff = _findAction(actionId)?.handoff;
    if (handoff == null) return;
    _updateAction(actionId, (a) => a.copyWith(state: PendingActionState.handingOff));
    final document = _documents[actionId];
    final photo = _photoShares[actionId];
    final photoReference = photo == null ? null : await _gallery?.shareReference(photo.item);
    final result = photo != null
        ? (photoReference == null
            ? HandoffResult.unavailable
            : await _handoff.shareDocument(
                reference: photoReference,
                mimeType: photo.item.mimeType ?? 'image/jpeg',
                text: handoff.message.isEmpty ? null : handoff.message,
              ))
        : document != null
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
              : a.isPhotoShare
                  ? "Okay, I didn't share the photo."
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
    var message = action?.isPhotoShare == true
        ? whatsApp
            ? 'WhatsApp opened. Tap Send to complete it.'
            : 'Share options opened. Nothing is sent until you send the photo from the app you choose.'
        : action?.isDocumentShare == true
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
    _photoShares.remove(actionId);
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
