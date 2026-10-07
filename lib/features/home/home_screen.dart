import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/widgets/widgets.dart';
import '../chat/screens/chat_screen.dart';
import '../documents/screens/documents_screen.dart';
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

  static String _greeting(DateTime now) => switch (now.hour) {
    < 12 => 'Good morning',
    < 17 => 'Good afternoon',
    _ => 'Good evening',
  };

  @override
  Widget build(BuildContext context) {
    final services = widget.services;
    final theme = Theme.of(context);
    final actions = [
      _ActionData(
        icon: Icons.location_on_rounded,
        title: 'Location',
        subtitle: 'View current place',
        gradient: AppGradients.location,
        onTap: () => _open(
          LocationScreen(
            locationService: services.locationService,
            historyService: services.locationHistoryService,
            permissionSyncService: services.permissionSyncService,
          ),
        ),
      ),
      _ActionData(
        icon: Icons.photo_library_rounded,
        title: 'Photos',
        subtitle: 'View your gallery',
        gradient: AppGradients.photos,
        onTap: () => _open(
          PhotosScreen(
            galleryService: services.photoGalleryService,
            permissionSyncService: services.permissionSyncService,
          ),
        ),
      ),
      _ActionData(
        icon: Icons.person_rounded,
        title: 'Profile',
        subtitle: 'Your account details',
        gradient: AppGradients.profile,
        onTap: () => _open(ProfileScreen(profileService: services.profileService)),
      ),
      _ActionData(
        icon: Icons.verified_user_rounded,
        title: 'Permissions',
        subtitle: 'Manage app access',
        gradient: AppGradients.permissions,
        onTap: () => _open(
          PermissionsScreen(permissionService: services.permissionService, syncService: services.permissionSyncService),
        ),
      ),
      _ActionData(
        icon: Icons.description_rounded,
        title: 'Documents',
        subtitle: 'Files from your device',
        gradient: AppGradients.documents,
        onTap: () => _open(DocumentsScreen(documentService: services.documentService)),
      ),
      _ActionData(
        icon: Icons.smart_toy_rounded,
        title: 'Child Assist',
        subtitle: 'Chat with your assistant',
        gradient: AppGradients.brand,
        onTap: () => _open(
          ChatScreen(
            chatService: services.chatService,
            documentService: services.documentService,
            galleryService: services.photoGalleryService,
            permissionService: services.permissionService,
            permissionSyncService: services.permissionSyncService,
            voiceInput: services.voiceInput,
            textToSpeech: services.textToSpeech,
          ),
        ),
      ),
    ];

    return Scaffold(
      body: ListenableBuilder(
        listenable: services.authService,
        builder: (context, _) {
          final user = services.authService.currentUser;
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: HeroHeader(
                  padding: EdgeInsets.fromLTRB(20, MediaQuery.paddingOf(context).top + 12, 20, 28),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 960),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const AppLogo(size: 40, onDark: true),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Child Assist',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              _LogoutPill(busy: _loggingOut, onPressed: _logout),
                            ],
                          ),
                          const SizedBox(height: 24),
                          FadeSlideIn(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${_greeting(DateTime.now())} 👋',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: Colors.white.withValues(alpha: 0.8),
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Welcome, ${user?.displayName ?? ''}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.headlineSmall?.copyWith(color: Colors.white, fontSize: 26),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: _Constrained(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
                    child: FadeSlideIn(
                      index: 1,
                      child: SectionTitle('Quick Actions', subtitle: 'Everything you need, one tap away'),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: _Constrained(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final columns = constraints.maxWidth >= 680 ? 4 : 2;
                        return GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          padding: EdgeInsets.zero,
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: columns,
                            mainAxisSpacing: 14,
                            crossAxisSpacing: 14,
                            mainAxisExtent: 150,
                          ),
                          itemCount: actions.length,
                          itemBuilder: (context, i) => FadeSlideIn(
                            index: i + 2,
                            child: _ActionCard(data: actions[i]),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: _Constrained(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
                    child: FadeSlideIn(
                      index: actions.length + 2,
                      child: AppCard(
                        child: Row(
                          children: [
                            const IconBadge(icon: Icons.lock_rounded, gradient: AppGradients.location, size: 44),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Private by design', style: theme.textTheme.titleSmall),
                                  const SizedBox(height: 2),
                                  Text(
                                    'You decide what Child Assist can use. Change it any time.',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Constrained extends StatelessWidget {
  const _Constrained({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1000), child: child),
    );
  }
}

class _ActionData {
  const _ActionData({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.gradient,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final LinearGradient gradient;
  final VoidCallback onTap;
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.data});

  final _ActionData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = data.gradient.colors.first;
    return Semantics(
      button: true,
      child: AppCard(
        onTap: data.onTap,
        padding: const EdgeInsets.all(16),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // A faint oversized icon in the corner gives each tile some depth.
            Positioned(
              right: -18,
              bottom: -22,
              child: ExcludeSemantics(child: Icon(data.icon, size: 92, color: tint.withValues(alpha: 0.08))),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    IconBadge(icon: data.icon, gradient: data.gradient, size: 46),
                    const Spacer(),
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(color: tint.withValues(alpha: 0.12), shape: BoxShape.circle),
                      child: Icon(Icons.arrow_forward_rounded, size: 16, color: tint),
                    ),
                  ],
                ),
                const Spacer(),
                Text(data.title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(data.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A frosted pill on the header for signing out.
class _LogoutPill extends StatelessWidget {
  const _LogoutPill({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      enabled: !busy,
      child: Material(
        color: Colors.white.withValues(alpha: 0.16),
        shape: StadiumBorder(side: BorderSide(color: Colors.white.withValues(alpha: 0.3))),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: busy ? null : onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                busy
                    ? const ButtonSpinner(size: 16, color: Colors.white)
                    : const Icon(Icons.logout_rounded, size: 18, color: Colors.white),
                const SizedBox(width: 6),
                const Text(
                  'Logout',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
