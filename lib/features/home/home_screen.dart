import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../location/screens/location_screen.dart';
import '../permissions/screens/permissions_screen.dart';
import '../photos/screens/photos_screen.dart';
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
                Text('Quick Actions', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                _QuickAction(
                  icon: Icons.location_on_outlined,
                  title: 'Location',
                  subtitle: 'View current place',
                  onTap: () => _open(LocationScreen(
                    locationService: services.locationService,
                    historyService: services.locationHistoryService,
                    permissionSyncService: services.permissionSyncService,
                  )),
                ),
                _QuickAction(
                  icon: Icons.photo_library_outlined,
                  title: 'Photos',
                  subtitle: 'View your gallery',
                  onTap: () => _open(PhotosScreen(
                    galleryService: services.photoGalleryService,
                    permissionSyncService: services.permissionSyncService,
                  )),
                ),
                _QuickAction(
                  icon: Icons.person_outline,
                  title: 'Profile',
                  onTap: () => _open(ProfileScreen(profileService: services.profileService)),
                ),
                _QuickAction(
                  icon: Icons.verified_user_outlined,
                  title: 'Permissions',
                  onTap: () => _open(PermissionsScreen(
                    permissionService: services.permissionService,
                    syncService: services.permissionSyncService,
                  )),
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

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.icon, required this.title, this.subtitle, required this.onTap});

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
