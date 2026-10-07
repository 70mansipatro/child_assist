import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';
import '../models/chat_conversation.dart';
import '../services/chat_service.dart';
import '../widgets/chat_message_bubble.dart' show chatTimeLabel;

/// The user's earlier chats, most recent first. Tapping one returns its ID so the chat screen
/// can open and continue it.
class ChatHistoryScreen extends StatefulWidget {
  const ChatHistoryScreen({
    super.key,
    required this.chatService,
    required this.onDeleted,
    this.currentConversationId,
  });

  final ChatService chatService;

  /// Told about each deleted conversation, so an open chat that was deleted is cleared.
  final ValueChanged<String> onDeleted;
  final String? currentConversationId;

  @override
  State<ChatHistoryScreen> createState() => _ChatHistoryScreenState();
}

class _ChatHistoryScreenState extends State<ChatHistoryScreen> {
  List<ChatConversation>? _conversations;
  bool _failed = false;
  final Set<String> _deleting = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final conversations = await widget.chatService.listConversations();
      if (mounted) setState(() => _conversations = conversations);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _delete(ChatConversation conversation) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this conversation?'),
        content: Text('"${conversation.displayTitle}" and all its messages will be removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deleting.add(conversation.id));
    try {
      await widget.chatService.deleteConversation(conversation.id);
      widget.onDeleted(conversation.id);
      if (!mounted) return;
      setState(() => _conversations = _conversations?.where((c) => c.id != conversation.id).toList());
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Conversation deleted')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Something went wrong. Please try again.')),
      );
    } finally {
      if (mounted) setState(() => _deleting.remove(conversation.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final conversations = _conversations;
    return Scaffold(
      appBar: AppBar(title: const Text('Chat History')),
      body: SafeArea(
        child: switch (conversations) {
          _ when _failed => StateMessage(
              icon: Icons.cloud_off_rounded,
              gradient: AppGradients.danger,
              title: 'Something went wrong. Please try again.',
              action: GradientButton(onPressed: _load, label: const Text('Retry')),
            ),
          null => const Center(child: CircularProgressIndicator()),
          [] => const StateMessage(
              icon: Icons.forum_outlined,
              gradient: AppGradients.brand,
              title: 'No conversations yet.',
              body: 'Your chats with Child Assist will appear here.',
            ),
          final conversations => RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: conversations.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) => _ConversationTile(
                  conversation: conversations[i],
                  current: conversations[i].id == widget.currentConversationId,
                  deleting: _deleting.contains(conversations[i].id),
                  onOpen: () => Navigator.of(context).pop(conversations[i].id),
                  onDelete: () => _delete(conversations[i]),
                ),
              ),
            ),
        },
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    required this.current,
    required this.deleting,
    required this.onOpen,
    required this.onDelete,
  });

  final ChatConversation conversation;
  final bool current;
  final bool deleting;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      onTap: deleting ? null : onOpen,
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      child: Row(
        children: [
          const IconBadge(icon: Icons.chat_bubble_rounded, gradient: AppGradients.brand, size: 40, iconSize: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  conversation.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  current
                      ? 'Open now · ${chatTimeLabel(context, conversation.updatedAt)}'
                      : chatTimeLabel(context, conversation.updatedAt),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          deleting
              ? const Padding(padding: EdgeInsets.all(12), child: ButtonSpinner(size: 20, color: AppColors.danger))
              : IconButton(
                  tooltip: 'Delete conversation',
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
        ],
      ),
    );
  }
}
