import 'package:flutter/material.dart';

import '../../contacts/services/message_handoff.dart';
import '../services/document_service.dart';
import 'document_viewer_screen.dart';
import 'documents_screen.dart';

bool _picking = false;

/// What Documents does: Android's own document picker (the Storage Access Framework) opens
/// straight away, as the document browser. It shows whatever the phone offers, such as Recent,
/// Downloads, internal storage and Google Drive or other installed providers. Child Assist
/// itself sees only the one document the user picks, which is then kept for the signed-in user
/// (so the assistant can find it later) and opened in [DocumentViewerScreen].
///
/// Cancelling the picker just returns to where the user was, with no message. [push] shows the
/// viewer (by default a plain [Navigator] push).
Future<void> pickAndOpenDocument(
  BuildContext context, {
  required DocumentService documentService,
  MessageHandoff? messageHandoff,
  Future<void> Function(Widget screen)? push,
}) async {
  // A second tap while the picker is opening must not open another one.
  if (_picking) return;
  _picking = true;
  final AddDocumentsResult result;
  try {
    result = await documentService.addDocuments(multiple: false);
  } on DocumentException catch (e) {
    if (context.mounted) _showSnack(context, e.message);
    return;
  } finally {
    _picking = false;
  }
  if (!context.mounted || result.cancelled) return;

  final document = result.documents.firstOrNull;
  if (document == null) {
    _showSnack(context, 'Only PDF, DOC, DOCX and TXT documents are supported.');
    return;
  }
  final viewer = Builder(
    builder: (viewerContext) => DocumentViewerScreen(
      document: document,
      documentService: documentService,
      messageHandoff: messageHandoff,
      onShowAll: () => Navigator.of(viewerContext).push(MaterialPageRoute<void>(
        builder: (_) => DocumentsScreen(documentService: documentService, messageHandoff: messageHandoff),
      )),
    ),
  );
  if (push != null) return push(viewer);
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => viewer));
}

void _showSnack(BuildContext context, String message) => ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(message)));
