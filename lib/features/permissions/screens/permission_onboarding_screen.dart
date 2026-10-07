import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/permissions/permission_service.dart';
import '../../../core/widgets/widgets.dart';
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
    final finishing = _finishingPhase;
    final title = finishing ? 'Almost done' : _step.title;
    final icon = finishing ? Icons.check_rounded : _step.icon;
    final gradient = finishing ? AppGradients.location : _gradientFor(_step.permission);

    return Scaffold(
      body: Stack(
        children: [
          // A soft wash of the step's colour behind the stage; it cross-fades between steps.
          Positioned.fill(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    gradient.colors.first.withValues(alpha: theme.brightness == Brightness.dark ? 0.22 : 0.14),
                    theme.scaffoldBackgroundColor,
                  ],
                  stops: const [0, 0.65],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
                  child: Row(
                    children: [
                      const AppLogo(size: 34),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text('Quick setup', style: theme.textTheme.titleSmall),
                      ),
                      TextButton(
                        onPressed: widget.authService.logout,
                        child: const Text('Log out'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 450),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: (child, animation) => FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: Tween(begin: const Offset(0.08, 0), end: Offset.zero).animate(animation),
                              child: child,
                            ),
                          ),
                          layoutBuilder: (current, previous) => Stack(
                            alignment: Alignment.center,
                            children: [...previous, ?current],
                          ),
                          child: Column(
                            key: ValueKey(finishing ? 'finish' : 'step-$_index'),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _IconStage(icon: icon, gradient: gradient),
                              const SizedBox(height: 28),
                              Semantics(
                                header: true,
                                child: Text(
                                  title,
                                  style: theme.textTheme.headlineSmall,
                                  textAlign: TextAlign.center,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                finishing ? 'Saving your choices to your account.' : _step.description,
                                style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                                textAlign: TextAlign.center,
                              ),
                              ..._buildStatus(theme),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ..._buildActions(gradient),
                          const SizedBox(height: 18),
                          _ProgressDots(current: _index, total: _steps.length, color: gradient.colors.last),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static LinearGradient _gradientFor(AppPermission permission) => switch (permission) {
        AppPermission.location => AppGradients.location,
        AppPermission.camera => AppGradients.profile,
        AppPermission.microphone => AppGradients.microphone,
        AppPermission.photos => AppGradients.photos,
        AppPermission.notifications => AppGradients.notifications,
        AppPermission.contacts => AppGradients.documents,
      };

  List<Widget> _buildStatus(ThemeData theme) {
    final Widget? message = switch (_phase) {
      _Phase.explain => switch (_state) {
        PermissionState.granted => const InfoBanner(
            tone: BannerTone.success,
            message: Text('This is already allowed on this device.'),
          ),
        PermissionState.limited => const InfoBanner(
            tone: BannerTone.success,
            message: Text('Limited access is already allowed on this device.'),
          ),
        _ => null,
      },
      _Phase.blocked => InfoBanner(
          tone: BannerTone.warning,
          icon: Icons.block_rounded,
          message: Text(
            _state == PermissionState.restricted
                ? 'This permission is restricted on this device and cannot be changed from the app.'
                : 'Permission is currently blocked.\n\nYou can enable it later from Settings.',
            style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      _Phase.saveFailed => InfoBanner(
          tone: BannerTone.danger,
          message: Text('Could not save your choice to your account: $_error'),
        ),
      _Phase.finishFailed => InfoBanner(
          tone: BannerTone.danger,
          message: Text('Could not finish setup: $_error'),
        ),
      _ => null,
    };
    if (message == null) return const [];
    return [
      const SizedBox(height: 22),
      FadeSlideIn(offset: const Offset(0, 12), child: message),
    ];
  }

  List<Widget> _buildActions(LinearGradient gradient) {
    GradientButton primary(String label, VoidCallback onPressed) =>
        GradientButton(gradient: gradient, onPressed: onPressed, label: Text(label));

    return switch (_phase) {
      _Phase.explain => [primary('Continue', _requestPermission)],
      _Phase.blocked => [
        primary('Continue', _continueFromBlocked),
        if (_state == PermissionState.permanentlyDenied) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(54)),
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
            label: const Text('Open Settings'),
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
              child: const CircularProgressIndicator(strokeCap: StrokeCap.round),
            ),
          ),
        ),
      ],
    };
  }
}

/// The step's icon on a gradient disc, inside two soft rings, popping in on each step.
class _IconStage extends StatelessWidget {
  const _IconStage({required this.icon, required this.gradient});

  final IconData icon;
  final LinearGradient gradient;

  @override
  Widget build(BuildContext context) {
    final tint = gradient.colors.first;
    return ExcludeSemantics(
      child: PopIn(
        from: 0.5,
        child: Container(
          width: 176,
          height: 176,
          decoration: BoxDecoration(shape: BoxShape.circle, color: tint.withValues(alpha: 0.08)),
          alignment: Alignment.center,
          child: Container(
            width: 136,
            height: 136,
            decoration: BoxDecoration(shape: BoxShape.circle, color: tint.withValues(alpha: 0.14)),
            alignment: Alignment.center,
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: gradient,
                boxShadow: AppTheme.glow(gradient.colors.last),
              ),
              child: Icon(icon, size: 46, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

/// An animated pill track ("━━ ● ● ●") plus "2 of 5". Screen readers hear "Step 2 of 5".
class _ProgressDots extends StatelessWidget {
  const _ProgressDots({required this.current, required this.total, required this.color});

  final int current;
  final int total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        ExcludeSemantics(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < total; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOutCubic,
                  width: i == current ? 28 : 10,
                  height: 10,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(5),
                    color: i <= current ? color : theme.colorScheme.outlineVariant,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(
          '${current + 1} of $total',
          semanticsLabel: 'Step ${current + 1} of $total',
          style: theme.textTheme.labelMedium,
        ),
      ],
    );
  }
}
