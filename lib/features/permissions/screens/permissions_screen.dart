import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/permissions/permission_service.dart';
import '../data/permissions_api.dart';
import '../services/permission_sync_service.dart';

/// Shows each device permission's OS status and lets the user allow or manage it.
///
/// Opening this screen only *checks* statuses; a system dialog appears only after the user
/// taps Allow or a test button.
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({
    super.key,
    required this.permissionService,
    required this.syncService,
  });

  final PermissionService permissionService;
  final PermissionSyncService syncService;

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> {
  final Map<AppPermission, PermissionState> _device = {};
  late final AppLifecycleListener _lifecycle;
  AppPermission? _busy;
  bool _loading = true;
  bool _refreshing = false;
  String? _syncError;

  @override
  void initState() {
    super.initState();
    // The user may change permissions in system Settings and come back: re-check then.
    _lifecycle = AppLifecycleListener(onResume: () {
      if (_busy == null) unawaited(_refresh());
    });
    _refresh();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// Reads the OS status of every permission (no dialogs) and syncs real changes.
  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      await _refreshStatuses();
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _refreshStatuses() async {
    String? syncError;
    try {
      await widget.syncService.load();
    } on ApiException catch (e) {
      syncError = e.message;
    }

    for (final permission in AppPermission.values) {
      final state = await widget.permissionService.status(permission);
      if (!mounted) return;
      setState(() => _device[permission] = state);
      if (syncError == null) {
        try {
          await widget.syncService.report(permission, state, fromRequest: false);
        } on ApiException catch (e) {
          syncError = e.message;
        }
      }
    }
    if (mounted) {
      setState(() {
        _loading = false;
        _syncError = syncError;
      });
    }
  }

  /// Checks, requests if still possible, records the OS result, then syncs it to the backend.
  Future<PermissionState> _ask(AppPermission permission) async {
    setState(() => _busy = permission);
    try {
      final state = await widget.permissionService.request(permission);
      if (mounted) setState(() => _device[permission] = state);
      try {
        await widget.syncService.report(permission, state, fromRequest: true);
        if (mounted) setState(() => _syncError = null);
      } on ApiException catch (e) {
        if (mounted) setState(() => _syncError = e.message);
      }
      return state;
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _onRowAction(AppPermission permission) async {
    final state = _device[permission] ?? PermissionState.denied;
    if (state == PermissionState.denied) {
      final result = await _ask(permission);
      if (!mounted) return;
      if (result == PermissionState.permanentlyDenied) {
        await _showResult(permission, result);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${permission.label}: ${_statusLabel(result)}')),
        );
      }
      return;
    }
    await _openSettings();
  }

  /// Simulates opening a feature that needs [permission]: the real features come later.
  Future<void> _testFeature(AppPermission permission) async {
    final result = await _ask(permission);
    if (mounted) await _showResult(permission, result);
  }

  Future<void> _openSettings() async {
    final opened = await widget.permissionService.openSettings();
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Open your device settings to change this permission.'),
      ));
    }
  }

  Future<void> _showResult(AppPermission permission, PermissionState state) {
    final needsSettings = state == PermissionState.permanentlyDenied;
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${permission.label}: ${_statusLabel(state)}'),
        content: Text(_resultMessage(permission, state)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
          if (needsSettings)
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                _openSettings();
              },
              child: const Text('Open settings'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Permissions'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _busy == null ? _refresh : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListenableBuilder(
                listenable: widget.syncService,
                builder: (context, _) => ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Text(
                        'Child Assist asks for a permission only when you use a feature that '
                        'needs it. Your device decides what is allowed; your account keeps a '
                        'record of the latest status.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    if (_syncError != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        child: Text(
                          'Could not save to your account: $_syncError',
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                    for (final permission in AppPermission.values) _buildRow(permission),
                    const Divider(height: 32),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text('Test permission features', style: theme.textTheme.titleMedium),
                    ),
                    const SizedBox(height: 8),
                    for (final permission in AppPermission.values)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        child: OutlinedButton.icon(
                          onPressed: _busy == null ? () => _testFeature(permission) : null,
                          icon: Icon(_icon(permission)),
                          label: Text('Test ${permission.label} Permission'),
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildRow(AppPermission permission) {
    final state = _device[permission] ?? PermissionState.unavailable;
    final saved = widget.syncService.serverStatuses[permission] ?? SyncedPermissionStatus.unknown;
    return ListTile(
      key: ValueKey('permission-${permission.name}'),
      leading: Icon(_icon(permission)),
      title: Text(permission.label),
      subtitle: Text('${_statusLabel(state)} · Saved to account: ${_syncedLabel(saved)}'),
      trailing: _busy == permission
          ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : _buildAction(permission, state),
    );
  }

  Widget _buildAction(AppPermission permission, PermissionState state) {
    final enabled = _busy == null;
    return switch (state) {
      PermissionState.denied => FilledButton(
          onPressed: enabled ? () => _onRowAction(permission) : null,
          child: const Text('Allow'),
        ),
      PermissionState.granted || PermissionState.limited => OutlinedButton(
          onPressed: enabled ? () => _onRowAction(permission) : null,
          child: const Text('Manage'),
        ),
      PermissionState.permanentlyDenied => OutlinedButton(
          onPressed: enabled ? () => _onRowAction(permission) : null,
          child: const Text('Open settings'),
        ),
      PermissionState.restricted || PermissionState.unavailable => const SizedBox.shrink(),
    };
  }

  static IconData _icon(AppPermission permission) => switch (permission) {
        AppPermission.location => Icons.location_on_outlined,
        AppPermission.microphone => Icons.mic_none,
        AppPermission.camera => Icons.photo_camera_outlined,
        AppPermission.photos => Icons.photo_library_outlined,
        AppPermission.notifications => Icons.notifications_none,
      };

  static String _statusLabel(PermissionState state) => switch (state) {
        PermissionState.granted => 'Allowed',
        PermissionState.limited => 'Limited',
        PermissionState.denied => 'Not allowed',
        PermissionState.permanentlyDenied => 'Blocked',
        PermissionState.restricted => 'Restricted',
        PermissionState.unavailable => 'Not available on this device',
      };

  static String _syncedLabel(SyncedPermissionStatus status) => switch (status) {
        SyncedPermissionStatus.unknown => 'Not recorded',
        SyncedPermissionStatus.granted => 'Allowed',
        SyncedPermissionStatus.denied => 'Not allowed',
        SyncedPermissionStatus.restricted => 'Restricted',
        SyncedPermissionStatus.limited => 'Limited',
      };

  static String _resultMessage(AppPermission permission, PermissionState state) {
    final name = permission.label.toLowerCase();
    return switch (state) {
      PermissionState.granted =>
        'The $name permission is allowed. Features that use it will arrive in a later update.',
      PermissionState.limited =>
        'Child Assist has limited $name access. You can change this in your device settings.',
      PermissionState.denied =>
        'The $name permission was not allowed. You will be asked again the next time you use '
            'a feature that needs it.',
      PermissionState.permanentlyDenied =>
        'The $name permission is blocked, so Child Assist cannot ask again. To use this '
            'feature, enable $name for Child Assist in your device settings.',
      PermissionState.restricted =>
        'The $name permission is restricted on this device (for example by parental controls) '
            'and cannot be changed from the app.',
      PermissionState.unavailable =>
        'The $name permission is not available on this device or platform.',
    };
  }
}
