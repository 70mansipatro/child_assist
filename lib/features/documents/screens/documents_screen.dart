import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/navigation/app_menu.dart';
import '../../../core/widgets/widgets.dart';
import '../services/document_service.dart';
import '../widgets/document_card.dart';
import 'document_viewer_screen.dart';

/// The documents the user added from their device, with search and type/date filters.
///
/// "Add Documents" opens the system file picker, which is also how access is granted: there is
/// no permission dialog of Child Assist's own. Documents stay on the device; only their details
/// are listed here.
class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key, required this.documentService});

  final DocumentService documentService;

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  late final AppLifecycleListener _lifecycle;
  final _search = TextEditingController();

  /// Null while loading.
  List<DocumentItem>? _documents;
  bool _loadFailed = false;

  /// IDs of documents that could not be found the last time they were checked.
  Set<String> _unavailable = {};

  /// True while the file picker is open or picked documents are being read.
  bool _adding = false;

  String _query = '';
  DocumentType? _type;
  DocumentDateFilter _dateFilter = DocumentDateFilter.all;

  DocumentService get _service => widget.documentService;

  @override
  void initState() {
    super.initState();
    // Files can be deleted or moved while the app is in the background.
    _lifecycle = AppLifecycleListener(onResume: () {
      if (!_adding) unawaited(_checkAvailability());
    });
    _load();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loadFailed) setState(() => _loadFailed = false);
    try {
      final documents = await _service.list();
      if (!mounted) return;
      setState(() => _documents = documents);
      unawaited(_checkAvailability());
    } on DocumentException {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  Future<void> _checkAvailability() async {
    final documents = _documents;
    if (documents == null || documents.isEmpty) return;
    final unavailable = await _service.findUnavailable(documents);
    if (mounted) setState(() => _unavailable = unavailable);
  }

  Future<void> _add() async {
    setState(() => _adding = true);
    try {
      final result = await _service.addDocuments();
      if (!mounted || result.cancelled) return;
      await _load();
      _showSnack(_addedMessage(result));
    } on DocumentException catch (e) {
      _showSnack('${e.message} Please try again.', retry: _add);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  static String _addedMessage(AddDocumentsResult result) {
    String count(int n, String one, String many) => n == 1 ? '1 $one' : '$n $many';
    return [
      if (result.added.isNotEmpty) 'Added ${count(result.added.length, 'document', 'documents')}',
      if (result.alreadyAdded > 0)
        '${count(result.alreadyAdded, 'document was', 'documents were')} already in your list',
      if (result.unsupported > 0)
        "${count(result.unsupported, 'file was', 'files were')} skipped: only PDF, DOC, DOCX and TXT are supported",
    ].join('. ');
  }

  Future<void> _open(DocumentItem document) async {
    // A message about the list (e.g. "Added 2 documents") does not belong on the viewer.
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DocumentViewerScreen(document: document, documentService: _service),
    ));
    // The viewer may have refreshed the details or removed the document.
    if (mounted) await _load();
  }

  Future<void> _confirmRemove(DocumentItem document) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove from Child Assist?'),
        content: Text('"${document.name}" will be removed from this list. The file stays on your device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _service.remove(document);
      if (!mounted) return;
      await _load();
      _showSnack('Removed from Child Assist');
    } on DocumentException catch (e) {
      _showSnack(e.message);
    }
  }

  void _showSnack(String message, {VoidCallback? retry}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        action: retry == null ? null : SnackBarAction(label: 'Retry', onPressed: retry),
      ));
  }

  bool get _filtering => _query.trim().isNotEmpty || _type != null || _dateFilter != DocumentDateFilter.all;

  void _clearFilters() => setState(() {
        _search.clear();
        _query = '';
        _type = null;
        _dateFilter = DocumentDateFilter.all;
      });

  /// Documents matching the search text (name or type) and the filters.
  List<DocumentItem> _visible(List<DocumentItem> documents) {
    final query = _query.trim().toLowerCase();
    final now = DateTime.now();
    return documents.where((d) {
      if (_type != null && d.type != _type) return false;
      if (!_dateFilter.matches(d.date, now)) return false;
      if (query.isEmpty) return true;
      return d.name.toLowerCase().contains(query) || d.type.extension == query.replaceFirst('.', '');
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final documents = _documents;
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: const AppBarGradient(),
        title: const Text('Documents'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _adding || documents == null ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const AppMenuButton(current: AppDestination.documents),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: switch (documents) {
            _ when _loadFailed => StateMessage(
                key: const ValueKey('error'),
                icon: Icons.error_outline_rounded,
                gradient: AppGradients.danger,
                title: 'Unable to load your documents.',
                body: 'Please try again.',
                action: GradientButton(
                  gradient: AppGradients.documents,
                  onPressed: _load,
                  label: const Text('Retry'),
                ),
              ),
            null => const Center(key: ValueKey('loading'), child: CircularProgressIndicator()),
            [] => StateMessage(
                key: const ValueKey('empty'),
                icon: Icons.description_rounded,
                gradient: AppGradients.documents,
                title: 'No documents yet',
                body: 'Add a document from your device to see it here.',
                action: _addButton(),
              ),
            final documents => _buildList(context, documents),
          },
        ),
      ),
    );
  }

  Widget _addButton() => GradientButton(
        gradient: AppGradients.documents,
        onPressed: _adding ? null : _add,
        icon: _adding ? const ButtonSpinner(size: 18) : const Icon(Icons.add_rounded),
        label: Text(_adding ? 'Adding documents...' : 'Add Documents'),
      );

  Widget _buildList(BuildContext context, List<DocumentItem> documents) {
    final visible = _visible(documents);
    return CustomScrollView(
      key: const ValueKey('list'),
      slivers: [
        SliverToBoxAdapter(child: _buildControls(context)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
            child: SectionTitle(
              'Recent Documents',
              subtitle: _filtering
                  ? '${visible.length} of ${documents.length} match'
                  : documents.length == 1
                      ? '1 document'
                      : '${documents.length} documents',
            ),
          ),
        ),
        if (visible.isEmpty)
          // Compact, so it stays in view above the keyboard while searching.
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: AppCard(
                child: Row(
                  children: [
                    const IconBadge(icon: Icons.search_off_rounded, gradient: AppGradients.documents, size: 40),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('No matching documents', style: Theme.of(context).textTheme.titleSmall),
                          Text('Try a different search or filter.', style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                    ),
                    TextButton(onPressed: _clearFilters, child: const Text('Clear filters')),
                  ],
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: SliverList.separated(
              itemCount: visible.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final document = visible[i];
                return FadeSlideIn(
                  key: ValueKey(document.id),
                  index: min(i, 8),
                  child: DocumentCard(
                    document: document,
                    unavailable: _unavailable.contains(document.id),
                    onTap: () => _open(document),
                    onRemove: () => _confirmRemove(document),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildControls(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppSpacing.radius),
              boxShadow: AppTheme.softShadow(context),
            ),
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                hintText: 'Search documents...',
                prefixIcon: const Icon(Icons.search_rounded),
                fillColor: theme.colorScheme.surface,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
              textInputAction: TextInputAction.search,
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          const SizedBox(height: 12),
          _addButton(),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _DateFilterChip(value: _dateFilter, onChanged: (f) => setState(() => _dateFilter = f)),
                const SizedBox(width: 8),
                for (final type in <DocumentType?>[null, ...DocumentType.values]) ...[
                  ChoiceChip(
                    label: Text(type?.label ?? 'All'),
                    selected: _type == type,
                    showCheckmark: false,
                    selectedColor: AppColors.sky.withValues(alpha: 0.18),
                    onSelected: (_) => setState(() => _type = type),
                  ),
                  const SizedBox(width: 6),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A chip showing the current date filter; tapping it offers the others.
class _DateFilterChip extends StatelessWidget {
  const _DateFilterChip({required this.value, required this.onChanged});

  final DocumentDateFilter value;
  final ValueChanged<DocumentDateFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final active = value != DocumentDateFilter.all;
    return PopupMenuButton<DocumentDateFilter>(
      tooltip: 'Filter by date',
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final filter in DocumentDateFilter.values) PopupMenuItem(value: filter, child: Text(filter.label)),
      ],
      child: Chip(
        avatar: const Icon(Icons.calendar_month_rounded, size: 18),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [Text(value.label), const Icon(Icons.arrow_drop_down_rounded, size: 20)],
        ),
        backgroundColor: active ? AppColors.sky.withValues(alpha: 0.18) : null,
        side: active ? BorderSide(color: AppColors.sky.withValues(alpha: 0.5)) : null,
      ),
    );
  }
}
