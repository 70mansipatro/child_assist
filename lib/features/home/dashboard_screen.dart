import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/widgets/widgets.dart';
import '../auth/models/user.dart';
import '../../core/notifications/notification_service.dart';
import '../auth/services/auth_service.dart';
import '../location/services/automatic_location_tracking_service.dart';
import '../location/widgets/tracking_status.dart';
import '../profile/services/profile_photo_service.dart';

/// The Dashboard tab: a greeting, a shortcut into Chat, and cards for the features that do
/// not have their own tab (Photos, Documents, Permissions, Notifications).
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({
    super.key,
    required this.authService,
    required this.photoService,
    this.now = DateTime.now,
    required this.onOpenChat,
    required this.onOpenProfile,
    required this.onOpenPhotos,
    required this.onOpenDocuments,
    required this.onOpenPermissions,
    required this.onOpenNotifications,
    this.notificationService,
    this.trackingService,
    this.onOpenLocation,
  });

  /// The signed-in user; the greeting follows it, including name changes made in Profile.
  final AuthService authService;

  /// The profile photo shown in the corner avatar.
  final ProfilePhotoService photoService;

  /// The device's local time, for "Good morning/afternoon/evening". Replaceable in tests.
  final DateTime Function() now;

  final VoidCallback onOpenChat;
  final VoidCallback onOpenProfile;
  final VoidCallback onOpenPhotos;
  final VoidCallback onOpenDocuments;
  final VoidCallback onOpenPermissions;
  final VoidCallback onOpenNotifications;

  /// Shows the unread count on the Notifications card when set.
  final NotificationService? notificationService;

  /// Shows the Automatic Location History status card when set; tapping it calls [onOpenLocation].
  final AutomaticLocationTrackingService? trackingService;
  final VoidCallback? onOpenLocation;

  /// 05:00–11:59 morning, 12:00–17:59 afternoon, otherwise evening (device local time).
  static String timeOfDayGreeting(DateTime time) => switch (time.hour) {
    >= 5 && < 12 => 'Good morning',
    >= 12 && < 18 => 'Good afternoon',
    _ => 'Good evening',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final features = [
      _FeatureData(
        icon: Icons.photo_library_rounded,
        title: 'Photos',
        subtitle: 'View your photos and memories',
        gradient: AppGradients.photos,
        onTap: onOpenPhotos,
      ),
      _FeatureData(
        icon: Icons.description_rounded,
        title: 'Documents',
        subtitle: 'Find your notes and files',
        gradient: AppGradients.documents,
        onTap: onOpenDocuments,
      ),
      _FeatureData(
        icon: Icons.verified_user_rounded,
        title: 'Permissions',
        subtitle: 'Manage your app permissions',
        gradient: AppGradients.permissions,
        onTap: onOpenPermissions,
      ),
      _FeatureData(
        icon: Icons.notifications_rounded,
        title: 'Notifications',
        subtitle: 'View your notifications',
        gradient: AppGradients.notifications,
        onTap: onOpenNotifications,
        badge: notificationService,
      ),
    ];

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: HeroHeader(
              padding: EdgeInsets.fromLTRB(20, MediaQuery.paddingOf(context).top + 14, 20, 32),
              child: _Constrained(
                child: ListenableBuilder(
                  listenable: Listenable.merge([authService, photoService]),
                  builder: (context, _) {
                    final user = authService.currentUser;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const AppLogo(size: 36, onDark: true),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Semantics(
                                header: true,
                                child: Text(
                                  'Child Assist',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                            _UserAvatar(user: user, photo: photoService.photo, onPressed: onOpenProfile),
                          ],
                        ),
                        const SizedBox(height: 30),
                        FadeSlideIn(child: _Greeting(greeting: timeOfDayGreeting(now()), user: user)),
                        const SizedBox(height: 24),
                        FadeSlideIn(index: 1, child: _AskButton(onPressed: onOpenChat)),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: _Constrained(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
                child: FadeSlideIn(
                  index: 2,
                  child: SectionTitle('Explore', subtitle: 'Everything you need, one tap away'),
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
                        mainAxisExtent: 172,
                      ),
                      itemCount: features.length,
                      itemBuilder: (context, i) => FadeSlideIn(
                        index: i + 3,
                        child: _FeatureCard(data: features[i]),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          if (trackingService != null)
            SliverToBoxAdapter(
              child: _Constrained(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                  child: FadeSlideIn(
                    index: features.length + 3,
                    child: AutomaticTrackingStatusCard(service: trackingService!, onTap: onOpenLocation ?? () {}),
                  ),
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: _Constrained(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
                child: FadeSlideIn(
                  index: features.length + 3,
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
      ),
    );
  }
}

/// A small "Good afternoon 👋", the user's name large on its own line, then one quiet line
/// inviting a question. Without a name (not set yet, or still loading) it says "Welcome back".
class _Greeting extends StatelessWidget {
  const _Greeting({required this.greeting, required this.user});

  final String greeting;
  final User? user;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = user?.name?.trim();
    final hasName = name != null && name.isNotEmpty;
    return MergeSemantics(
      child: Column(
        key: const ValueKey('dashboard-greeting'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$greeting 👋',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: Colors.white.withValues(alpha: 0.82),
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            hasName ? name : 'Welcome back',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            hasName ? 'Welcome back! How can I help you today?' : 'How can I help you today?',
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white.withValues(alpha: 0.72)),
          ),
        ],
      ),
    );
  }
}

/// The user's photo, or their initials in a frosted circle; opens the Profile tab.
class _UserAvatar extends StatelessWidget {
  const _UserAvatar({required this.user, required this.photo, required this.onPressed});

  final User? user;
  final Uint8List? photo;
  final VoidCallback onPressed;

  static String _initials(String? name) {
    final words = (name ?? '').trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(2);
    return words.map((w) => w.characters.first.toUpperCase()).join();
  }

  static Widget _initialsOrIcon(String initials) => Center(
    child: initials.isEmpty
        ? const Icon(Icons.person_rounded, color: Colors.white, size: 22)
        : Text(
            initials,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
          ),
  );

  @override
  Widget build(BuildContext context) {
    final initials = _initials(user?.name);
    return Tooltip(
      message: 'Your profile',
      child: PressableScale(
        child: Material(
          color: Colors.white.withValues(alpha: 0.18),
          shape: CircleBorder(side: BorderSide(color: Colors.white.withValues(alpha: 0.4))),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: SizedBox.square(
              dimension: 40,
              child: photo != null
                  ? Image.memory(
                      photo!,
                      key: const ValueKey('dashboard-photo'),
                      fit: BoxFit.cover,
                      cacheWidth: 160,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => _initialsOrIcon(initials),
                    )
                  : _initialsOrIcon(initials),
            ),
          ),
        ),
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

/// A white, search-style bar on the header that opens the Chat tab.
class _AskButton extends StatelessWidget {
  const _AskButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppSpacing.radius);
    return PressableScale(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(color: AppColors.primaryDeep.withValues(alpha: 0.35), blurRadius: 24, offset: const Offset(0, 10)),
          ],
        ),
        child: Material(
          color: Colors.white,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  const Icon(Icons.auto_awesome_rounded, size: 20, color: AppColors.primary),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Ask Child Assist anything…',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: AppTheme.fontFamily,
                        color: AppColors.inkMuted,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(gradient: AppGradients.brand, borderRadius: BorderRadius.circular(12)),
                    child: const Icon(Icons.arrow_forward_rounded, size: 20, color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FeatureData {
  const _FeatureData({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.gradient,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final LinearGradient gradient;
  final VoidCallback onTap;

  /// Unread notifications, shown on the card's icon.
  final NotificationService? badge;
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({required this.data});

  final _FeatureData data;

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
                    data.badge == null
                        ? IconBadge(icon: data.icon, gradient: data.gradient, size: 46)
                        : ListenableBuilder(
                            listenable: data.badge!,
                            builder: (context, _) {
                              final unread = data.badge!.unreadCount;
                              return Badge(
                                isLabelVisible: unread > 0,
                                label: Text(unread > 99 ? '99+' : '$unread', key: const ValueKey('dashboard-unread')),
                                backgroundColor: AppColors.coral,
                                textColor: Colors.white,
                                child: IconBadge(icon: data.icon, gradient: data.gradient, size: 46),
                              );
                            },
                          ),
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
                // Always two lines tall, so titles line up whether the subtitle wraps or not.
                Stack(
                  children: [
                    ExcludeSemantics(
                      child: Opacity(opacity: 0, child: Text('\n', style: theme.textTheme.bodySmall)),
                    ),
                    Text(data.subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
