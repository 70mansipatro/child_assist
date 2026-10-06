import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../permissions/screens/permissions_screen.dart';
import '../profile/screens/profile_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.services});

  final AppServices services;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _loggingOut = false;

  Future<void> _logout() async {
    setState(() => _loggingOut = true);
    // AuthService clears the token and notifies listeners; the app switches to Login.
    await widget.services.authService.logout();
  }

  void _open(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final services = widget.services;
    final user = services.authService.currentUser;
    return Scaffold(
      appBar: AppBar(title: const Text('Child Assist')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Welcome, ${user?.displayName ?? ''}',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                FilledButton.tonalIcon(
                  onPressed: () => _open(ProfileScreen(profileService: services.profileService)),
                  icon: const Icon(Icons.person_outline),
                  label: const Text('Profile'),
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: () => _open(PermissionsScreen(
                    permissionService: services.permissionService,
                    syncService: services.permissionSyncService,
                  )),
                  icon: const Icon(Icons.verified_user_outlined),
                  label: const Text('Permissions'),
                ),
                const SizedBox(height: 32),
                OutlinedButton.icon(
                  onPressed: _loggingOut ? null : _logout,
                  icon: const Icon(Icons.logout),
                  label: const Text('Logout'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
