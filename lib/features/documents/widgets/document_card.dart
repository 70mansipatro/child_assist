import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';
import '../../photos/screens/photo_viewer_screen.dart' show fileSizeLabel;
import '../models/document_item.dart';

/// "Oct 6, 2026" in the device locale's month/day style.
String documentDateLabel(BuildContext context, DateTime date) {
  final l10n = MaterialLocalizations.of(context);
  final local = date.toLocal();
  return '${l10n.formatShortMonthDay(local)}, ${l10n.formatYear(local)}';
}

/// "Modified Oct 6, 2026", or "Added ..." when the platform did not report a modified date.
String documentDateText(BuildContext context, DocumentItem document) =>
    '${document.isModifiedDate ? 'Modified' : 'Added'} ${documentDateLabel(context, document.date)}';

/// "240 KB · Modified Oct 6, 2026", leaving out anything the platform did not report.
String documentSubtitle(BuildContext context, DocumentItem document) => [
      if (document.size != null) fileSizeLabel(document.size!),
      documentDateText(context, document),
    ].join(' · ');

/// A rounded tile with the document type written on it ("PDF", "DOCX"), so the type never
/// depends on colour alone.
class DocumentTypeBadge extends StatelessWidget {
  const DocumentTypeBadge({super.key, required this.type, this.size = 48});

  final DocumentType type;
  final double size;

  static LinearGradient gradientFor(DocumentType type) => switch (type) {
        DocumentType.pdf => AppGradients.danger,
        DocumentType.doc || DocumentType.docx => AppGradients.documents,
        DocumentType.txt => const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF8A94B8), Color(0xFF59618A)],
          ),
      };

  @override
  Widget build(BuildContext context) {
    final gradient = gradientFor(type);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(size * 0.3),
          boxShadow: AppTheme.glow(gradient.colors.last, strength: 0.45),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.description_rounded, color: Colors.white.withValues(alpha: 0.9), size: size * 0.34),
            Text(
              type.label,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: size * 0.21,
                height: 1.1,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One document in the list: type, name, size and date. Tapping opens it; the menu removes it.
class DocumentCard extends StatelessWidget {
  const DocumentCard({
    super.key,
    required this.document,
    required this.onTap,
    required this.onRemove,
    this.unavailable = false,
  });

  final DocumentItem document;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  /// The document could not be found the last time it was checked.
  final bool unavailable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = documentSubtitle(context, document);
    return Semantics(
      button: true,
      child: AppCard(
        onTap: onTap,
        padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
        child: Row(
          children: [
            Semantics(
              label: '${document.type.label} document',
              child: Opacity(opacity: unavailable ? 0.45 : 1, child: DocumentTypeBadge(type: document.type)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    document.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, style: theme.textTheme.bodySmall),
                  if (unavailable) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.link_off_rounded, size: 16, color: AppColors.danger),
                        const SizedBox(width: 4),
                        Text(
                          'No longer available',
                          style: theme.textTheme.labelMedium?.copyWith(color: AppColors.danger),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            // onSelected runs after the menu has closed, so it can safely show a dialog.
            PopupMenuButton<String>(
              tooltip: 'More options for ${document.name}',
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (_) => onRemove(),
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'remove',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.remove_circle_outline_rounded),
                    title: Text('Remove from Child Assist'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
