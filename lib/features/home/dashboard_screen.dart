import 'package:flutter/material.dart';

import '../../core/widgets/widgets.dart';

/// The Dashboard tab: a greeting, a shortcut into Chat, and cards for the features that do
/// not have their own tab (Photos, Documents, Permissions, Notifications).
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({
    super.key,
    required this.onOpenChat,
    required this.onOpenPhotos,
    required this.onOpenDocuments,
    required this.onOpenPermissions,
    required this.onOpenNotifications,
  });

  final VoidCallback onOpenChat;
  final VoidCallback onOpenPhotos;
  final VoidCallback onOpenDocuments;
  final VoidCallback onOpenPermissions;
  final VoidCallback onOpenNotifications;

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
      ),
    ];

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: HeroHeader(
              padding: EdgeInsets.fromLTRB(20, MediaQuery.paddingOf(context).top + 12, 20, 28),
              child: _Constrained(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const AppLogo(size: 40, onDark: true),
                        const SizedBox(width: 10),
                        Semantics(
                          header: true,
                          child: Text(
                            'Child Assist',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    FadeSlideIn(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            "Hi, I'm Child Assist! 👋",
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineSmall?.copyWith(color: Colors.white, fontSize: 26),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'How can I help you today?',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    FadeSlideIn(index: 1, child: _AskButton(onPressed: onOpenChat)),
                  ],
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

/// A frosted "ask" field on the header that opens the Chat tab.
class _AskButton extends StatelessWidget {
  const _AskButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      child: Material(
        color: Colors.white.withValues(alpha: 0.16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radius),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                const Icon(Icons.chat_bubble_rounded, size: 20, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Ask Child Assist',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.95), fontWeight: FontWeight.w600),
                  ),
                ),
                const Icon(Icons.arrow_forward_rounded, size: 18, color: Colors.white),
              ],
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
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final LinearGradient gradient;
  final VoidCallback onTap;
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
