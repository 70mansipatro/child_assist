import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/components.dart';

/// Every page the menu can jump to.
enum AppDestination {
  dashboard('Dashboard', Icons.home_rounded, AppGradients.brand),
  chat('Chat', Icons.chat_bubble_rounded, AppGradients.brand),
  location('Location', Icons.location_on_rounded, AppGradients.location),
  profile('Profile', Icons.person_rounded, AppGradients.profile),
  photos('Photos', Icons.photo_library_rounded, AppGradients.photos),
  documents('Documents', Icons.description_rounded, AppGradients.documents),
  permissions('Permissions', Icons.verified_user_rounded, AppGradients.permissions),
  notifications('Notifications', Icons.notifications_rounded, AppGradients.notifications),
  settings('App Settings', Icons.settings_rounded, AppGradients.brand);

  const AppDestination(this.label, this.icon, this.gradient);

  final String label;
  final IconData icon;
  final LinearGradient gradient;
}

/// Connects the menu (shown on any page, including pages pushed above the app shell) to the
/// signed-in app shell, which does the actual navigation.
class AppMenuController {
  ValueChanged<AppDestination>? _handler;

  /// True while a signed-in app shell is listening.
  bool get isAttached => _handler != null;

  void attach(ValueChanged<AppDestination> handler) => _handler = handler;

  void detach(ValueChanged<AppDestination> handler) {
    if (_handler == handler) _handler = null;
  }

  void go(AppDestination destination) => _handler?.call(destination);
}

/// Makes the [AppMenuController] available to every route (placed above the Navigator).
class AppMenuScope extends InheritedWidget {
  const AppMenuScope({super.key, required this.controller, required super.child});

  final AppMenuController controller;

  static AppMenuController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppMenuScope>()?.controller;

  @override
  bool updateShouldNotify(AppMenuScope oldWidget) => controller != oldWidget.controller;
}

/// The ☰ button for a page's header. Opens the menu of all pages; [current] is highlighted.
/// Renders nothing when no signed-in app shell is listening.
class AppMenuButton extends StatelessWidget {
  const AppMenuButton({super.key, this.current, this.color});

  final AppDestination? current;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final controller = AppMenuScope.maybeOf(context);
    if (controller == null || !controller.isAttached) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'Menu',
      onPressed: () => _open(context, controller),
      icon: Icon(Icons.menu_rounded, color: color),
    );
  }

  Future<void> _open(BuildContext context, AppMenuController controller) async {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final chosen = await showGeneralDialog<AppDestination>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close menu',
      barrierColor: Colors.black54,
      transitionDuration: reduceMotion ? Duration.zero : const Duration(milliseconds: 260),
      pageBuilder: (_, _, _) => Align(alignment: Alignment.centerRight, child: _MenuPanel(current: current)),
      transitionBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero)
            .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );
    if (chosen != null) controller.go(chosen);
  }
}

/// The side panel: a header like the Dashboard's, then one row per page.
class _MenuPanel extends StatelessWidget {
  const _MenuPanel({required this.current});

  final AppDestination? current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Drawer(
      shape: const RoundedRectangleBorder(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HeroHeader(
            padding: EdgeInsets.fromLTRB(20, MediaQuery.paddingOf(context).top + 20, 20, 24),
            child: Row(
              children: [
                const AppLogo(size: 40, onDark: true),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Child Assist',
                        style: theme.textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
                      ),
                      Text(
                        'Go to a page',
                        style: theme.textTheme.bodySmall?.copyWith(color: Colors.white.withValues(alpha: 0.8)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                for (final destination in AppDestination.values)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                    child: ListTile(
                      selected: destination == current,
                      selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppSpacing.radius)),
                      leading: IconBadge(icon: destination.icon, gradient: destination.gradient, size: 38, glow: false),
                      title: Text(
                        destination.label,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: destination == current ? theme.colorScheme.primary : null,
                        ),
                      ),
                      onTap: () => Navigator.of(context).pop(destination),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
