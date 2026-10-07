import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/permissions/permission_service.dart';
import '../../../core/navigation/app_menu.dart';
import '../../../core/widgets/widgets.dart';
import '../../permissions/services/permission_sync_service.dart';
import '../models/location_record.dart';
import '../services/location_history_service.dart';
import '../services/location_service.dart';

/// Shows the user's current location (read only when they tap the button) and the
/// locations they have saved.
///
/// Opening this screen never shows a permission dialog: it only checks the status so it can
/// explain a blocked permission. The OS dialog appears after "Get Current Location".
class LocationScreen extends StatefulWidget {
  const LocationScreen({
    super.key,
    required this.locationService,
    required this.historyService,
    required this.permissionSyncService,
  });

  final LocationService locationService;
  final LocationHistoryService historyService;
  final PermissionSyncService permissionSyncService;

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

  bool _historyLoading = true;
  String? _historyError;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    // The user may change the permission or turn on location in Settings and come back.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (!_locating) unawaited(_recheckAccess());
      },
    );
    _recheckAccess();
    _loadHistory();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
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

  Future<void> _loadHistory() async {
    setState(() {
      _historyLoading = true;
      _historyError = null;
    });
    try {
      await widget.historyService.load();
    } on ApiException catch (e) {
      if (mounted) setState(() => _historyError = e.message);
    } finally {
      if (mounted) setState(() => _historyLoading = false);
    }
  }

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
        setState(() {
          _saved = true;
          _historyError = null;
        });
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
      await _loadHistory();
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
          listenable: widget.historyService,
          builder: (context, _) {
            final records = widget.historyService.records;
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
                          'Your location is saved only when you choose to get your current '
                          'location.\n\nChild Assist does not track your location continuously.',
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
                    SectionTitle(
                      'Location History',
                      subtitle: records.isEmpty
                          ? null
                          : records.length == 1
                          ? '1 saved place'
                          : '${records.length} saved places',
                      trailing: TextButton.icon(
                        onPressed: busy || _historyLoading ? null : _loadHistory,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Refresh'),
                      ),
                    ),
                    const SizedBox(height: 10),
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

  List<Widget> _buildHistory(ThemeData theme, List<LocationRecord> records) {
    if (_historyLoading && records.isEmpty) {
      return const [
        Center(
          child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()),
        ),
      ];
    }
    return [
      if (_historyError != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: InfoBanner(
            tone: BannerTone.danger,
            message: Text('Could not load your location history: $_historyError'),
          ),
        ),
      if (records.isEmpty && _historyError == null)
        FadeSlideIn(
          child: AppCard(
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
                Text('No location history yet.', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  'Your saved locations will appear here after you get your current location.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      for (final (i, record) in records.indexed)
        FadeSlideIn(
          index: i.clamp(0, 8),
          child: _buildHistoryItem(theme, record, first: i == 0, last: i == records.length - 1),
        ),
    ];
  }

  /// One stop on the history timeline: a rail with a dot on the left, the place on the right.
  Widget _buildHistoryItem(ThemeData theme, LocationRecord record, {required bool first, required bool last}) {
    final coordinates = '${formatCoordinate(record.latitude)}, ${formatCoordinate(record.longitude)}';
    final when = '${formatCapturedAt(record.capturedAt)} • Accuracy: ${formatAccuracy(record.accuracy)}';
    final place = record.placeName;
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
                    Text(place ?? coordinates, style: theme.textTheme.titleMedium),
                    if (place != null && record.areaLine != null)
                      Text(record.areaLine!, style: theme.textTheme.bodyMedium),
                    if (place == null) Text('Place name unavailable', style: theme.textTheme.bodySmall),
                    const SizedBox(height: 8),
                    if (place != null)
                      Row(
                        children: [
                          Icon(Icons.explore_outlined, size: 14, color: theme.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Expanded(child: Text(coordinates, style: theme.textTheme.bodySmall)),
                        ],
                      ),
                    Row(
                      children: [
                        Icon(Icons.schedule_rounded, size: 14, color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Expanded(child: Text(when, style: theme.textTheme.bodySmall)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
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

/// "Today, 10:30 AM", "Yesterday, 9:05 PM" or "3 Oct 2026, 8:00 AM", in local time.
String formatCapturedAt(DateTime time, {DateTime? now}) {
  final local = time.toLocal();
  final today = DateUtils.dateOnly(now ?? DateTime.now());
  final day = DateUtils.dateOnly(local);
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final clock = '$hour:${local.minute.toString().padLeft(2, '0')} ${local.hour < 12 ? 'AM' : 'PM'}';

  final dayDiff = today.difference(day).inDays;
  if (dayDiff == 0) return 'Today, $clock';
  if (dayDiff == 1) return 'Yesterday, $clock';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${local.day} ${months[local.month - 1]} ${local.year}, $clock';
}
