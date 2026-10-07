import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';
import '../../photos/screens/photo_viewer_screen.dart' show fileSizeLabel;
import '../services/document_service.dart';
import '../widgets/document_card.dart';

enum _Phase { checking, ready, unavailable, failed }

/// One document: its details, plus a way to read it. TXT is shown inside the app; PDF, DOC and
/// DOCX are opened in the device's own viewer app. Read-only: the file is never changed.
///
/// Pops with `true` if the user removed the document.
class DocumentViewerScreen extends StatefulWidget {
  const DocumentViewerScreen({super.key, required this.document, required this.documentService});

  final DocumentItem document;
  final DocumentService documentService;

  @override
  State<DocumentViewerScreen> createState() => _DocumentViewerScreenState();
}

class _DocumentViewerScreenState extends State<DocumentViewerScreen> {
  late final AppLifecycleListener _lifecycle;
  late DocumentItem _document = widget.document;
  _Phase _phase = _Phase.checking;

  /// What "Retry" does after a failure.
  Future<void> Function()? _retry;

  // TXT preview.
  DocumentText? _text;
  bool _textFailed = false;

  bool _opening = false;

  /// Set when no app could show the document; [_noAppAtAll] when even "any app" found none.
  bool _noViewer = false;
  bool _noAppAtAll = false;

  bool _removing = false;

  DocumentService get _service => widget.documentService;
  bool get _isText => _document.type == DocumentType.txt;

  @override
  void initState() {
    super.initState();
    // Coming back from the viewer app or elsewhere: the file may have gone meanwhile.
    _lifecycle = AppLifecycleListener(onResume: () {
      if (_phase == _Phase.ready && !_opening) unawaited(_check(quiet: true));
    });
    _check();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// Makes sure the document is still there and refreshes its details. With [quiet], keeps
  /// the current view unless the document has gone.
  Future<void> _check({bool quiet = false}) async {
    if (!quiet) setState(() => _phase = _Phase.checking);
    try {
      final document = await _service.refresh(_document);
      if (!mounted) return;
      setState(() {
        _document = document;
        _phase = _Phase.ready;
      });
      if (_isText && (_text == null || !quiet)) await _loadText();
    } on DocumentUnavailableException {
      if (mounted) setState(() => _phase = _Phase.unavailable);
    } on DocumentException {
      if (mounted && !quiet) _fail(_check);
    }
  }

  Future<void> _loadText() async {
    setState(() => _textFailed = false);
    try {
      final text = await _service.readText(_document);
      if (mounted) setState(() => _text = text);
    } on DocumentUnavailableException {
      if (mounted) setState(() => _phase = _Phase.unavailable);
    } on DocumentException {
      if (mounted) setState(() => _textFailed = true);
    }
  }

  Future<void> _open({bool anyApp = false}) async {
    setState(() => _opening = true);
    try {
      final result = await _service.open(_document, anyApp: anyApp);
      if (!mounted) return;
      setState(() {
        switch (result) {
          case DocumentOpenResult.opened:
            _noViewer = false;
          case DocumentOpenResult.noViewer:
            _noViewer = true;
            _noAppAtAll = anyApp;
          case DocumentOpenResult.unavailable:
            _phase = _Phase.unavailable;
        }
      });
    } on DocumentException {
      if (mounted) _fail(() => _open(anyApp: anyApp));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _fail(Future<void> Function() retry) => setState(() {
        _phase = _Phase.failed;
        _retry = retry;
      });

  Future<void> _runRetry() async {
    final retry = _retry ?? _check;
    // A failed open happened on the details view; go back to it before trying again.
    if (retry != _check) setState(() => _phase = _Phase.ready);
    await retry();
  }

  Future<void> _remove() async {
    setState(() => _removing = true);
    try {
      await _service.remove(_document);
      if (mounted) Navigator.of(context).pop(true);
    } on DocumentException catch (e) {
      if (!mounted) return;
      setState(() => _removing = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  void _close() => Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(flexibleSpace: const AppBarGradient(), title: Text(_document.name, overflow: TextOverflow.ellipsis)),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: switch (_phase) {
            _Phase.checking => Center(
                key: const ValueKey('checking'),
                child: Semantics(label: 'Opening document', child: const CircularProgressIndicator()),
              ),
            _Phase.unavailable => StateMessage(
                key: const ValueKey('unavailable'),
                icon: Icons.link_off_rounded,
                gradient: AppGradients.danger,
                title: 'This document is no longer available.',
                body: 'It may have been moved, renamed or deleted on your device. '
                    'You can remove it from Child Assist.',
                action: GradientButton(
                  gradient: AppGradients.danger,
                  onPressed: _removing ? null : _remove,
                  icon: _removing ? const ButtonSpinner(size: 18) : const Icon(Icons.delete_outline_rounded),
                  label: const Text('Remove'),
                ),
                secondaryAction: TextButton(onPressed: _close, child: const Text('Close')),
              ),
            _Phase.failed => StateMessage(
                key: const ValueKey('failed'),
                icon: Icons.error_outline_rounded,
                gradient: AppGradients.danger,
                title: 'Unable to open this document.',
                body: 'Please try again.',
                action: GradientButton(
                  gradient: AppGradients.documents,
                  onPressed: _runRetry,
                  label: const Text('Retry'),
                ),
                secondaryAction: TextButton(onPressed: _close, child: const Text('Close')),
              ),
            _Phase.ready => _isText ? _buildTextView(context) : _buildDetailsView(context),
          },
        ),
      ),
    );
  }

  /// PDF, DOC, DOCX: details and a button that hands the document to the device's viewer.
  Widget _buildDetailsView(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      key: const ValueKey('details'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        FadeSlideIn(child: _Header(document: _document)),
        const SizedBox(height: 16),
        FadeSlideIn(index: 1, child: _Details(document: _document)),
        const SizedBox(height: 20),
        FadeSlideIn(
          index: 2,
          child: AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Open in a viewer app', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  '${_document.type.label} files open in a viewer app on your device. '
                  'The file is not uploaded.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 14),
                GradientButton(
                  gradient: AppGradients.documents,
                  onPressed: _opening ? null : _open,
                  icon: _opening ? const ButtonSpinner(size: 18) : const Icon(Icons.open_in_new_rounded),
                  label: Text(_opening ? 'Opening...' : 'Open document'),
                ),
              ],
            ),
          ),
        ),
        if (_noViewer) ...[const SizedBox(height: 14), _noViewerBanner()],
      ],
    );
  }

  Widget _noViewerBanner() {
    return InfoBanner(
      tone: BannerTone.warning,
      icon: Icons.visibility_off_outlined,
      title: 'This document cannot be previewed on this device.',
      message: Text(_noAppAtAll
          ? 'No app on this device can open it.'
          : 'No app that opens ${_document.type.label} files was found.'),
      actions: [
        if (!_noAppAtAll)
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: _opening ? null : () => _open(anyApp: true),
            child: const Text('Open with another app'),
          ),
        TextButton(onPressed: _close, child: const Text('Close')),
      ],
    );
  }

  /// TXT: details, then the text itself (the first part, for very long files).
  Widget _buildTextView(BuildContext context) {
    final theme = Theme.of(context);
    final text = _text;
    // Laid out in chunks so a long file is built lazily as it scrolls.
    final chunks = text == null ? const <String>[] : _chunks(text.text);
    return SelectionArea(
      key: const ValueKey('text'),
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            sliver: SliverList.list(children: [
              FadeSlideIn(child: _Header(document: _document)),
              const SizedBox(height: 16),
              FadeSlideIn(index: 1, child: _Details(document: _document)),
              const SizedBox(height: 20),
              SectionTitle(
                'Preview',
                trailing: TextButton.icon(
                  onPressed: _opening ? null : () => _open(anyApp: true),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('Open with another app'),
                ),
              ),
              const SizedBox(height: 8),
              if (_noViewer) ...[_noViewerBanner(), const SizedBox(height: 12)],
              if (_textFailed)
                InfoBanner(
                  tone: BannerTone.danger,
                  title: 'Unable to open this document.',
                  message: const Text('Please try again.'),
                  actions: [
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                      onPressed: _loadText,
                      child: const Text('Retry'),
                    ),
                  ],
                )
              else if (text == null)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (text.text.trim().isEmpty)
                Text('This document is empty.', style: theme.textTheme.bodyMedium)
              else if (text.truncated)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: InfoBanner(
                    message: Text(
                      'Showing the first ${fileSizeLabel(DocumentService.maxTextPreviewBytes)} of this document.',
                    ),
                  ),
                ),
            ]),
          ),
          if (chunks.isNotEmpty && text!.text.trim().isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              sliver: DecoratedSliver(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(AppSpacing.radius),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                sliver: SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SliverList.builder(
                    itemCount: chunks.length,
                    itemBuilder: (context, i) => Text(
                      chunks[i],
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Splits [text] into groups of lines.
  static List<String> _chunks(String text, {int lines = 40}) {
    final all = text.split('\n');
    return [
      for (var i = 0; i < all.length; i += lines) all.sublist(i, (i + lines).clamp(0, all.length)).join('\n'),
    ];
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.document});

  final DocumentItem document;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      child: Row(
        children: [
          Semantics(
            label: '${document.type.label} document',
            child: DocumentTypeBadge(type: document.type, size: 56),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(document.name, style: theme.textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(documentSubtitle(context, document), style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The metadata the device reported; anything it did not report is left out.
class _Details extends StatelessWidget {
  const _Details({required this.document});

  final DocumentItem document;

  @override
  Widget build(BuildContext context) {
    final details = <(IconData, String, String)>[
      (Icons.description_outlined, 'Type', '${document.type.label} document'),
      if (document.size != null) (Icons.sd_storage_outlined, 'Size', fileSizeLabel(document.size!)),
      if (document.modifiedAt != null)
        (Icons.edit_calendar_outlined, 'Modified', documentDateLabel(context, document.modifiedAt!)),
      (Icons.add_circle_outline_rounded, 'Added', documentDateLabel(context, document.addedAt)),
    ];
    return LayoutBuilder(builder: (context, constraints) {
      final columns = constraints.maxWidth >= 520 ? 4 : 2;
      final width = (constraints.maxWidth - 10 * (columns - 1)) / columns;
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final (icon, label, value) in details)
            SizedBox(width: width, child: _DetailTile(icon: icon, label: label, value: value)),
        ],
      );
    });
  }
}

class _DetailTile extends StatelessWidget {
  const _DetailTile({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.sky),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
