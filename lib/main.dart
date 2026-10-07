import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_services.dart';
import 'core/navigation/app_menu.dart';
import 'core/widgets/widgets.dart';
import 'features/auth/screens/login_screen.dart';
import 'features/auth/services/auth_service.dart';
import 'features/home/app_shell.dart';
import 'features/permissions/screens/permission_onboarding_screen.dart';
import 'features/permissions/services/permission_onboarding_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Draw edge to edge: screens paint their own header behind a transparent status bar.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
  ));
  final services = AppServices.create();
  services.authService.restoreSession();
  // Push notifications: Firebase Cloud Messaging delivery only. Picks up a notification tap that
  // launched the app; it is opened once the session is restored and the app is ready.
  services.notificationService.start();
  runApp(MyApp(services: services));
}

class MyApp extends StatefulWidget {
  const MyApp({super.key, required this.services});

  final AppServices services;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  late AuthStatus _lastStatus = widget.services.authService.status;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    widget.services.authService.addListener(_onAuthChanged);
    // Back from Settings or the background: Automatic Location History checks the OS again
    // (stops if a permission was revoked, resumes if it was fixed) and retries unsent places.
    _lifecycle = AppLifecycleListener(onResume: _onResume);
  }

  void _onResume() {
    final services = widget.services;
    services.automaticTrackingService.recheck();
    // A permission changed in Settings is reported to the account (the server tells the user if
    // one Child Assist relies on was turned off), and push registration follows the notification
    // permission. Status checks only; no dialogs.
    services.permissionSyncService.reportDeviceStatuses(services.permissionService);
    services.notificationService.syncRegistration();
    services.notificationService.refreshUnreadCount();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    widget.services.authService.removeListener(_onAuthChanged);
    super.dispose();
  }

  // On sign-in or sign-out, close any pushed screens (Permissions, Settings, Register, dialogs)
  // so the root shows the right screen and nothing from the previous session stays visible.
  void _onAuthChanged() {
    final status = widget.services.authService.status;
    if (status == _lastStatus) return;
    _lastStatus = status;
    _navigatorKey.currentState?.popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: widget.services.themeMode,
      builder: (context, themeMode, _) => MaterialApp(
        navigatorKey: _navigatorKey,
        title: 'Child Assist',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: themeMode,
        // Above the Navigator, so the menu works on pushed pages too.
        builder: (context, child) => AppMenuScope(controller: widget.services.appMenu, child: child!),
        home: AuthGate(services: widget.services),
      ),
    );
  }
}

/// Shows Login when signed out. When signed in, shows the first-time permission walkthrough
/// if the backend says it has not been completed, otherwise the main app. This is the only place that
/// decides; login, registration and session restore all arrive here.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key, required this.services});

  final AppServices services;

  static const _loading = SplashView(key: ValueKey('splash'));

  @override
  Widget build(BuildContext context) {
    final authService = services.authService;
    final onboarding = services.permissionOnboardingService;
    return ListenableBuilder(
      listenable: Listenable.merge([authService, onboarding]),
      // Cross-fade between Login, the walkthrough and the app instead of cutting.
      builder: (context, _) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 380),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        child: _screen(authService, onboarding),
      ),
    );
  }

  Widget _screen(AuthService authService, PermissionOnboardingService onboarding) {
    final user = authService.currentUser;
    switch (authService.status) {
      case AuthStatus.unknown:
        return _loading;
      case AuthStatus.unauthenticated:
        return LoginScreen(authService: authService);
      case AuthStatus.authenticated:
        if (user == null) return _loading;
        return switch (onboarding.gateFor(user.id)) {
          OnboardingGate.checking => _loading,
          OnboardingGate.failed => _GateError(
            message: onboarding.error,
            onRetry: onboarding.refresh,
            onLogout: authService.logout,
          ),
          OnboardingGate.required => PermissionOnboardingScreen(
            key: ValueKey('onboarding-${user.id}'),
            onboardingService: onboarding,
            permissionService: services.permissionService,
            syncService: services.permissionSyncService,
            authService: authService,
          ),
          OnboardingGate.completed => AppShell(key: ValueKey('home-${user.id}'), services: services),
        };
    }
  }
}

/// Shown when the account's setup state could not be loaded (e.g. the server is unreachable).
class _GateError extends StatelessWidget {
  const _GateError({required this.message, required this.onRetry, required this.onLogout});

  final String? message;
  final VoidCallback onRetry;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: StateMessage(
          icon: Icons.cloud_off_rounded,
          gradient: AppGradients.danger,
          title: "We couldn't reach your account",
          body: message ?? 'Something went wrong.',
          action: GradientButton(onPressed: onRetry, label: const Text('Retry')),
          secondaryAction: TextButton(onPressed: onLogout, child: const Text('Log out')),
        ),
      ),
    );
  }
}
