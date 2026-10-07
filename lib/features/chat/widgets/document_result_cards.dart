import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';
import '../../documents/services/document_service.dart';
import '../../documents/widgets/document_card.dart' show DocumentTypeBadge, documentSubtitle;
import '../../documents/widgets/document_share.dart';
import '../models/chat_message.dart';
import '../services/chat_session.dart';
import 'tool_result_cards.dart' show ChatResultContext;

// Documents in chat. Every search runs on the phone over the signed-in user's own documents (each
// one granted by the OS file picker); names and contents never go to the server or the assistant.
// Nothing is shared without the user confirming it, and Child Assist only ever *opens* WhatsApp or
// the share sheet: the user sends the document there.

const documentUnavailableText = 'This document is no longer available.';

/// The document type for a label such as "PDF", or null.
DocumentType? documentTypeFromLabel(String? label) => DocumentType.fromLabel(label);

/// The answer to "send me / find / show the Python document": the one document found, with its
/// details and actions; several to choose from; or a clear "not found". Never invented.
class DocumentResultsCard extends StatefulWidget {
  const DocumentResultsCard({super.key, required this.query, required this.results});

  final ChatLookupQuery query;
  final ChatResultContext results;

  @override
  State<DocumentResultsCard> createState() => _DocumentResultsCardState();
}

class _DocumentResultsCardState extends State<DocumentResultsCard> {
  late final Future<DocumentSearchResult> _search = widget.results.documentService.search(
    widget.query.text,
    type: documentTypeFromLabel(widget.query.type),
    limit: widget.query.limit ?? 10,
  );

  /// The document the user picked from several.
  DocumentMatch? _chosen;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSearchResult>(
      future: _search,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator());
        }
        final result = snapshot.data;
        if (snapshot.hasError || result == null || result.outcome == DocumentSearchOutcome.none) {
          return InfoBanner(
            icon: Icons.search_off_rounded,
            title: result == null ? "I couldn't search your documents." : result.notFoundMessage,
            message: const Text('Child Assist can only see the folders and files you allowed in Documents.'),
            actions: [OutlinedButton(onPressed: widget.results.onOpenDocuments, child: const Text('Open Documents'))],
          );
        }
        final chosen = _chosen ?? result.single;
        if (chosen != null) {
          return DocumentDetailsCard(
            key: ValueKey('document-${chosen.document.id}'),
            match: chosen,
            results: widget.results,
            onChooseAnother: result.matches.length > 1 ? () => setState(() => _chosen = null) : null,
          );
        }
        return AppCard(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: DocumentChoiceList(
            prompt: result.choosePrompt,
            matches: result.matches,
            onSelected: (m) => setState(() => _chosen = m),
          ),
        );
      },
    );
  }
}

/// Documents to choose from, each with its type, size and date. Ones that are no longer on the
/// phone are shown but cannot be chosen.
class DocumentChoiceList extends StatelessWidget {
  const DocumentChoiceList({
    super.key,
    required this.prompt,
    required this.matches,
    required this.onSelected,
    this.enabled = true,
  });

  final String prompt;
  final List<DocumentMatch> matches;
  final ValueChanged<DocumentMatch> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(prompt, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        for (final match in matches)
          ListTile(
            key: ValueKey('choose-document-${match.document.id}'),
            contentPadding: EdgeInsets.zero,
            enabled: enabled && match.available,
            leading: Opacity(
              opacity: match.available ? 1 : 0.45,
              child: DocumentTypeBadge(type: match.document.type, size: 40),
            ),
            title: Text(match.document.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              match.available ? documentSubtitle(context, match.document) : documentUnavailableText,
              style: match.available ? null : TextStyle(color: AppColors.danger),
            ),
            onTap: () => onSelected(match),
          ),
      ],
    );
  }
}

/// One document: name, type, size, modified date and whether it is still on the phone, with the
/// actions the platform supports for it. Share and WhatsApp ask first, and only open the other
/// app: the user sends the document there. Summarize asks the assistant about this document, which
/// reads it on the phone.
class DocumentDetailsCard extends StatefulWidget {
  const DocumentDetailsCard({super.key, required this.match, required this.results, this.onChooseAnother});

  final DocumentMatch match;
  final ChatResultContext results;
  final VoidCallback? onChooseAnother;

  @override
  State<DocumentDetailsCard> createState() => _DocumentDetailsCardState();
}

class _DocumentDetailsCardState extends State<DocumentDetailsCard> {
  late DocumentItem _document = widget.match.document;
  late bool _available = widget.match.available;
  String? _status;

  @override
  void initState() {
    super.initState();
    // "Summarize it" next refers to this document.
    if (_available) widget.results.session.rememberDocument(_document);
  }

  Future<void> _share({required bool toWhatsApp}) async {
    final outcome = await confirmAndShareDocument(
      context,
      document: _document,
      documentService: widget.results.documentService,
      share: widget.results.onShareDocument,
      toWhatsApp: toWhatsApp,
    );
    if (!mounted) return;
    setState(() {
      _status = outcome.message;
      if (outcome.unavailable) _available = false;
      if (outcome.document != null) _document = outcome.document!;
    });
  }

  void _summarize() {
    widget.results.session.rememberDocument(_document);
    // The file name is not sent: the assistant asks the phone to read "this document".
    widget.results.session.send('Summarize this document');
  }

  @override
  Widget build(BuildContext context) {
    return DocumentSummaryTile(
      document: _document,
      available: _available,
      footer: [
        if (_status != null) Text(_status!, style: Theme.of(context).textTheme.bodyMedium),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (_available) ...[
              OutlinedButton.icon(
                onPressed: () => widget.results.onOpenDocument(_document),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('Open'),
              ),
              OutlinedButton.icon(
                onPressed: () => _share(toWhatsApp: false),
                icon: const Icon(Icons.share_rounded, size: 18),
                label: const Text('Share'),
              ),
              FilledButton.icon(
                onPressed: () => _share(toWhatsApp: true),
                icon: const Icon(Icons.chat_rounded, size: 18),
                label: const Text('Send on WhatsApp'),
              ),
              if (_document.type != DocumentType.doc)
                TextButton.icon(
                  onPressed: widget.results.session.isSending ? null : _summarize,
                  icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                  label: const Text('Summarize'),
                ),
            ] else
              OutlinedButton(onPressed: widget.results.onOpenDocuments, child: const Text('Open Documents')),
            if (widget.onChooseAnother != null)
              TextButton(onPressed: widget.onChooseAnother, child: const Text('Choose another document')),
          ],
        ),
      ],
    );
  }
}

/// A document's badge, name, type, size, date and availability, with [footer] below.
class DocumentSummaryTile extends StatelessWidget {
  const DocumentSummaryTile({super.key, required this.document, required this.available, this.footer = const []});

  final DocumentItem document;
  final bool available;
  final List<Widget> footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Opacity(
                opacity: available ? 1 : 0.45,
                child: DocumentTypeBadge(type: document.type, size: 44),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      document.name,
                      style: theme.textTheme.titleSmall,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(document.type.label, style: theme.textTheme.labelSmall),
                    Text(documentSubtitle(context, document), style: theme.textTheme.bodySmall),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(
                          available ? Icons.check_circle_outline_rounded : Icons.link_off_rounded,
                          size: 16,
                          color: available ? AppColors.success : AppColors.danger,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            available ? 'Available on this phone' : documentUnavailableText,
                            style: theme.textTheme.labelMedium?.copyWith(color: available ? null : AppColors.danger),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          for (final widget in footer) ...[const SizedBox(height: 8), widget],
        ],
      ),
    );
  }
}

/// A question about what is inside a document ("Python notes me kya hai?"). The document is
/// found among the user's own documents on this phone (several are offered to choose from),
/// checked to still be there, and its text extracted here; only that one document's text goes to
/// the server, and the answer from it appears as the next chat message. Every failure is said
/// plainly: nothing about the document is ever guessed.
class DocumentReadCard extends StatefulWidget {
  const DocumentReadCard({super.key, required this.requestId, required this.query, required this.results});

  final String requestId;
  final ChatLookupQuery query;
  final ChatResultContext results;

  @override
  State<DocumentReadCard> createState() => _DocumentReadCardState();
}

class _DocumentReadCardState extends State<DocumentReadCard> {
  @override
  void initState() {
    super.initState();
    // Idempotent: a rebuilt card never reads or sends twice.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.results.session.startDocumentRead(widget.requestId, widget.query);
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.results.session;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final state = session.documentRead(widget.requestId);
        final theme = Theme.of(context);
        final document = state?.document;
        switch (state?.phase) {
          case null || DocumentReadPhase.searching:
            return const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator());
          case DocumentReadPhase.choosing:
            return AppCard(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DocumentChoiceList(
                    prompt: state!.result!.choosePrompt,
                    matches: state.result!.matches,
                    onSelected: (m) => session.chooseDocumentToRead(widget.requestId, m.document),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton(
                      onPressed: () => session.cancelDocumentRead(widget.requestId),
                      child: const Text('Cancel'),
                    ),
                  ),
                ],
              ),
            );
          case DocumentReadPhase.reading:
            return DocumentSummaryTile(
              document: document!,
              available: true,
              footer: [
                Text('Reading this document on your phone...', style: theme.textTheme.bodySmall),
                const LinearProgressIndicator(),
              ],
            );
          case DocumentReadPhase.answered:
            return DocumentSummaryTile(
              document: document!,
              available: true,
              footer: [
                Text('Answered from this document.', style: theme.textTheme.bodySmall),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => widget.results.onOpenDocument(document),
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      label: const Text('Open'),
                    ),
                  ],
                ),
              ],
            );
          case DocumentReadPhase.failed:
            if (document != null) {
              final gone = state!.message == ChatSession.documentGoneMessage;
              return DocumentSummaryTile(
                document: document,
                available: !gone,
                footer: [
                  if (!gone) Text(state.message ?? '', style: theme.textTheme.bodyMedium),
                  if (!gone)
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => widget.results.onOpenDocument(document),
                          icon: const Icon(Icons.open_in_new_rounded, size: 18),
                          label: const Text('Open'),
                        ),
                      ],
                    ),
                ],
              );
            }
            return InfoBanner(
              icon: Icons.search_off_rounded,
              title: state!.message ?? "I couldn't read that document.",
              message: const Text('Child Assist can only read the folders and files you allowed in Documents.'),
              actions: [OutlinedButton(onPressed: widget.results.onOpenDocuments, child: const Text('Open Documents'))],
            );
        }
      },
    );
  }
}

/// For a document share: finds the document the user asked for among their own documents on
/// this phone. One strong match that is still there is taken without asking (the user still
/// confirms it next); several must be chosen from; none, or a missing file, is said plainly and
/// never shared. [onPick] returns an error to show, or null on success.
class ActionDocumentPicker extends StatefulWidget {
  const ActionDocumentPicker({
    super.key,
    required this.query,
    required this.results,
    required this.onPick,
    required this.onCancel,
  });

  /// The words the user used for the document; null when they did not name one.
  final String? query;
  final ChatResultContext results;
  final Future<String?> Function(DocumentItem document) onPick;
  final VoidCallback onCancel;

  @override
  State<ActionDocumentPicker> createState() => _ActionDocumentPickerState();
}

class _ActionDocumentPickerState extends State<ActionDocumentPicker> {
  late final Future<DocumentSearchResult> _search = widget.results.documentService.search(widget.query);
  bool _autoPicked = false;
  bool _submitting = false;
  String? _error;

  Future<void> _pick(DocumentItem document) async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final error = await widget.onPick(document);
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<DocumentSearchResult>(
      future: _search,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: LinearProgressIndicator());
        }
        final result = snapshot.data;
        if (snapshot.hasError || result == null) return _messageAndCancel(context, "I couldn't search your documents.");
        if (result.outcome == DocumentSearchOutcome.none) {
          return _messageAndCancel(context, result.notFoundMessage, openDocuments: true);
        }

        final single = result.single;
        if (single != null) {
          if (!single.available) return _messageAndCancel(context, documentUnavailableText, openDocuments: true);
          if (!_autoPicked) {
            _autoPicked = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _pick(single.document);
            });
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error == null)
                const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: LinearProgressIndicator()),
              ..._errorAndCancel(theme),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DocumentChoiceList(
              prompt: result.choosePrompt,
              matches: result.matches,
              enabled: !_submitting,
              onSelected: (m) => _pick(m.document),
            ),
            ..._errorAndCancel(theme),
          ],
        );
      },
    );
  }

  Widget _messageAndCancel(BuildContext context, String message, {bool openDocuments = false}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(message, style: Theme.of(context).textTheme.bodyMedium),
      if (openDocuments)
        Text(
          'Child Assist can only see the folders and files you allowed in Documents.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      const SizedBox(height: 8),
      Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        children: [
          if (openDocuments) TextButton(onPressed: widget.results.onOpenDocuments, child: const Text('Open Documents')),
          OutlinedButton(onPressed: widget.onCancel, child: const Text('Cancel')),
        ],
      ),
    ],
  );

  List<Widget> _errorAndCancel(ThemeData theme) => [
    if (_error != null) ...[Text(_error!, style: TextStyle(color: AppColors.danger)), const SizedBox(height: 6)],
    Align(
      alignment: Alignment.centerRight,
      child: OutlinedButton(onPressed: _submitting ? null : widget.onCancel, child: const Text('Cancel')),
    ),
  ];
}
