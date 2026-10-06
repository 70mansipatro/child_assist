import 'package:flutter/material.dart';

import 'app_services.dart';
import 'features/auth/screens/login_screen.dart';
import 'features/auth/services/auth_service.dart';
import 'features/home/home_screen.dart';

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

/// Shows Login or Home depending on the current authentication state.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final authService = services.authService;
    return ListenableBuilder(
      listenable: authService,
      builder: (context, _) {
        switch (authService.status) {
          case AuthStatus.unknown:
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          case AuthStatus.authenticated:
            return HomeScreen(services: services);
          case AuthStatus.unauthenticated:
            return LoginScreen(authService: authService);
        }
      },
    );
  }
}
