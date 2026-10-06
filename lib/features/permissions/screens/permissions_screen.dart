import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/permissions/permission_service.dart';
import '../../../core/widgets/widgets.dart';
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
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListenableBuilder(
                listenable: widget.syncService,
                builder: (context, _) => Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
                      children: [
                        FadeSlideIn(child: _buildSummary(theme)),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 250),
                          child: _syncError == null
                              ? const SizedBox(width: double.infinity)
                              : Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: InfoBanner(
                                    tone: BannerTone.danger,
                                    icon: Icons.cloud_off_rounded,
                                    message: Text('Could not save to your account: $_syncError'),
                                  ),
                                ),
                        ),
                        const SizedBox(height: 22),
                        const SectionTitle('Device permissions'),
                        const SizedBox(height: 10),
                        for (final (i, permission) in AppPermission.values.indexed)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: FadeSlideIn(index: i + 1, child: _buildRow(permission)),
                          ),
                        const SizedBox(height: 18),
                        const SectionTitle(
                          'Test permission features',
                          subtitle: 'Try how each feature asks for access',
                        ),
                        const SizedBox(height: 10),
                        for (final permission in AppPermission.values)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                alignment: Alignment.centerLeft,
                                backgroundColor: theme.colorScheme.surface,
                                foregroundColor: theme.colorScheme.onSurface,
                                side: BorderSide(color: theme.colorScheme.outlineVariant),
                              ),
                              onPressed: _busy == null ? () => _testFeature(permission) : null,
                              icon: Icon(_icon(permission), color: _gradient(permission).colors.first),
                              label: Text('Test ${permission.label} Permission'),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  /// "3 of 5 allowed" with a progress bar, on the brand gradient.
  Widget _buildSummary(ThemeData theme) {
    final available = AppPermission.values
        .where((p) => _device[p] != PermissionState.unavailable && _device[p] != null)
        .toList();
    final allowed = available.where((p) => _device[p]!.isUsable).length;
    final total = available.isEmpty ? AppPermission.values.length : available.length;
    return AppCard(
      gradient: AppGradients.permissions,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.shield_rounded, color: Colors.white),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$allowed/$total allowed',
                      style: theme.textTheme.titleLarge?.copyWith(color: Colors.white),
                    ),
                    Text(
                      'Your privacy, your choice',
                      style: theme.textTheme.bodySmall?.copyWith(color: Colors.white.withValues(alpha: 0.85)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: total == 0 ? 0 : allowed / total),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => LinearProgressIndicator(
                value: value,
                minHeight: 8,
                color: Colors.white,
                backgroundColor: Colors.white.withValues(alpha: 0.22),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'You can change any of these at any time. Your device decides what is '
            'allowed; your account keeps a record of the latest status.',
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.white.withValues(alpha: 0.9)),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(AppPermission permission) {
    final theme = Theme.of(context);
    final state = _device[permission] ?? PermissionState.unavailable;
    final saved = widget.syncService.serverStatuses[permission] ?? SyncedPermissionStatus.unknown;
    return AppCard(
      key: ValueKey('permission-${permission.name}'),
      padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
      child: Row(
        children: [
          IconBadge(icon: _icon(permission), gradient: _gradient(permission), size: 46),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(permission.label, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: StatusDot(color: _statusColor(state)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${_statusLabel(state)} · Saved to account: ${_syncedLabel(saved)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: _busy == permission
                ? const Padding(
                    padding: EdgeInsets.all(8),
                    child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
                  )
                : _buildAction(permission, state),
          ),
        ],
      ),
    );
  }

  Widget _buildAction(AppPermission permission, PermissionState state) {
    final enabled = _busy == null;
    const compact = Size(0, 40);
    const padding = EdgeInsets.symmetric(horizontal: 16);
    return switch (state) {
      PermissionState.denied => FilledButton(
          key: const ValueKey('allow'),
          style: FilledButton.styleFrom(minimumSize: compact, padding: padding),
          onPressed: enabled ? () => _onRowAction(permission) : null,
          child: const Text('Allow'),
        ),
      PermissionState.granted || PermissionState.limited => OutlinedButton(
          key: const ValueKey('manage'),
          style: OutlinedButton.styleFrom(minimumSize: compact, padding: padding),
          onPressed: enabled ? () => _onRowAction(permission) : null,
          child: const Text('Manage'),
        ),
      PermissionState.permanentlyDenied => OutlinedButton(
          key: const ValueKey('settings'),
          style: OutlinedButton.styleFrom(
            minimumSize: compact,
            padding: padding,
            foregroundColor: AppColors.danger,
            side: BorderSide(color: AppColors.danger.withValues(alpha: 0.4)),
          ),
          onPressed: enabled ? () => _onRowAction(permission) : null,
          child: const Text('Open settings'),
        ),
      PermissionState.restricted || PermissionState.unavailable => const SizedBox.shrink(),
    };
  }

  static Color _statusColor(PermissionState state) => switch (state) {
        PermissionState.granted => AppColors.success,
        PermissionState.limited => AppColors.warning,
        PermissionState.denied => AppColors.inkMuted,
        PermissionState.permanentlyDenied => AppColors.danger,
        PermissionState.restricted || PermissionState.unavailable => const Color(0xFFB0B3C7),
      };

  static LinearGradient _gradient(AppPermission permission) => switch (permission) {
        AppPermission.location => AppGradients.location,
        AppPermission.microphone => AppGradients.microphone,
        AppPermission.camera => AppGradients.profile,
        AppPermission.photos => AppGradients.photos,
        AppPermission.notifications => AppGradients.notifications,
      };

  static IconData _icon(AppPermission permission) => switch (permission) {
        AppPermission.location => Icons.location_on_rounded,
        AppPermission.microphone => Icons.mic_rounded,
        AppPermission.camera => Icons.photo_camera_rounded,
        AppPermission.photos => Icons.photo_library_rounded,
        AppPermission.notifications => Icons.notifications_rounded,
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
