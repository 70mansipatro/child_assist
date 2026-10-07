/// One saved chat with Child Assist, as listed in Chat History.
class ChatConversation {
  const ChatConversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;

  /// Null until the server has named the chat after its first meaningful message.
  final String? title;
  final DateTime createdAt;

  /// When the last message was added; History lists the most recent first.
  final DateTime updatedAt;

  String get displayTitle => (title == null || title!.trim().isEmpty) ? 'New Chat' : title!;

  factory ChatConversation.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final created = DateTime.tryParse(json['createdAt'] as String? ?? '');
    final updated = DateTime.tryParse(json['updatedAt'] as String? ?? '');
    if (id is! String || created == null || updated == null) {
      throw const FormatException('Invalid conversation');
    }
    return ChatConversation(
      id: id,
      title: json['title'] as String?,
      createdAt: created,
      updatedAt: updated,
    );
  }
}
