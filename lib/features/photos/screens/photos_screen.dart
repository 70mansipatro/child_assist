import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/permissions/permission_service.dart';
import '../../../core/widgets/widgets.dart';
import '../../permissions/services/permission_sync_service.dart';
import '../services/photo_gallery_service.dart';
import '../widgets/photo_grid.dart';
import 'photo_viewer_screen.dart';

/// The device gallery: a lazily loaded grid of photos, newest first, with a filename search
/// and a date filter.
///
/// Opening this screen only *checks* the Photos permission; the system dialog appears only
/// after the user taps "Allow Photos". Coming back to the app (e.g. from Settings) checks again.
class PhotosScreen extends StatefulWidget {
  const PhotosScreen({
    super.key,
    required this.galleryService,
    required this.permissionSyncService,
  });

  final PhotoGalleryService galleryService;
  final PermissionSyncService permissionSyncService;

  @override
  State<PhotosScreen> createState() => _PhotosScreenState();
}

class _PhotosScreenState extends State<PhotosScreen> {
  final _scroll = ScrollController();
  late final AppLifecycleListener _lifecycle;

  /// The OS Photos permission; null until first checked.
  PermissionState? _permission;

  /// True while a system dialog or picker is showing, so resuming from it does not re-check.
  bool _askingOs = false;

  final List<PhotoItem> _photos = [];
  int _nextPage = 0;
  bool _hasMore = true;
  bool _loadingFirst = false;
  bool _loadingMore = false;
  bool _firstPageFailed = false;
  bool _moreFailed = false;

  /// Bumped on every reload so results from an older load are dropped.
  int _generation = 0;

  String _query = '';
  DateTimeRange? _range;

  PhotoGalleryService get _gallery => widget.galleryService;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _lifecycle = AppLifecycleListener(onResume: () {
      if (!_askingOs) unawaited(_checkPermission(fromResume: true));
    });
    _checkPermission();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Reads the real OS state (never a cached one) and loads the gallery if it is usable.
  Future<void> _checkPermission({bool fromResume = false}) async {
    final previous = _permission;
    final state = await _gallery.permissionStatus();
    if (!mounted) return;
    setState(() => _permission = state);
    unawaited(_report(state, fromRequest: false));
    if (!state.isUsable) {
      setState(_clearPhotos);
    } else if (!fromResume || previous != state || state == PermissionState.limited) {
      // With limited access the selection may have changed in Settings even if the state did not.
      await _reload();
    }
  }

  Future<void> _allowPhotos() async {
    setState(() => _askingOs = true);
    try {
      final state = await _gallery.requestPermission();
      if (!mounted) return;
      setState(() => _permission = state);
      unawaited(_report(state, fromRequest: true));
      if (state.isUsable) await _reload();
    } finally {
      if (mounted) setState(() => _askingOs = false);
    }
  }

  Future<void> _changeSelection() async {
    setState(() => _askingOs = true);
    try {
      final state = await _gallery.changeLimitedSelection();
      if (!mounted) return;
      setState(() => _permission = state);
      unawaited(_report(state, fromRequest: true));
      if (state.isUsable) {
        await _reload();
      } else {
        setState(_clearPhotos);
      }
    } finally {
      if (mounted) setState(() => _askingOs = false);
    }
  }

  Future<void> _openSettings() async {
    final opened = await _gallery.openSettings();
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Open your device settings to change photo access.'),
      ));
    }
  }

  /// Keeps the account's record of the Photos permission up to date. Failing to save it must
  /// not get in the way of looking at photos, so errors are ignored here; the Permissions
  /// screen shows them.
  Future<void> _report(PermissionState state, {required bool fromRequest}) async {
    try {
      await widget.permissionSyncService.report(AppPermission.photos, state, fromRequest: fromRequest);
    } on ApiException {
      // Ignored, see above.
    }
  }

  void _clearPhotos() {
    _generation++;
    _photos.clear();
    _nextPage = 0;
    _hasMore = true;
    _loadingFirst = false;
    _loadingMore = false;
    _firstPageFailed = false;
    _moreFailed = false;
  }

  /// Starts again from the newest photo, e.g. after Refresh or a filter change.
  Future<void> _reload() async {
    _gallery.reset();
    setState(() {
      _clearPhotos();
      _loadingFirst = true;
    });
    await _loadNext();
  }

  Future<void> _loadNext() async {
    if (_loadingMore || !_hasMore) return;
    final generation = _generation;
    final first = _photos.isEmpty;
    setState(() {
      _loadingMore = true;
      _moreFailed = false;
      _firstPageFailed = false;
    });
    try {
      final page = await _gallery.loadPage(_nextPage, range: _range);
      if (!mounted || generation != _generation) return;
      setState(() {
        _photos.addAll(page);
        _nextPage++;
        _hasMore = page.length >= _gallery.pageSize;
      });
    } on PhotoGalleryException {
      if (!mounted || generation != _generation) return;
      setState(() => first ? _firstPageFailed = true : _moreFailed = true);
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _loadingMore = false;
          _loadingFirst = false;
        });
      }
    }
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 800 && !_moreFailed && !_loadingFirst) {
      unawaited(_loadNext());
    }
  }

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(1990),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _range,
      helpText: 'Show photos taken between',
    );
    if (picked == null || !mounted) return;
    setState(() => _range = picked);
    await _reload();
  }

  Future<void> _clearDates() async {
    setState(() => _range = null);
    await _reload();
  }

  void _openPhoto(PhotoItem photo) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PhotoViewerScreen(photo: photo, galleryService: _gallery),
    ));
  }

  /// Loaded photos whose file name contains the search text.
  List<PhotoItem> get _visible {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _photos;
    return _photos.where((p) => p.name?.toLowerCase().contains(query) ?? false).toList();
  }

  @override
  Widget build(BuildContext context) {
    final usable = _permission?.isUsable ?? false;
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: const AppBarGradient(),
        title: const Text('Photos'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _askingOs ? null : () => _checkPermission(),
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: switch (_permission) {
          null => const Center(child: CircularProgressIndicator()),
          _ when usable => RefreshIndicator(onRefresh: _reload, child: _buildGallery(context)),
          final state => _buildNoAccess(state),
        },
      ),
    );
  }

  Widget _buildNoAccess(PermissionState state) {
    return switch (state) {
      PermissionState.denied => _Message(
          icon: Icons.photo_library_rounded,
          title: 'Photo access is needed to show your gallery.',
          body: 'Child Assist only reads your photos on this device to show them here. '
              'They are not uploaded.',
          action: GradientButton(
            gradient: AppGradients.photos,
            onPressed: _askingOs ? null : _allowPhotos,
            label: const Text('Allow Photos'),
          ),
        ),
      PermissionState.permanentlyDenied => _Message(
          icon: Icons.block_rounded,
          gradient: AppGradients.danger,
          title: 'Photo access is currently blocked.',
          body: 'You can enable it later from Settings.',
          action: GradientButton(
            gradient: AppGradients.photos,
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
            label: const Text('Open Settings'),
          ),
        ),
      PermissionState.restricted => const _Message(
          icon: Icons.lock_outline_rounded,
          title: 'Photo access is restricted on this device.',
          body: 'It is limited by a device setting (for example parental controls) and cannot be '
              'changed from the app.',
        ),
      _ => const _Message(
          icon: Icons.hide_image_outlined,
          title: 'Photos are not available on this device.',
        ),
    };
  }

  Widget _buildGallery(BuildContext context) {
    final visible = _visible;
    final searching = _query.trim().isNotEmpty;
    final theme = Theme.of(context);
    return CustomScrollView(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(child: _buildFilters(context)),
        if (_permission == PermissionState.limited) SliverToBoxAdapter(child: _buildLimitedBanner()),
        if (_loadingFirst)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_firstPageFailed)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _Message(
              icon: Icons.error_outline_rounded,
              gradient: AppGradients.danger,
              title: 'Unable to load photos.',
              body: 'Please try again.',
              action: GradientButton(
                gradient: AppGradients.photos,
                onPressed: _reload,
                label: const Text('Retry'),
              ),
            ),
          )
        else if (_photos.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _range != null
                ? const _Message(
                    icon: Icons.event_busy_rounded,
                    title: 'No photos in these dates',
                    body: 'Try a different date range.',
                  )
                : const _Message(
                    icon: Icons.photo_outlined,
                    title: 'No photos found',
                    body: "Your device gallery doesn't contain any photos yet.",
                  ),
          )
        else ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
              child: Row(
                children: [
                  Icon(
                    searching ? Icons.manage_search_rounded : Icons.collections_rounded,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      searching
                          ? visible.isEmpty
                              ? 'No loaded photos have a name containing "${_query.trim()}".'
                              : '${visible.length} of ${_photos.length} loaded photos match.'
                          : 'Newest first',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: PhotoGrid(photos: visible, galleryService: _gallery, onTap: _openPhoto),
          ),
          SliverToBoxAdapter(child: _buildFooter()),
        ],
      ],
    );
  }

  Widget _buildFilters(BuildContext context) {
    final l10n = MaterialLocalizations.of(context);
    final range = _range;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppSpacing.radius),
              boxShadow: AppTheme.softShadow(context),
            ),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search photos by name...',
                prefixIcon: const Icon(Icons.search_rounded),
                fillColor: theme.colorScheme.surface,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
              textInputAction: TextInputAction.search,
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ActionChip(
                avatar: const Icon(Icons.calendar_month_rounded, size: 18),
                backgroundColor: range == null ? null : AppColors.pink.withValues(alpha: 0.12),
                side: range == null ? null : BorderSide(color: AppColors.pink.withValues(alpha: 0.4)),
                label: Text(range == null
                    ? 'Any date'
                    : '${l10n.formatShortDate(range.start)} – ${l10n.formatShortDate(range.end)}'),
                onPressed: _pickDates,
              ),
              if (range != null)
                ActionChip(
                  avatar: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('Clear dates'),
                  onPressed: _clearDates,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLimitedBanner() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: InfoBanner(
        tone: BannerTone.warning,
        icon: Icons.photo_filter_outlined,
        message: const Text(
          "You've allowed access to selected photos only. Only those photos are shown here.",
        ),
        actions: [
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: _askingOs ? null : _changeSelection,
            child: const Text('Select more photos'),
          ),
          TextButton(onPressed: _openSettings, child: const Text('Open Settings')),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    final Widget child;
    if (_loadingMore) {
      child = const CircularProgressIndicator();
    } else if (_moreFailed) {
      child = Column(
        children: [
          const Text("Couldn't load more photos."),
          TextButton(onPressed: _loadNext, child: const Text('Retry')),
        ],
      );
    } else if (_hasMore) {
      child = OutlinedButton.icon(
        onPressed: _loadNext,
        icon: const Icon(Icons.expand_more_rounded),
        label: const Text('Load more'),
      );
    } else {
      child = const SizedBox.shrink();
    }
    return Padding(padding: const EdgeInsets.all(20), child: Center(child: child));
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    this.body,
    this.action,
    this.gradient = AppGradients.photos,
  });

  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;
  final Gradient gradient;

  @override
  Widget build(BuildContext context) {
    return StateMessage(icon: icon, title: title, body: body, action: action, gradient: gradient);
  }
}
