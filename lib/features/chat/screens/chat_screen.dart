import 'package:flutter/material.dart';

import '../../../core/permissions/permission_service.dart';
import '../../../core/widgets/widgets.dart';
import '../../documents/screens/document_viewer_screen.dart';
import '../../documents/screens/documents_screen.dart';
import '../../documents/services/document_service.dart';
import '../../permissions/screens/permissions_screen.dart';
import '../../permissions/services/permission_sync_service.dart';
import '../../photos/screens/photo_viewer_screen.dart';
import '../../photos/services/photo_gallery_service.dart';
import '../services/chat_service.dart';
import '../models/chat_message.dart';
import '../services/chat_session.dart';
import '../services/text_to_speech_service.dart';
import '../services/voice_chat_controller.dart';
import '../services/voice_input.dart';
import '../widgets/chat_input.dart';
import '../widgets/chat_message_bubble.dart';
import '../widgets/tool_result_cards.dart';
import '../widgets/typing_indicator.dart';
import 'chat_history_screen.dart';

/// Chat with Child Assist. All AI work happens on the server; this screen only sends text,
/// shows replies, and runs photo/document searches locally when the server asks it to.
/// Spoken messages are turned into text on the device and sent exactly like typed ones.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.chatService,
    required this.documentService,
    required this.galleryService,
    required this.permissionService,
    required this.permissionSyncService,
    required this.textToSpeech,
    this.voiceInput = const UnavailableVoiceInput(),
    this.active = true,
  });

  final ChatService chatService;
  final DocumentService documentService;
  final PhotoGalleryService galleryService;
  final PermissionService permissionService;
  final PermissionSyncService permissionSyncService;
  final VoiceInput voiceInput;
  final TextToSpeechService textToSpeech;

  /// False while another bottom-navigation tab is showing. Leaving the tab stops the
  /// microphone and any speech, just like leaving the app.
  final bool active;

  static const suggestions = [
    'Where did I go yesterday?',
    'Find my math notes',
    'What can you do?',
  ];

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final ChatSession _session = ChatSession(service: widget.chatService);
  final _input = TextEditingController();
  final _focus = FocusNode();

  late final ChatResultContext _results = ChatResultContext(
    documentService: widget.documentService,
    galleryService: widget.galleryService,
    onOpenPermissions: () => _push(
      PermissionsScreen(permissionService: widget.permissionService, syncService: widget.permissionSyncService),
    ),
    onOpenDocuments: () => _push(DocumentsScreen(documentService: widget.documentService)),
    onOpenDocument: (document) =>
        _push(DocumentViewerScreen(document: document, documentService: widget.documentService)),
    onOpenPhoto: (photo) => _push(PhotoViewerScreen(photo: photo, galleryService: widget.galleryService)),
    onConfirmAction: (id) => _session.confirmAction(id),
    onCancelAction: (id) => _session.cancelAction(id),
  );

  late final VoiceChatController _voice = VoiceChatController(
    voiceInput: widget.voiceInput,
    textToSpeech: widget.textToSpeech,
    permissionService: widget.permissionService,
    permissionSyncService: widget.permissionSyncService,
    send: _sendAndGetReply,
    explainPermission: _explainMicrophone,
  );

  // Leaving the app stops the microphone and any speech: voice is foreground-only.
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(onHide: _voice.interrupt);

  @override
  void initState() {
    super.initState();
    _lifecycle;
  }

  @override
  void didUpdateWidget(ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) {
      _focus.unfocus();
      _voice.interrupt();
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _voice.dispose();
    _session.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _push(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  void _send(String text) => _voice.send(text);

  /// The one chat send used for typed and spoken messages; returns the new reply, if any.
  Future<ChatMessage?> _sendAndGetReply(String text) async {
    final before = _session.messages.lastOrNull?.id;
    await _session.send(text);
    final last = _session.messages.lastOrNull;
    return last != null && !last.isUser && last.id != before ? last : null;
  }

  void _newChat() {
    _voice.interrupt();
    _session.newChat();
    _input.clear();
    _focus.requestFocus();
  }

  Future<void> _openHistory() async {
    final id = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ChatHistoryScreen(
          chatService: widget.chatService,
          currentConversationId: _session.conversationId,
          onDeleted: _session.conversationDeleted,
        ),
      ),
    );
    if (id != null && mounted) {
      await _voice.interrupt();
      await _session.open(id);
    }
  }

  void _microphone() {
    _focus.unfocus();
    _voice.toggleListening();
  }

  /// Shown before the system microphone dialog, so the user knows why it is asked for.
  Future<bool> _explainMicrophone() async {
    final allowed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const IconBadge(icon: Icons.mic_rounded, gradient: AppGradients.brand, size: 52),
        title: const Text('Talk to Child Assist?'),
        content: const Text(
          'Child Assist uses your microphone only while you tap the voice button, so it can understand '
          'what you say. Only the words are sent to Child Assist, never a recording.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Continue')),
        ],
      ),
    );
    return allowed == true;
  }

  // No snack bar: it would cover the microphone button. The icon itself shows the state.
  void _toggleVoiceReplies() => _voice.repliesEnabled = !_voice.repliesEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: const AppBarGradient(),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // A frosted tile, like the Dashboard logo, so the avatar stands out on the purple bar.
            Semantics(
              label: 'Child Assist',
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
                ),
                child: const Icon(Icons.smart_toy_rounded, size: 20, color: Colors.white),
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Child Assist',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                  Text(
                    'Your personal assistant',
                    style: theme.textTheme.bodySmall?.copyWith(color: Colors.white.withValues(alpha: 0.8)),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (widget.textToSpeech.isAvailable)
            ListenableBuilder(
              listenable: _voice,
              builder: (context, _) => IconButton(
                tooltip: _voice.repliesEnabled ? 'Voice replies: on' : 'Voice replies: off',
                onPressed: _toggleVoiceReplies,
                icon: Icon(_voice.repliesEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded),
              ),
            ),
          IconButton(tooltip: 'New Chat', onPressed: _newChat, icon: const Icon(Icons.add_comment_rounded)),
          IconButton(tooltip: 'History', onPressed: _openHistory, icon: const Icon(Icons.history_rounded)),
          const SizedBox(width: 4),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([_session, _voice]),
        builder: (context, _) => Column(
          children: [
            Expanded(child: _buildBody(context)),
            if (_session.error != null) _buildError(),
            ?_buildVoiceStatus(context),
            ChatInput(
              controller: _input,
              focusNode: _focus,
              enabled: !_session.isSending,
              voiceState: _voice.state,
              onSend: _send,
              onMicrophone: _microphone,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_session.isLoading) return const Center(child: CircularProgressIndicator());
    if (_session.messages.isEmpty && !_session.isSending) return _Welcome(onSuggestion: _send);

    final messages = _session.messages;
    final typing = _session.isSending;
    // Reversed so the newest message sits at the bottom and the list starts scrolled there.
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      itemCount: messages.length + (typing ? 1 : 0),
      // New messages shift every index; this lets each message keep its state (e.g. a photo
      // search result) instead of being rebuilt from scratch.
      findChildIndexCallback: (key) {
        if (key is! ValueKey<String>) return null;
        final index = messages.indexWhere((m) => m.id == key.value);
        return index < 0 ? null : messages.length - 1 - index + (typing ? 1 : 0);
      },
      itemBuilder: (context, i) {
        if (typing && i == 0) return TypingIndicator(activeTool: _session.activeTool);
        final message = messages[messages.length - 1 - (i - (typing ? 1 : 0))];
        return Center(
          key: ValueKey(message.id),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: ChatMessageBubble(
              message: message,
              results: _results,
              onSpeak: _voice.canSpeak && !message.isUser ? () => _voice.toggleSpeaking(message) : null,
              speaking: _voice.speakingMessageId == message.id,
            ),
          ),
        );
      },
    );
  }

  /// "Listening..." with the words heard so far, "Processing...", or a friendly voice error.
  Widget? _buildVoiceStatus(BuildContext context) {
    final theme = Theme.of(context);
    final Widget banner;
    switch (_voice.state) {
      case VoiceState.listening || VoiceState.processing:
        final listening = _voice.state == VoiceState.listening;
        final heard = _voice.transcript;
        banner = InfoBanner(
          icon: listening ? Icons.mic_rounded : Icons.hourglass_top_rounded,
          title: listening ? 'Listening...' : 'Processing...',
          message: Semantics(
            liveRegion: true,
            child: Text(
              heard.isNotEmpty ? heard : (listening ? 'Tap to stop when you are done.' : 'One moment.'),
              style: heard.isNotEmpty ? theme.textTheme.bodyLarge : null,
            ),
          ),
        );
      case VoiceState.error:
        final kind = _voice.error ?? VoiceErrorKind.unknown;
        banner = InfoBanner(
          tone: BannerTone.warning,
          icon: Icons.mic_off_rounded,
          message: Text(kind.message),
          actions: [
            if (kind == VoiceErrorKind.permissionBlocked || kind == VoiceErrorKind.permissionDenied)
              FilledButton(
                onPressed: () {
                  _voice.dismissError();
                  _results.onOpenPermissions();
                },
                child: const Text('Open Permissions'),
              )
            else if (kind != VoiceErrorKind.unavailable)
              FilledButton(onPressed: _voice.startListening, child: const Text('Try again')),
            TextButton(onPressed: _voice.dismissError, child: const Text('OK')),
          ],
        );
      case VoiceState.idle || VoiceState.requestingPermission || VoiceState.speaking:
        return null;
    }
    return Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 10), child: banner);
  }

  Widget _buildError() {
    final error = _session.error!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: InfoBanner(
        tone: BannerTone.danger,
        title: 'Something went wrong. Please try again.',
        message: Text(error.detail),
        actions: [
          if (_session.canRetry) FilledButton(onPressed: _session.retry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onSuggestion});

  final ValueChanged<String> onSuggestion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            children: [
              const PopIn(child: AssistantAvatar(size: 72)),
              const SizedBox(height: 18),
              FadeSlideIn(
                child: Text('Hey! 👋', textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
              ),
              const SizedBox(height: 8),
              FadeSlideIn(
                index: 1,
                child: Text(
                  'How can I help you today?',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: 24),
              for (final (i, prompt) in ChatScreen.suggestions.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: FadeSlideIn(
                    index: i + 2,
                    child: AppCard(
                      onTap: () => onSuggestion(prompt),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      radius: AppSpacing.radius,
                      child: Row(
                        children: [
                          Icon(Icons.auto_awesome_rounded, size: 18, color: theme.colorScheme.primary),
                          const SizedBox(width: 12),
                          Expanded(child: Text(prompt, style: theme.textTheme.bodyLarge)),
                          Icon(Icons.north_east_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

