import 'package:flutter/material.dart';

import 'app_services.dart';
import 'features/auth/screens/login_screen.dart';
import 'features/auth/services/auth_service.dart';
import 'features/home/home_screen.dart';
import 'features/permissions/screens/permission_onboarding_screen.dart';
import 'features/permissions/services/permission_onboarding_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final services = AppServices.create();
  services.authService.restoreSession();
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

  @override
  void initState() {
    super.initState();
    widget.services.authService.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    widget.services.authService.removeListener(_onAuthChanged);
    super.dispose();
  }

  // On sign-in or sign-out, close any pushed screens (Profile, Permissions, Register, dialogs)
  // so the root shows the right screen and nothing from the previous session stays visible.
  void _onAuthChanged() {
    final status = widget.services.authService.status;
    if (status == _lastStatus) return;
    _lastStatus = status;
    _navigatorKey.currentState?.popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Child Assist',
      theme: ThemeData(colorScheme: .fromSeed(seedColor: Colors.deepPurple)),
      home: AuthGate(services: widget.services),
    );
  }
}

/// Shows Login when signed out. When signed in, shows the first-time permission walkthrough
/// if the backend says it has not been completed, otherwise Home. This is the only place that
/// decides; login, registration and session restore all arrive here.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key, required this.services});

  final AppServices services;

  static const _loading = Scaffold(body: Center(child: CircularProgressIndicator()));

  @override
  Widget build(BuildContext context) {
    final authService = services.authService;
    final onboarding = services.permissionOnboardingService;
    return ListenableBuilder(
      listenable: Listenable.merge([authService, onboarding]),
      builder: (context, _) {
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
              OnboardingGate.completed => HomeScreen(services: services),
            };
        }
      },
    );
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
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message ?? 'Something went wrong.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                FilledButton(onPressed: onRetry, child: const Text('Retry')),
                TextButton(onPressed: onLogout, child: const Text('Log out')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
