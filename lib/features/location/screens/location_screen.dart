import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/permissions/permission_service.dart';
import '../../../core/navigation/app_menu.dart';
import '../../../core/widgets/widgets.dart';
import '../../permissions/services/permission_sync_service.dart';
import '../data/location_api.dart' show maxHistoryResults;
import '../models/location_record.dart';
import '../services/automatic_location_tracking_service.dart';
import '../services/location_history_service.dart';
import '../services/location_service.dart';
import '../widgets/tracking_status.dart';

/// Shows the user's current location (read only when they tap the button), the Automatic
/// Location History switch, today's travel and the locations they have saved.
///
/// Opening this screen never shows a permission dialog: it only checks the status so it can
/// explain a blocked permission. The OS dialogs appear after "Get Current Location", or after
/// the user switches on Automatic Location History and confirms the explanation.
class LocationScreen extends StatefulWidget {
  const LocationScreen({
    super.key,
    required this.locationService,
    required this.historyService,
    required this.permissionSyncService,
    required this.trackingService,
  });

  final LocationService locationService;
  final LocationHistoryService historyService;
  final PermissionSyncService permissionSyncService;
  final AutomaticLocationTrackingService trackingService;

  @override
  State<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends State<LocationScreen> {
  late final AppLifecycleListener _lifecycle;

  DeviceLocation? _current;
  LocationFailure? _failure;
  bool _locating = false;
  bool _saved = false;
  String? _saveError;

  bool _clearing = false;

  // "Search by Date": a single day or a range, chosen with the platform date pickers.
  bool _rangeMode = false;
  DateTime? _customDate;
  DateTimeRange? _customRange;
  String? _customError;

  /// Reload the lists when Automatic Location History stores a new place.
  late int _seenSaves = widget.trackingService.savedCount;

  @override
  void initState() {
    super.initState();
    widget.trackingService.addListener(_onTrackingChanged);
    // The user may change the permission or turn on location in Settings and come back.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (!_locating) unawaited(_recheckAccess());
      },
    );
    _recheckAccess();
    _loadHistory();
    widget.historyService.loadToday();
  }

  @override
  void dispose() {
    widget.trackingService.removeListener(_onTrackingChanged);
    _lifecycle.dispose();
    super.dispose();
  }

  void _onTrackingChanged() {
    final saves = widget.trackingService.savedCount;
    if (saves == _seenSaves) return;
    _seenSaves = saves;
    unawaited(_loadHistory());
    unawaited(widget.historyService.loadToday());
  }

  /// The switch. Turning it on first explains what is collected; only then does the OS ask.
  Future<void> _onTrackingSwitch(bool on) async {
    final tracking = widget.trackingService;
    final messenger = ScaffoldMessenger.of(context);
    if (!on) {
      await tracking.disable();
      messenger.showSnackBar(const SnackBar(
        content: Text('Automatic Location History is off. Places already saved are kept.'),
      ));
      return;
    }
    final confirmed = await _confirmTracking();
    if (confirmed != true || !mounted) return;
    await tracking.enable();
    if (!mounted) return;
    if (tracking.isActive) {
      messenger.showSnackBar(const SnackBar(content: Text('Automatic Location History is on.')));
      unawaited(widget.historyService.loadToday());
    }
  }

  Future<bool?> _confirmTracking() {
    Widget point(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: AppColors.teal),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('automatic-tracking-explanation'),
        icon: const IconBadge(icon: Icons.route_rounded, gradient: AppGradients.location, size: 52),
        title: const Text('Turn on Automatic Location History?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              point(
                Icons.place_outlined,
                'What is saved: the places where you stay for a few minutes, with the time and the place '
                    "name from your phone. Child Assist doesn't record the route you travel.",
              ),
              point(
                Icons.visibility_outlined,
                'Your location will be collected even when the app is closed or not in use. On Android '
                    'a notification shows the whole time this is happening.',
              ),
              point(Icons.battery_alert_outlined, 'Automatic location history may use additional battery.'),
              point(
                Icons.toggle_off_outlined,
                'You can stop it at any time with this switch. Places already saved stay until you clear '
                    'your location history.',
              ),
              point(
                Icons.settings_outlined,
                'Next, your phone will ask for location access. Choose "Allow all the time" so places can '
                    'be saved while the app is closed.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Continue')),
        ],
      ),
    );
  }

  /// Status checks only, no dialogs. Shows a blocked permission up front and clears a
  /// problem the user has fixed in Settings.
  Future<void> _recheckAccess() async {
    final permission = await widget.locationService.permissionStatus();
    final servicesOn = await widget.locationService.isServiceEnabled();
    unawaited(_report(permission, fromRequest: false));
    if (!mounted) return;

    setState(() {
      switch (permission) {
        case PermissionState.permanentlyDenied:
          _failure = LocationFailure.permissionPermanentlyDenied;
        case PermissionState.restricted:
          _failure = LocationFailure.permissionRestricted;
        case PermissionState.granted || PermissionState.limited:
          if (_isPermissionFailure(_failure)) _failure = null;
          if (_failure == LocationFailure.servicesDisabled && servicesOn) _failure = null;
        case PermissionState.denied || PermissionState.unavailable:
          // Was blocked, now askable again (e.g. reset in Settings).
          if (_failure == LocationFailure.permissionPermanentlyDenied) {
            _failure = LocationFailure.permissionDenied;
          }
      }
    });
  }

  /// Reloads whatever the history currently shows. Reads saved records only: no GPS and no
  /// location permission are needed, so history works with location turned off.
  Future<void> _loadHistory() => widget.historyService.load();

  Future<void> _searchFilter(LocationHistoryFilter filter) => widget.historyService.searchFilter(filter);

  Future<void> _pickDate() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: _customDate ?? today,
      firstDate: _firstPickableDate,
      lastDate: today,
      helpText: 'Select a date',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _customDate = picked;
      _customError = null;
    });
  }

  Future<void> _pickRange() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: _customRange,
      firstDate: _firstPickableDate,
      lastDate: today,
      helpText: 'Select a date range',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _customRange = picked;
      _customError = validateHistoryRange(HistoryDateRange(picked.start, picked.end));
    });
  }

  Future<void> _searchCustom() async {
    final query = _rangeMode
        ? (_customRange == null ? null : LocationHistoryQuery.range(_customRange!.start, _customRange!.end))
        : (_customDate == null ? null : LocationHistoryQuery.date(_customDate!));
    if (query == null) return;
    final problem = validateHistoryRange(query.range!);
    setState(() => _customError = problem);
    if (problem != null) return;
    await widget.historyService.search(query);
  }

  /// The pickers go back far enough for any saved history; each search is still at most a year.
  static final _firstPickableDate = DateTime(2000);

  Future<void> _getCurrentLocation() async {
    if (_locating) return; // one request at a time
    setState(() {
      _locating = true;
      _failure = null;
      _saved = false;
      _saveError = null;
    });
    try {
      final result = await widget.locationService.getCurrentLocation();
      if (result.permission != null) unawaited(_report(result.permission!, fromRequest: true));
      if (!mounted) return;

      final location = result.location;
      if (location == null) {
        setState(() => _failure = result.failure);
        return;
      }
      setState(() => _current = location);

      try {
        await widget.historyService.save(location);
        if (!mounted) return;
        setState(() => _saved = true);
      } on ApiException catch (e) {
        if (mounted) setState(() => _saveError = 'Could not save this location: ${e.message}');
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  /// Mirrors the OS permission result to the account, as the Permissions screen does.
  /// A sync failure must never block reading the location.
  Future<void> _report(PermissionState state, {required bool fromRequest}) async {
    try {
      await widget.permissionSyncService.report(AppPermission.location, state, fromRequest: fromRequest);
    } on ApiException {
      // Ignored here; the Permissions screen shows sync problems.
    }
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const IconBadge(icon: Icons.delete_outline_rounded, gradient: AppGradients.danger, size: 52),
        title: const Text('Clear Location History?'),
        content: const Text('This will permanently delete your saved location history from Child Assist.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _clearing = true);
    try {
      final deleted = await widget.historyService.clear();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(deleted == 1 ? 'Deleted 1 saved location' : 'Deleted $deleted saved locations')),
      );
      unawaited(_loadHistory());
      unawaited(widget.historyService.loadToday());
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not clear history: ${e.message}')));
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _openSettings(LocationFailure failure) async {
    final opened = failure == LocationFailure.servicesDisabled
        ? await widget.locationService.openLocationSettings()
        : await widget.locationService.openAppSettings();
    if (!opened && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Open your device settings to change this.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _locating || _clearing;
    return Scaffold(
      appBar: AppBar(flexibleSpace: const AppBarGradient(), title: const Text('My Location'),
        actions: const [AppMenuButton(current: AppDestination.location)],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([widget.historyService, widget.trackingService]),
          builder: (context, _) {
            final history = widget.historyService;
            final records = history.records;
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
                  children: [
                    FadeSlideIn(
                      child: InfoBanner(
                        icon: Icons.privacy_tip_outlined,
                        tone: BannerTone.success,
                        message: const Text(
                          'Your location is saved when you tap "Get Current Location", or automatically '
                          'while you have Automatic Location History switched on.\n\nYou can turn it off '
                          'at any time.',
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FadeSlideIn(index: 1, child: _buildCurrentCard(theme)),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutCubic,
                      child: _failure == null
                          ? const SizedBox(width: double.infinity)
                          : Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: _buildFailureCard(theme, _failure!),
                            ),
                    ),
                    const SizedBox(height: 16),
                    FadeSlideIn(
                      index: 2,
                      child: GradientButton(
                        gradient: AppGradients.location,
                        onPressed: busy ? null : _getCurrentLocation,
                        icon: _locating
                            ? const ButtonSpinner(size: 18)
                            : Icon(_current == null ? Icons.my_location_rounded : Icons.refresh_rounded),
                        label: Text(
                          _locating
                              ? 'Getting location...'
                              : _current == null
                              ? 'Get Current Location'
                              : 'Refresh Location',
                        ),
                      ),
                    ),
                    if (_saveError != null) ...[
                      const SizedBox(height: 10),
                      InfoBanner(tone: BannerTone.danger, message: Text(_saveError!)),
                    ],
                    const SizedBox(height: 28),
                    FadeSlideIn(index: 3, child: _buildAutomaticCard(theme)),
                    const SizedBox(height: 28),
                    ..._buildTodayTravel(theme),
                    const SizedBox(height: 28),
                    SectionTitle(
                      'Location History',
                      subtitle: _historySubtitle(records),
                      trailing: TextButton.icon(
                        onPressed: busy || history.loading
                            ? null
                            : () {
                                unawaited(_loadHistory());
                                unawaited(history.loadToday());
                              },
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Refresh'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _buildQuickFilters(theme),
                    const SizedBox(height: 14),
                    _buildDateSearch(theme),
                    const SizedBox(height: 18),
                    ..._buildHistory(theme, records),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.danger,
                        side: BorderSide(
                          color: AppColors.danger.withValues(alpha: busy || records.isEmpty ? 0.15 : 0.4),
                        ),
                      ),
                      onPressed: busy || records.isEmpty ? null : _confirmClear,
                      icon: const Icon(Icons.delete_outline_rounded),
                      label: const Text('Clear Location History'),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildCurrentCard(ThemeData theme) {
    final current = _current;
    const white = Colors.white;
    final soft = white.withValues(alpha: 0.82);
    return AppCard(
      key: const ValueKey('location-current'),
      gradient: AppGradients.location,
      padding: const EdgeInsets.all(18),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            right: -30,
            top: -30,
            child: IgnorePointer(child: Icon(Icons.public_rounded, size: 150, color: white.withValues(alpha: 0.08))),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.location_on_rounded, color: white, size: 22),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('Current Location', style: theme.textTheme.titleMedium?.copyWith(color: white)),
                  ),
                  if (_saved && !_locating)
                    PopIn(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(color: white, borderRadius: BorderRadius.circular(20)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.check_circle_rounded, size: 16, color: AppColors.success),
                            const SizedBox(width: 5),
                            Text(
                              'Location updated',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: AppColors.success,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                switchInCurve: Curves.easeOutCubic,
                layoutBuilder: (current, previous) =>
                    Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
                child: _locating
                    ? Row(
                        key: const ValueKey('locating'),
                        children: [
                          const PulseHalo(
                            size: 72,
                            color: white,
                            child: Icon(Icons.my_location_rounded, color: white, size: 28),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Getting location...', style: theme.textTheme.titleSmall?.copyWith(color: white)),
                                const SizedBox(height: 2),
                                Text(
                                  'Please wait while we get your current location from your device.',
                                  style: theme.textTheme.bodySmall?.copyWith(color: soft),
                                ),
                              ],
                            ),
                          ),
                        ],
                      )
                    : current == null
                    ? Column(
                        key: const ValueKey('empty'),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Where am I?', style: theme.textTheme.headlineSmall?.copyWith(color: white)),
                          const SizedBox(height: 4),
                          Text(
                            'Tap "Get Current Location" to see your real device location.',
                            style: theme.textTheme.bodyMedium?.copyWith(color: soft),
                          ),
                        ],
                      )
                    : Column(
                        key: ValueKey(current.capturedAt),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (current.hasPlace) ...[
                            Text(current.placeName!, style: theme.textTheme.headlineSmall?.copyWith(color: white)),
                            if (current.areaLine != null)
                              Text(current.areaLine!, style: theme.textTheme.bodyLarge?.copyWith(color: soft)),
                          ] else ...[
                            Text(
                              '${formatCoordinate(current.latitude)}, ${formatCoordinate(current.longitude)}',
                              style: theme.textTheme.headlineSmall?.copyWith(color: white),
                            ),
                            Text('Place name unavailable', style: theme.textTheme.bodyMedium?.copyWith(color: soft)),
                          ],
                          const SizedBox(height: 16),
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final tileWidth = (constraints.maxWidth - 10) / 2;
                              return Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  for (final (icon, label, value) in [
                                    (Icons.north_rounded, 'Latitude', formatCoordinate(current.latitude)),
                                    (Icons.east_rounded, 'Longitude', formatCoordinate(current.longitude)),
                                    (Icons.gps_fixed_rounded, 'Accuracy', formatAccuracy(current.accuracy)),
                                    (Icons.schedule_rounded, 'Updated', formatUpdated(current.capturedAt)),
                                  ])
                                    SizedBox(width: tileWidth, child: _field(theme, icon, label, value)),
                                ],
                              );
                            },
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// A frosted stat tile on the current-location card.
  Widget _field(ThemeData theme, IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.white.withValues(alpha: 0.85)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.labelSmall?.copyWith(color: Colors.white.withValues(alpha: 0.8))),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFailureCard(ThemeData theme, LocationFailure failure) {
    final (message, action) = switch (failure) {
      LocationFailure.permissionDenied => (
        'Location permission is required to get your current location.',
        ('Allow Location', _getCurrentLocation),
      ),
      LocationFailure.permissionPermanentlyDenied => (
        'Location permission is blocked.\n\nPlease enable location access from your device Settings.',
        ('Open Settings', () => _openSettings(failure)),
      ),
      LocationFailure.servicesDisabled => (
        'Location services are turned off.\n\nPlease enable Location on your device.',
        ('Open Settings', () => _openSettings(failure)),
      ),
      LocationFailure.permissionRestricted => (
        'Location access is restricted on this device (for example by parental controls) '
            'and cannot be changed from the app.',
        null,
      ),
      LocationFailure.timeout ||
      LocationFailure.unavailable => ('Location is currently unavailable.\nPlease try again.', null),
    };
    final icon = switch (failure) {
      LocationFailure.servicesDisabled => Icons.location_disabled_rounded,
      LocationFailure.permissionPermanentlyDenied || LocationFailure.permissionRestricted => Icons.block_rounded,
      LocationFailure.timeout || LocationFailure.unavailable => Icons.wifi_tethering_error_rounded,
      LocationFailure.permissionDenied => Icons.location_off_rounded,
    };
    return InfoBanner(
      key: const ValueKey('location-failure'),
      tone: action == null ? BannerTone.warning : BannerTone.danger,
      icon: icon,
      message: Text(message),
      actions: [
        if (action != null)
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 42),
              backgroundColor: AppColors.danger.withValues(alpha: 0.14),
              foregroundColor: AppColors.danger,
            ),
            onPressed: _locating || _clearing ? null : action.$2,
            child: Text(action.$1),
          ),
      ],
    );
  }

  String? _historySubtitle(List<LocationRecord> records) {
    final query = widget.historyService.query;
    final count = records.isEmpty
        ? null
        : records.length == 1
        ? '1 saved place'
        : '${records.length} saved places';
    if (query.isRecent) return count;
    final label = switch (query.filter) {
      LocationHistoryFilter.customDate || LocationHistoryFilter.customRange => formatRangeLabel(query.range!),
      _ => query.filter.label,
    };
    return count == null ? label : '$label • $count';
  }

  /// One-tap periods. Each runs a search straight away.
  Widget _buildQuickFilters(ThemeData theme) {
    final selected = widget.historyService.query.filter;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Quick Search', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final filter in LocationHistoryFilter.quick)
              ChoiceChip(
                key: ValueKey('history-filter-${filter.name}'),
                label: Text(filter.label),
                selected: selected == filter,
                showCheckmark: false,
                selectedColor: AppColors.teal.withValues(alpha: 0.18),
                onSelected: _clearing ? null : (_) => _searchFilter(filter),
              ),
          ],
        ),
      ],
    );
  }

  /// A chosen day or range, searched when the user taps "Search History".
  Widget _buildDateSearch(ThemeData theme) {
    final chosen = _rangeMode ? _customRange != null : _customDate != null;
    return AppCard(
      key: const ValueKey('history-date-search'),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Search by Date', style: theme.textTheme.titleSmall),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Custom Date')),
              ButtonSegment(value: true, label: Text('Custom Date Range')),
            ],
            selected: {_rangeMode},
            showSelectedIcon: false,
            onSelectionChanged: (value) => setState(() {
              _rangeMode = value.first;
              _customError = null;
            }),
          ),
          const SizedBox(height: 12),
          if (_rangeMode)
            Row(
              children: [
                Expanded(child: _dateField(theme, 'From', _customRange?.start, _pickRange, key: 'history-from')),
                const SizedBox(width: 10),
                Expanded(child: _dateField(theme, 'To', _customRange?.end, _pickRange, key: 'history-to')),
              ],
            )
          else
            _dateField(theme, 'Date', _customDate, _pickDate, key: 'history-date'),
          if (_customError != null) ...[
            const SizedBox(height: 8),
            Text(_customError!, style: theme.textTheme.bodySmall?.copyWith(color: AppColors.danger)),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: chosen && !_clearing && _customError == null ? _searchCustom : null,
            icon: const Icon(Icons.search_rounded),
            label: const Text('Search History'),
          ),
        ],
      ),
    );
  }

  Widget _dateField(ThemeData theme, String label, DateTime? value, VoidCallback onTap, {required String key}) {
    return InkWell(
      key: ValueKey(key),
      onTap: _clearing ? null : onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: const Icon(Icons.calendar_month_rounded),
        ),
        child: Text(
          value == null ? 'Select date' : formatShortDate(value),
          style: value == null
              ? theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)
              : theme.textTheme.bodyLarge,
        ),
      ),
    );
  }

  List<Widget> _buildHistory(ThemeData theme, List<LocationRecord> records) {
    final history = widget.historyService;
    final query = history.query;
    final error = history.error;
    if (history.loading && records.isEmpty) {
      return const [
        Center(
          child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()),
        ),
      ];
    }

    // Grouped by local calendar day, keeping the order the server returned.
    final days = <DateTime, List<LocationRecord>>{};
    for (final record in records) {
      (days[DateUtils.dateOnly(record.capturedAt)] ??= []).add(record);
    }

    var index = 0;
    return [
      if (history.loading) const LinearProgressIndicator(minHeight: 2),
      if (error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: InfoBanner(
            key: ValueKey('history-error-${error.kind.name}'),
            tone: BannerTone.danger,
            icon: switch (error.kind) {
              LocationHistoryErrorKind.noConnection => Icons.wifi_off_rounded,
              LocationHistoryErrorKind.serverUnavailable => Icons.cloud_off_rounded,
              LocationHistoryErrorKind.invalidDate => Icons.event_busy_rounded,
              LocationHistoryErrorKind.notAllowed => Icons.lock_outline_rounded,
              LocationHistoryErrorKind.other => Icons.error_outline_rounded,
            },
            message: Text('Could not load your location history: ${error.message}'),
          ),
        ),
      if (records.isEmpty && error == null && !history.loading)
        FadeSlideIn(
          child: AppCard(
            key: const ValueKey('history-empty'),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 26),
            child: Column(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.teal.withValues(alpha: 0.12)),
                  child: const Icon(Icons.route_rounded, size: 30, color: AppColors.teal),
                ),
                const SizedBox(height: 12),
                Text(
                  query.isRecent ? 'No location history yet.' : 'No location history found.',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  query.isRecent
                      ? 'Your saved locations will appear here after you get your current location '
                          'or switch on Automatic Location History.'
                      : 'No saved locations were found for ${formatRangeLabel(query.range!)}.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      if (history.hasMore)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: InfoBanner(
            key: const ValueKey('history-more'),
            tone: BannerTone.warning,
            icon: Icons.filter_list_rounded,
            message: Text(
              query.isRecent
                  ? 'Showing your $maxHistoryResults most recent saved locations.'
                  : 'Showing the first $maxHistoryResults saved locations. Choose a shorter period to see the rest.',
            ),
          ),
        ),
      for (final MapEntry(key: day, value: dayRecords) in days.entries) ...[
        Padding(
          key: ValueKey('history-day-${formatApiDate(day)}'),
          padding: const EdgeInsets.only(top: 6, bottom: 8),
          child: Row(
            children: [
              const Icon(Icons.calendar_today_rounded, size: 16, color: AppColors.teal),
              const SizedBox(width: 8),
              Text(formatLongDate(day), style: theme.textTheme.titleSmall),
            ],
          ),
        ),
        for (final (i, record) in dayRecords.indexed)
          FadeSlideIn(
            index: (index++).clamp(0, 8),
            child: _buildHistoryItem(theme, record, first: i == 0, last: i == dayRecords.length - 1),
          ),
      ],
    ];
  }

  /// One stop on the history timeline: a rail with a dot on the left, the place on the right.
  Widget _buildHistoryItem(ThemeData theme, LocationRecord record, {required bool first, required bool last}) {
    final coordinates = '${formatCoordinate(record.latitude)}, ${formatCoordinate(record.longitude)}';
    final when = '${formatClock(record.capturedAt)} • Accuracy: ${formatAccuracy(record.accuracy)}';
    final place = record.placeName;
    // The device's full address, when it says more than the place and area lines already do.
    final address = record.address;
    final showAddress = place != null &&
        address != null &&
        address != joinParts([place, record.areaLine]) &&
        address != record.areaLine;
    final railColor = theme.colorScheme.outlineVariant;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 28,
            child: Column(
              children: [
                Container(width: 2, height: 18, color: first ? Colors.transparent : railColor),
                Container(
                  width: first ? 16 : 12,
                  height: first ? 16 : 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: first ? AppGradients.location : null,
                    color: first ? null : theme.colorScheme.surface,
                    border: first ? null : Border.all(color: AppColors.teal, width: 2.5),
                    boxShadow: first ? AppTheme.glow(AppColors.teal, strength: 0.6) : null,
                  ),
                ),
                Expanded(child: Container(width: 2, color: last ? Colors.transparent : railColor)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: AppCard(
                key: ValueKey('location-${record.id}'),
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: Text(place ?? coordinates, style: theme.textTheme.titleMedium)),
                        const SizedBox(width: 8),
                        _sourceChip(theme, record),
                      ],
                    ),
                    if (place != null && record.areaLine != null)
                      Text(record.areaLine!, style: theme.textTheme.bodyMedium),
                    if (place == null) Text('Place name unavailable', style: theme.textTheme.bodySmall),
                    const SizedBox(height: 8),
                    if (showAddress) _detail(theme, Icons.home_work_outlined, address),
                    if (place != null) _detail(theme, Icons.explore_outlined, coordinates),
                    _detail(theme, Icons.schedule_rounded, when),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// "Auto" or "Manual", so the user can tell how each place was saved.
  Widget _sourceChip(ThemeData theme, LocationRecord record) {
    final color = record.isAutomatic ? AppColors.violet : AppColors.teal;
    return Container(
      key: ValueKey('source-${record.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(record.isAutomatic ? Icons.route_rounded : Icons.touch_app_rounded, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            record.isAutomatic ? 'Auto' : 'Manual',
            style: theme.textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildAutomaticCard(ThemeData theme) {
    final tracking = widget.trackingService;
    final state = describeTracking(tracking);
    final status = tracking.status;
    final issue = tracking.issue;
    final working = tracking.busy || status == AutomaticTrackingStatus.starting;

    final (String? help, List<(String, VoidCallback)> actions) = switch (status) {
      AutomaticTrackingStatus.permissionRequired => (
        switch (issue) {
          TrackingIssue.backgroundPermission =>
            'Open Settings, then Permissions › Location, and choose "Allow all the time" for Child Assist.',
          TrackingIssue.restricted => 'Location access is restricted on this device and cannot be changed from the app.',
          _ => 'Allow location access for Child Assist to continue.',
        },
        [
          if (issue != TrackingIssue.restricted) ('Open Settings', () => unawaited(tracking.openAppSettings())),
          if (issue == TrackingIssue.locationPermission) ('Try Again', () => unawaited(tracking.enable())),
        ],
      ),
      AutomaticTrackingStatus.paused => (
        'Turn on Location on your device to continue.',
        [('Open Location Settings', () => unawaited(widget.locationService.openLocationSettings()))],
      ),
      AutomaticTrackingStatus.error when issue != TrackingIssue.unsupported => (
        null,
        [('Try Again', () => unawaited(tracking.enable()))],
      ),
      _ => (null, const <(String, VoidCallback)>[]),
    };

    return AppCard(
      key: const ValueKey('automatic-tracking-card'),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const IconBadge(icon: Icons.route_rounded, gradient: AppGradients.location, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Automatic Location History', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      'Automatically save significant places you visit so Child Assist can show your travel '
                      'history later.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Switch(
                key: const ValueKey('automatic-tracking-switch'),
                value: tracking.enabled,
                activeThumbColor: Colors.white,
                activeTrackColor: AppColors.teal,
                onChanged: working || _clearing || (!tracking.isSupported && !tracking.enabled)
                    ? null
                    : _onTrackingSwitch,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: state.color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            ),
            child: Row(
              children: [
                if (working)
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                else
                  Icon(state.icon, size: 18, color: state.color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: 'Status: ', style: theme.textTheme.bodyMedium),
                      TextSpan(
                        text: state.label,
                        style: theme.textTheme.bodyMedium?.copyWith(color: state.color, fontWeight: FontWeight.w600),
                      ),
                    ]),
                    key: const ValueKey('automatic-tracking-status'),
                  ),
                ),
              ],
            ),
          ),
          if (state.detail != null && status != AutomaticTrackingStatus.active) ...[
            const SizedBox(height: 10),
            Text(state.detail!, style: theme.textTheme.bodyMedium),
          ],
          if (help != null) ...[
            const SizedBox(height: 6),
            Text(help, style: theme.textTheme.bodySmall),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (label, onPressed) in actions)
                  FilledButton.tonal(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                    onPressed: working ? null : onPressed,
                    child: Text(label),
                  ),
              ],
            ),
          ],
          if (tracking.isActive && tracking.notificationsBlocked) ...[
            const SizedBox(height: 10),
            Text(
              'Notifications are off for Child Assist, so the tracking notification is hidden from the '
              'notification shade. Android still lists Child Assist as an active app while it tracks.',
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (tracking.pendingUploads > 0) ...[
            const SizedBox(height: 10),
            Row(
              key: const ValueKey('automatic-tracking-pending'),
              children: [
                const Icon(Icons.cloud_upload_outlined, size: 16, color: AppColors.inkMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    tracking.pendingUploads == 1
                        ? '1 place is waiting to be uploaded. It will be sent when you are back online.'
                        : '${tracking.pendingUploads} places are waiting to be uploaded. They will be sent '
                              'when you are back online.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
          if (tracking.enabled) ...[
            const SizedBox(height: 10),
            Text(
              'Automatic location history may use additional battery. If your phone stops it in the '
              "background, check Child Assist's battery settings.",
              style: theme.textTheme.bodySmall,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => unawaited(tracking.openAppSettings()),
                icon: const Icon(Icons.battery_saver_outlined, size: 18),
                label: const Text('App & battery settings'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Today's places, manual and automatic, in the order they were saved.
  List<Widget> _buildTodayTravel(ThemeData theme) {
    final history = widget.historyService;
    final records = history.todayRecords;
    final error = history.todayError;
    return [
      SectionTitle(
        "Today's Travel",
        subtitle: records.isEmpty ? null : (records.length == 1 ? '1 place' : '${records.length} places'),
      ),
      const SizedBox(height: 10),
      if (history.todayLoading && records.isEmpty)
        const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
      else if (error != null)
        InfoBanner(
          key: const ValueKey('today-error'),
          tone: BannerTone.danger,
          icon: Icons.error_outline_rounded,
          message: Text("Could not load today's travel: ${error.message}"),
        )
      else if (records.isEmpty)
        AppCard(
          key: const ValueKey('today-empty'),
          padding: const EdgeInsets.all(16),
          child: Text(
            widget.trackingService.isActive
                ? 'No places saved today yet. A place appears here after you stay somewhere for a few minutes.'
                : 'No places saved today. Switch on Automatic Location History, or tap "Get Current Location".',
            style: theme.textTheme.bodySmall,
          ),
        )
      else
        AppCard(
          key: const ValueKey('today-travel'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            children: [
              for (final (i, record) in records.indexed) ...[
                if (i > 0) Divider(height: 1, color: theme.colorScheme.outlineVariant),
                Padding(
                  key: ValueKey('today-${record.id}'),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 74,
                        child: Text(formatClock(record.capturedAt), style: theme.textTheme.labelLarge),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(record.placeName ?? 'Location unavailable', style: theme.textTheme.titleSmall),
                            Text(
                              record.placeName == null
                                  ? '${formatCoordinate(record.latitude)}, ${formatCoordinate(record.longitude)}'
                                  : (record.areaLine ?? ''),
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      _sourceChip(theme, record),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
    ];
  }

  Widget _detail(ThemeData theme, IconData icon, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
      ],
    );
  }

  static bool _isPermissionFailure(LocationFailure? f) =>
      f == LocationFailure.permissionDenied || f == LocationFailure.permissionPermanentlyDenied;
}

/// Up to 6 decimals (about 10 cm), without trailing zeros.
String formatCoordinate(double value) {
  final text = value.toStringAsFixed(6);
  return text.contains('.') ? text.replaceFirst(RegExp(r'\.?0+$'), '') : text;
}

String formatAccuracy(double? metres) => metres == null ? 'Unknown' : '${metres.round()} m';

/// "Just now", "5 min ago", or the full time for anything older than an hour.
String formatUpdated(DateTime time, {DateTime? now}) {
  final elapsed = (now ?? DateTime.now()).difference(time);
  if (elapsed.inMinutes < 1) return 'Just now';
  if (elapsed.inMinutes < 60) return '${elapsed.inMinutes} min ago';
  return formatCapturedAt(time, now: now);
}

/// "10:30 AM", in local time.
String formatClock(DateTime time) {
  final local = time.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  return '$hour:${local.minute.toString().padLeft(2, '0')} ${local.hour < 12 ? 'AM' : 'PM'}';
}

/// "Today, 10:30 AM", "Yesterday, 9:05 PM" or "3 Oct 2026, 8:00 AM", in local time.
String formatCapturedAt(DateTime time, {DateTime? now}) {
  final local = time.toLocal();
  final today = DateUtils.dateOnly(now ?? DateTime.now());
  final day = DateUtils.dateOnly(local);
  final clock = formatClock(local);

  final dayDiff = today.difference(day).inDays;
  if (dayDiff == 0) return 'Today, $clock';
  if (dayDiff == 1) return 'Yesterday, $clock';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${local.day} ${months[local.month - 1]} ${local.year}, $clock';
}
