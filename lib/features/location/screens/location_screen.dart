import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/permissions/permission_service.dart';
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
    _lifecycle = AppLifecycleListener(onResume: () {
      if (!_locating) unawaited(_recheckAccess());
    });
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
        title: const Text('Clear Location History?'),
        content: const Text(
          'This will permanently delete your saved location history from Child Assist.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(deleted == 1 ? 'Deleted 1 saved location' : 'Deleted $deleted saved locations'),
      ));
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Open your device settings to change this.'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _locating || _clearing;
    return Scaffold(
      appBar: AppBar(title: const Text('My Location')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: widget.historyService,
          builder: (context, _) {
            final records = widget.historyService.records;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card.outlined(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.privacy_tip_outlined, color: theme.colorScheme.primary),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'Your location is saved only when you choose to get your current '
                            'location.\n\nChild Assist does not track your location continuously.',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _buildCurrentCard(theme),
                if (_failure != null) ...[
                  const SizedBox(height: 12),
                  _buildFailureCard(theme, _failure!),
                ],
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: busy ? null : _getCurrentLocation,
                  icon: _locating
                      ? const SizedBox.square(
                          dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(_current == null ? Icons.my_location : Icons.refresh),
                  label: Text(_locating
                      ? 'Getting location...'
                      : _current == null
                          ? 'Get Current Location'
                          : 'Refresh Location'),
                ),
                if (_saveError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _saveError!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(child: Text('Location History', style: theme.textTheme.titleMedium)),
                    TextButton.icon(
                      onPressed: busy || _historyLoading ? null : _loadHistory,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Refresh'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ..._buildHistory(theme, records),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: busy || records.isEmpty ? null : _confirmClear,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Clear Location History'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildCurrentCard(ThemeData theme) {
    final current = _current;
    return Card(
      key: const ValueKey('location-current'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.location_on, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('Current Location', style: theme.textTheme.titleMedium),
            ]),
            const SizedBox(height: 12),
            if (_locating) ...[
              Text('Getting location...', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              const Text('Please wait while we get your current location from your device.'),
            ] else if (current == null)
              const Text('Tap "Get Current Location" to see your real device location.')
            else ...[
              if (_saved) ...[
                Row(children: [
                  Icon(Icons.check_circle, size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Text('Location updated', style: TextStyle(color: theme.colorScheme.primary)),
                ]),
                const SizedBox(height: 12),
              ],
              if (current.hasPlace) ...[
                Text(current.placeName!, style: theme.textTheme.titleLarge),
                if (current.areaLine != null) Text(current.areaLine!, style: theme.textTheme.bodyLarge),
              ] else ...[
                Text(
                  '${formatCoordinate(current.latitude)}, ${formatCoordinate(current.longitude)}',
                  style: theme.textTheme.titleLarge,
                ),
                Text('Place name unavailable', style: theme.textTheme.bodyMedium),
              ],
              const SizedBox(height: 16),
              _field(theme, 'Latitude', formatCoordinate(current.latitude)),
              _field(theme, 'Longitude', formatCoordinate(current.longitude)),
              _field(theme, 'Accuracy', formatAccuracy(current.accuracy)),
              _field(theme, 'Updated', formatUpdated(current.capturedAt)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _field(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelMedium),
          Text(value, style: theme.textTheme.bodyLarge),
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
      LocationFailure.timeout || LocationFailure.unavailable => (
          'Location is currently unavailable.\nPlease try again.',
          null,
        ),
    };
    return Card(
      key: const ValueKey('location-failure'),
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(message, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
            if (action != null) ...[
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: _locating || _clearing ? null : action.$2,
                child: Text(action.$1),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _buildHistory(ThemeData theme, List<LocationRecord> records) {
    if (_historyLoading && records.isEmpty) {
      return const [Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))];
    }
    return [
      if (_historyError != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Could not load your location history: $_historyError',
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      if (records.isEmpty && _historyError == null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              Icon(Icons.location_on_outlined, size: 36, color: theme.colorScheme.outline),
              const SizedBox(height: 8),
              Text('No location history yet.', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                'Your saved locations will appear here after you get your current location.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      for (final record in records) _buildHistoryItem(theme, record),
    ];
  }

  Widget _buildHistoryItem(ThemeData theme, LocationRecord record) {
    final coordinates = '${formatCoordinate(record.latitude)}, ${formatCoordinate(record.longitude)}';
    final when = '${formatCapturedAt(record.capturedAt)} • Accuracy: ${formatAccuracy(record.accuracy)}';
    final place = record.placeName;
    return Card(
      key: ValueKey('location-${record.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.location_on, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(place ?? coordinates, style: theme.textTheme.titleMedium),
                  if (place != null && record.areaLine != null) Text(record.areaLine!),
                  if (place == null) Text('Place name unavailable', style: theme.textTheme.bodySmall),
                  const SizedBox(height: 6),
                  if (place != null) Text(coordinates, style: theme.textTheme.bodySmall),
                  Text(when, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
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
