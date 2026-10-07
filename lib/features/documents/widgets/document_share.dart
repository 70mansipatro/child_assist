import 'package:flutter/material.dart';

import '../../contacts/services/message_handoff.dart';
import '../services/document_service.dart';

/// Opens WhatsApp (or the share sheet) with one document attached. The user picks the chat and
/// taps Send in that app: Child Assist never sends anything itself.
typedef ShareDocument = Future<HandoffResult> Function(DocumentItem document, {required bool toWhatsApp});

/// [ShareDocument] through the phone's WhatsApp and share sheet.
ShareDocument shareDocumentWith(MessageHandoff handoff) => (document, {required toWhatsApp}) => handoff.shareDocument(
      reference: document.reference,
      mimeType: document.mimeType ?? document.type.mimeType,
      toWhatsApp: toWhatsApp,
    );

/// The outcome of [confirmAndShareDocument], to show to the user.
class DocumentShareOutcome {
  const DocumentShareOutcome(this.message, {this.unavailable = false, this.document});

  final String message;

  /// The document turned out to be gone; nothing was shared.
  final bool unavailable;

  /// The document with refreshed details, when it was checked.
  final DocumentItem? document;
}

/// Asks the user to confirm sharing [document] (on WhatsApp, or with any app), checks it is still
/// on the phone, then opens WhatsApp or the share sheet. Nothing happens without the user's
/// Confirm, and the result never claims the document was sent: the user sends it in that app.
Future<DocumentShareOutcome> confirmAndShareDocument(
  BuildContext context, {
  required DocumentItem document,
  required DocumentService documentService,
  required ShareDocument share,
  required bool toWhatsApp,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(toWhatsApp ? 'Send on WhatsApp?' : 'Share this document?'),
      content: Text(
        'Document: ${document.name}\n\n${toWhatsApp ? 'WhatsApp will open with this document attached. Choose the chat, then tap Send in WhatsApp. Nothing is sent until you do.' : 'Your share options will open. Nothing is sent until you send it from the app you choose.'}',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confirm')),
      ],
    ),
  );
  if (confirmed != true) return const DocumentShareOutcome("Okay, I didn't share the document.");

  final DocumentItem current;
  try {
    // It may have been deleted or moved since it was listed: never share a missing file.
    current = await documentService.refresh(document);
  } on DocumentUnavailableException {
    return const DocumentShareOutcome('This document is no longer available.', unavailable: true);
  } on DocumentException {
    return const DocumentShareOutcome("I couldn't check the document. Nothing was shared.");
  }
  final result = await share(current, toWhatsApp: toWhatsApp);
  final message = switch ((result, toWhatsApp)) {
    (HandoffResult.opened, true) => 'WhatsApp opened. Choose the chat, then tap Send to send the document.',
    (HandoffResult.opened, false) =>
      'Share options opened. Nothing is sent until you send the document from the app you choose.',
    (_, true) => "WhatsApp isn't available on this device. Nothing was shared.",
    (_, false) => "Sharing isn't available on this device. Nothing was shared.",
  };
  return DocumentShareOutcome(message, document: current);
}
