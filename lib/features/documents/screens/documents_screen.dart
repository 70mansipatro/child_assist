import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/navigation/app_menu.dart';
import '../../../core/widgets/widgets.dart';
import '../../contacts/services/message_handoff.dart';
import '../services/document_service.dart';
import '../widgets/document_card.dart';
import '../widgets/document_share.dart';
import 'document_viewer_screen.dart';

/// The documents Child Assist can access on this phone, with search and type/date filters.
///
/// Opening the screen lists them straight away; it never opens a picker by itself. Android only
/// lets an app see documents the user allowed, without "all files access" (which Child Assist does
/// not use): folders the user connected once in the system folder picker (every PDF, Word and
/// text file in them, listed live each time), and files picked one by one. A first-time user who
/// has allowed nothing yet is told exactly that, with a button to choose a folder.
class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key, required this.documentService, this.messageHandoff});

  final DocumentService documentService;

  /// WhatsApp and the share sheet, for Share and WhatsApp on each document. Hidden without it.
  final MessageHandoff? messageHandoff;

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  late final AppLifecycleListener _lifecycle;
  final _search = TextEditingController();

  /// Null while loading.
  DocumentLibrary? _library;
  bool _loadFailed = false;

  /// IDs of documents that could not be found the last time they were checked.
  Set<String> _unavailable = {};

  /// True while a picker is open or what was picked is being saved.
  bool _adding = false;

  String _query = '';
  DocumentType? _type;
  DocumentDateFilter _dateFilter = DocumentDateFilter.all;

  DocumentService get _service => widget.documentService;

  @override
  void initState() {
    super.initState();
    // Files can be added, deleted or moved while the app is in the background.
    _lifecycle = AppLifecycleListener(onResume: () {
      if (!_adding) unawaited(_load());
    });
    _load();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _search.dispose();
    super.dispose();
  }

  /// Lists the documents afresh: connected folders are read again, so new files show up.
  Future<void> _load() async {
    if (_loadFailed) setState(() => _loadFailed = false);
    try {
      final library = await _service.library(refresh: true);
      if (!mounted) return;
      setState(() => _library = library);
      unawaited(_checkAvailability());
    } on DocumentException {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  /// Files picked one by one can vanish; files in a folder are listed live, so they just go.
  Future<void> _checkAvailability() async {
    final picked = _library?.documents.where((d) => !d.inFolder).toList() ?? const [];
    if (picked.isEmpty) {
      if (_unavailable.isNotEmpty && mounted) setState(() => _unavailable = {});
      return;
    }
    final unavailable = await _service.findUnavailable(picked);
    if (mounted) setState(() => _unavailable = unavailable);
  }

  Future<void> _connectFolder() async {
    setState(() => _adding = true);
    try {
      final folder = await _service.connectFolder();
      if (!mounted || folder == null) return;
      await _load();
      _showSnack('Showing documents from ${folder.name}');
    } on DocumentException catch (e) {
      _showSnack('${e.message} Please try again.', retry: _connectFolder);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _pickFiles() async {
    setState(() => _adding = true);
    try {
      final result = await _service.addDocuments();
      if (!mounted || result.cancelled) return;
      await _load();
      _showSnack(_addedMessage(result));
    } on DocumentException catch (e) {
      _showSnack('${e.message} Please try again.', retry: _pickFiles);
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

  /// Share or WhatsApp: asks first, checks the file is still there, then opens the other app.
  Future<void> _share(DocumentItem document, {required bool toWhatsApp}) async {
    final handoff = widget.messageHandoff;
    if (handoff == null) return;
    final outcome = await confirmAndShareDocument(
      context,
      document: document,
      documentService: _service,
      share: shareDocumentWith(handoff),
      toWhatsApp: toWhatsApp,
    );
    if (!mounted) return;
    if (outcome.unavailable) setState(() => _unavailable = {..._unavailable, document.id});
    _showSnack(outcome.message);
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

  Future<void> _confirmDisconnect(DocumentFolder folder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop showing this folder?'),
        content: Text(
          'Documents in "${folder.name}" will no longer be shown in Child Assist. The files stay on your device.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Remove folder'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _service.disconnectFolder(folder);
      if (!mounted) return;
      await _load();
      _showSnack('${folder.name} removed from Child Assist');
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

  /// Documents matching the filters and the search text (name words, partial words, or a type
  /// such as "pdf"), best match first while searching.
  List<DocumentItem> _visible(List<DocumentItem> documents) {
    final now = DateTime.now();
    final filtered = documents
        .where((d) => (_type == null || d.type == _type) && _dateFilter.matches(d.date, now))
        .toList();
    if (_query.trim().isEmpty) return filtered;
    return DocumentSearch.search(filtered, _query, conversational: false).documents;
  }

  @override
  Widget build(BuildContext context) {
    final library = _library;
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: const AppBarGradient(),
        title: const Text('Documents'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _adding || library == null ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
          PopupMenuButton<String>(
            tooltip: 'Add documents',
            enabled: !_adding,
            icon: _adding ? const ButtonSpinner(size: 20) : const Icon(Icons.add_rounded),
            onSelected: (choice) => choice == 'folder' ? _connectFolder() : _pickFiles(),
            itemBuilder: (_) => [
              if (_service.supportsFolders)
                const PopupMenuItem(
                  value: 'folder',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.folder_open_rounded),
                    title: Text('Choose a folder'),
                  ),
                ),
              const PopupMenuItem(
                value: 'files',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.note_add_rounded),
                  title: Text('Pick files'),
                ),
              ),
            ],
          ),
          const AppMenuButton(current: AppDestination.documents),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: switch (library) {
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
            null => const Center(
                key: ValueKey('loading'),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Loading documents...')],
                ),
              ),
            DocumentLibrary(documents: [], folders: []) => _AccessIntro(
                key: const ValueKey('intro'),
                busy: _adding,
                foldersSupported: _service.supportsFolders,
                onChooseFolder: _connectFolder,
                onPickFiles: _pickFiles,
              ),
            final library => _buildList(context, library),
          },
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context, DocumentLibrary library) {
    final documents = library.documents;
    final visible = _visible(documents);
    final theme = Theme.of(context);
    return CustomScrollView(
      key: const ValueKey('list'),
      slivers: [
        SliverToBoxAdapter(child: _buildControls(context)),
        if (library.folders.isNotEmpty) SliverToBoxAdapter(child: _buildFolders(context, library.folders)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
            child: SectionTitle(
              'Your Documents',
              subtitle: _filtering
                  ? '${visible.length} of ${documents.length} match'
                  : documents.length == 1
                      ? '1 document'
                      : '${documents.length} documents',
            ),
          ),
        ),
        if (documents.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: AppCard(
                child: Text(
                  'No PDF, Word or text files in your folders yet. Files you save there will show up here.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ),
          )
        else if (visible.isEmpty)
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
                          Text('No matching documents', style: theme.textTheme.titleSmall),
                          Text('Try a different search or filter.', style: theme.textTheme.bodySmall),
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
                    // A file in a connected folder is removed by removing the folder.
                    onRemove: document.inFolder ? null : () => _confirmRemove(document),
                    onShare: widget.messageHandoff == null ? null : () => _share(document, toWhatsApp: false),
                    onWhatsApp: widget.messageHandoff == null ? null : () => _share(document, toWhatsApp: true),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  /// Which folders the list comes from, and any whose access was lost.
  Widget _buildFolders(BuildContext context, List<FolderStatus> folders) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final status in folders.where((s) => !s.available))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InfoBanner(
                tone: BannerTone.warning,
                icon: Icons.folder_off_rounded,
                title: 'Child Assist can no longer see "${status.folder.name}".',
                message: const Text('The folder was moved or deleted, or its access was removed in Android settings.'),
                actions: [
                  TextButton(onPressed: () => _confirmDisconnect(status.folder), child: const Text('Remove folder')),
                  if (_service.supportsFolders)
                    FilledButton(onPressed: _connectFolder, child: const Text('Choose folder again')),
                ],
              ),
            ),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('From your folders:', style: theme.textTheme.labelMedium),
              for (final status in folders.where((s) => s.available))
                InputChip(
                  avatar: const Icon(Icons.folder_rounded, size: 18),
                  label: Text(status.truncated ? '${status.folder.name} (first ${status.count})' : status.folder.name),
                  tooltip: 'Remove ${status.folder.name}',
                  onDeleted: () => _confirmDisconnect(status.folder),
                  deleteButtonTooltipMessage: 'Remove ${status.folder.name}',
                ),
            ],
          ),
        ],
      ),
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

/// Shown only while the user has allowed Child Assist no documents at all. It says honestly what
/// Android allows, and opens a picker only when the user taps a button.
class _AccessIntro extends StatelessWidget {
  const _AccessIntro({
    super.key,
    required this.busy,
    required this.foldersSupported,
    required this.onChooseFolder,
    required this.onPickFiles,
  });

  final bool busy;
  final bool foldersSupported;
  final VoidCallback onChooseFolder;
  final VoidCallback onPickFiles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: IconBadge(icon: Icons.folder_open_rounded, gradient: AppGradients.documents, size: 72)),
          const SizedBox(height: 20),
          Text('Show your documents here', style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: 10),
          Text(
            foldersSupported
                ? 'Android only lets apps see the documents you allow. Choose a folder once, for example '
                    'Documents or a folder inside Download, and every PDF, Word and text file in it will '
                    'show here each time you open Documents, including new ones.'
                : 'Your phone only lets apps see the documents you choose. Pick the files to show here.',
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            'Child Assist only reads them on your phone. Nothing is uploaded.',
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          if (foldersSupported)
            GradientButton(
              gradient: AppGradients.documents,
              onPressed: busy ? null : onChooseFolder,
              icon: busy ? const ButtonSpinner(size: 18) : const Icon(Icons.folder_open_rounded),
              label: const Text('Choose folder'),
            ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: busy ? null : onPickFiles,
            icon: const Icon(Icons.note_add_rounded),
            label: const Text('Pick individual files'),
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
