import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/permissions/permission_service.dart';
import '../../auth/services/auth_service.dart';
import '../models/permission_onboarding.dart';
import '../services/permission_onboarding_service.dart';
import '../services/permission_sync_service.dart';

enum _Phase {
  /// Checking the current OS status of the step's permission (no dialog).
  checking,

  /// Explaining the permission; "Continue" shows the real system dialog.
  explain,

  /// The system dialog is showing.
  requesting,

  /// Saving the OS result to the user's account.
  saving,
  saveFailed,

  /// The OS will not show a dialog for this permission (blocked or restricted).
  blocked,

  /// All steps done; marking the walkthrough completed on the backend.
  finishing,
  finishFailed,
}

/// The first-time permission walkthrough: one permission at a time, in
/// [permissionOnboardingSteps] order. Each step explains the permission, then shows the real
/// system dialog; whatever the user picks is saved to their account and the next step follows.
/// A denial never stops the walkthrough.
class PermissionOnboardingScreen extends StatefulWidget {
  const PermissionOnboardingScreen({
    super.key,
    required this.onboardingService,
    required this.permissionService,
    required this.syncService,
    required this.authService,
  });

  final PermissionOnboardingService onboardingService;
  final PermissionService permissionService;
  final PermissionSyncService syncService;
  final AuthService authService;

  @override
  State<PermissionOnboardingScreen> createState() => _PermissionOnboardingScreenState();
}

class _PermissionOnboardingScreenState extends State<PermissionOnboardingScreen> {
  static const _steps = permissionOnboardingSteps;

  int _index = 0;
  _Phase _phase = _Phase.checking;

  /// The OS state for the current step: the pre-check result, then the dialog result.
  PermissionState? _state;
  String? _error;

  PermissionOnboardingStep get _step => _steps[_index];

  @override
  void initState() {
    super.initState();
    _resume();
  }

  /// Continues from the step saved on this device, e.g. after the app was closed mid-way.
  Future<void> _resume() async {
    final saved = (await widget.onboardingService.savedStep()).clamp(0, _steps.length);
    if (!mounted) return;
    if (saved >= _steps.length) {
      setState(() => _index = _steps.length - 1);
      await _finish();
    } else {
      await _enterStep(saved);
    }
  }

  Future<void> _enterStep(int index) async {
    setState(() {
      _index = index;
      _phase = _Phase.checking;
      _state = null;
      _error = null;
    });
    final state = await widget.permissionService.status(_step.permission);
    if (!mounted) return;
    if (state == PermissionState.permanentlyDenied || state == PermissionState.restricted) {
      // Asking again would not show a dialog: record it and explain instead.
      await _record(state);
    } else {
      setState(() {
        _state = state;
        _phase = _Phase.explain;
      });
    }
  }

  Future<void> _requestPermission() async {
    setState(() => _phase = _Phase.requesting);
    // Checks first and shows the system dialog only if the OS still allows asking.
    final state = await widget.permissionService.request(_step.permission);
    if (mounted) await _record(state);
  }

  /// Saves the OS result to the account, then moves on (or explains a blocked permission).
  Future<void> _record(PermissionState state) async {
    setState(() {
      _state = state;
      _phase = _Phase.saving;
      _error = null;
    });
    try {
      await widget.syncService.report(_step.permission, state, fromRequest: true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.saveFailed;
          _error = e.message;
        });
      }
      return;
    }
    if (!mounted) return;
    if (state == PermissionState.permanentlyDenied || state == PermissionState.restricted) {
      setState(() => _phase = _Phase.blocked);
    } else {
      await _advance();
    }
  }

  Future<void> _continueFromBlocked() async {
    // The user may have enabled it in Settings meanwhile: save that instead.
    final now = await widget.permissionService.status(_step.permission);
    if (!mounted) return;
    if (now.isUsable) {
      await _record(now);
    } else {
      await _advance();
    }
  }

  Future<void> _advance() async {
    final next = _index + 1;
    await widget.onboardingService.saveStep(next);
    if (!mounted) return;
    if (next < _steps.length) {
      await _enterStep(next);
    } else {
      await _finish();
    }
  }

  /// Marks the walkthrough completed. Home appears only once the backend confirms it.
  Future<void> _finish() async {
    setState(() {
      _phase = _Phase.finishing;
      _error = null;
    });
    try {
      await widget.onboardingService.complete();
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.finishFailed;
          _error = e.message;
        });
      }
    }
  }

  Future<void> _openSettings() async {
    final opened = await widget.permissionService.openSettings();
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Open your device settings to change this permission.')),
      );
    }
  }

  bool get _finishingPhase => _phase == _Phase.finishing || _phase == _Phase.finishFailed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final finishing = _finishingPhase;
    final title = finishing ? 'Almost done' : _step.title;
    final icon = finishing ? Icons.check_circle_outline : _step.icon;

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: TextButton(
                  onPressed: widget.authService.logout,
                  child: const Text('Log out'),
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ExcludeSemantics(
                          child: CircleAvatar(
                            radius: 48,
                            backgroundColor: colors.primaryContainer,
                            child: Icon(icon, size: 48, color: colors.onPrimaryContainer),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Semantics(
                          header: true,
                          child: Text(
                            title,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          finishing ? 'Saving your choices to your account.' : _step.description,
                          style: theme.textTheme.bodyLarge,
                          textAlign: TextAlign.center,
                        ),
                        ..._buildStatus(theme),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ..._buildActions(),
                      const SizedBox(height: 20),
                      _ProgressDots(current: _index, total: _steps.length),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildStatus(ThemeData theme) {
    final error = TextStyle(color: theme.colorScheme.error, fontSize: 16);
    final Widget? message = switch (_phase) {
      _Phase.explain => switch (_state) {
        PermissionState.granted => const Text('This is already allowed on this device.'),
        PermissionState.limited => const Text('Limited access is already allowed on this device.'),
        _ => null,
      },
      _Phase.blocked => Text(
        _state == PermissionState.restricted
            ? 'This permission is restricted on this device and cannot be changed from the app.'
            : 'Permission is currently blocked.\n\nYou can enable it later from Settings.',
        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      _Phase.saveFailed => Text(
        'Could not save your choice to your account: $_error',
        style: error,
      ),
      _Phase.finishFailed => Text('Could not finish setup: $_error', style: error),
      _ => null,
    };
    if (message == null) return const [];
    return [
      const SizedBox(height: 20),
      DefaultTextStyle.merge(textAlign: TextAlign.center, child: message),
    ];
  }

  List<Widget> _buildActions() {
    const minSize = Size.fromHeight(56);
    FilledButton primary(String label, VoidCallback onPressed) => FilledButton(
      style: FilledButton.styleFrom(minimumSize: minSize, textStyle: const TextStyle(fontSize: 18)),
      onPressed: onPressed,
      child: Text(label),
    );

    return switch (_phase) {
      _Phase.explain => [primary('Continue', _requestPermission)],
      _Phase.blocked => [
        primary('Continue', _continueFromBlocked),
        if (_state == PermissionState.permanentlyDenied) ...[
          const SizedBox(height: 12),
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: minSize),
            onPressed: _openSettings,
            child: const Text('Open Settings'),
          ),
        ],
      ],
      _Phase.saveFailed => [primary('Retry', () => _record(_state!))],
      _Phase.finishFailed => [primary('Retry', _finish)],
      _Phase.checking || _Phase.requesting || _Phase.saving || _Phase.finishing => [
        SizedBox(
          height: 56,
          child: Center(
            child: Semantics(
              label: _phase == _Phase.requesting ? 'Waiting for your choice' : 'Please wait',
              child: const CircularProgressIndicator(),
            ),
          ),
        ),
      ],
    };
  }
}

/// "● ● ○ ○ ○" plus "2 of 5". Screen readers hear "Step 2 of 5".
class _ProgressDots extends StatelessWidget {
  const _ProgressDots({required this.current, required this.total});

  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        ExcludeSemantics(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < total; i++)
                Container(
                  width: 12,
                  height: 12,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i <= current ? colors.primary : null,
                    border: Border.all(color: colors.primary, width: 2),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${current + 1} of $total',
          semanticsLabel: 'Step ${current + 1} of $total',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }
}
