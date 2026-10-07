import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../core/navigation/app_menu.dart';
import '../../core/widgets/widgets.dart';
import '../chat/screens/chat_screen.dart';
import '../documents/screens/documents_screen.dart';
import '../location/screens/location_screen.dart';
import '../notifications/screens/notifications_screen.dart';
import '../permissions/screens/permissions_screen.dart';
import '../photos/screens/photos_screen.dart';
import '../profile/screens/profile_screen.dart';
import '../settings/screens/app_settings_screen.dart';
import 'dashboard_screen.dart';

/// The signed-in app: four tabs (Dashboard, Chat, Location, Profile) behind one bottom
/// navigation bar. Everything else (Photos, Documents, Permissions, Notifications, Settings)
/// opens as a full screen on top of it, so there is only ever one navigation bar.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.services});

  final AppServices services;

  static const dashboardTab = 0;
  static const chatTab = 1;
  static const locationTab = 2;
  static const profileTab = 3;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = AppShell.dashboardTab;

  // Tabs are built the first time they are shown, then kept alive so a chat in progress or a
  // fetched location survives switching tabs.
  final _visited = <int>{AppShell.dashboardTab};

  @override
  void initState() {
    super.initState();
    widget.services.appMenu.attach(_go);
  }

  @override
  void dispose() {
    widget.services.appMenu.detach(_go);
    super.dispose();
  }

  /// Opens a page chosen from the ☰ menu: closes whatever is on top, then shows a tab or
  /// pushes the page.
  void _go(AppDestination destination) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    switch (destination) {
      case AppDestination.dashboard:
        _select(AppShell.dashboardTab);
      case AppDestination.chat:
        _select(AppShell.chatTab);
      case AppDestination.location:
        _select(AppShell.locationTab);
      case AppDestination.profile:
        _select(AppShell.profileTab);
      case AppDestination.photos:
        _openPhotos();
      case AppDestination.documents:
        _openDocuments();
      case AppDestination.permissions:
        _openPermissions();
      case AppDestination.notifications:
        _openNotifications();
      case AppDestination.settings:
        _openSettings();
    }
  }

  void _select(int index) {
    if (index == _index) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _index = index;
      _visited.add(index);
    });
  }

  void _push(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  void _openPhotos() => _push(
    PhotosScreen(
      galleryService: widget.services.photoGalleryService,
      permissionSyncService: widget.services.permissionSyncService,
    ),
  );

  void _openDocuments() => _push(DocumentsScreen(documentService: widget.services.documentService));

  void _openPermissions() => _push(
    PermissionsScreen(
      permissionService: widget.services.permissionService,
      syncService: widget.services.permissionSyncService,
    ),
  );

  void _openNotifications() => _push(NotificationsScreen(onOpenPermissions: _openPermissions));

  void _openSettings() => _push(
    AppSettingsScreen(
      textToSpeech: widget.services.textToSpeech,
      themeMode: widget.services.themeMode,
      onLogout: widget.services.authService.logout,
    ),
  );

  Widget _buildTab(int index) {
    final services = widget.services;
    return switch (index) {
      AppShell.dashboardTab => DashboardScreen(
        authService: services.authService,
        photoService: services.profilePhotoService,
        onOpenChat: () => _select(AppShell.chatTab),
        onOpenProfile: () => _select(AppShell.profileTab),
        onOpenPhotos: _openPhotos,
        onOpenDocuments: _openDocuments,
        onOpenPermissions: _openPermissions,
        onOpenNotifications: _openNotifications,
        trackingService: services.automaticTrackingService,
        onOpenLocation: () => _select(AppShell.locationTab),
      ),
      AppShell.chatTab => ChatScreen(
        active: _index == AppShell.chatTab,
        chatService: services.chatService,
        documentService: services.documentService,
        galleryService: services.photoGalleryService,
        permissionService: services.permissionService,
        permissionSyncService: services.permissionSyncService,
        contactService: services.contactService,
        messageHandoff: services.messageHandoff,
        voiceInput: services.voiceInput,
        textToSpeech: services.textToSpeech,
      ),
      AppShell.locationTab => LocationScreen(
        locationService: services.locationService,
        historyService: services.locationHistoryService,
        permissionSyncService: services.permissionSyncService,
        trackingService: services.automaticTrackingService,
      ),
      _ => ProfileScreen(
        profileService: services.profileService,
        photoService: services.profilePhotoService,
        onOpenPermissions: _openPermissions,
        onOpenNotifications: _openNotifications,
        onOpenSettings: _openSettings,
        onLogout: services.authService.logout,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back from any other tab returns to Dashboard; back on Dashboard leaves the app.
      canPop: _index == AppShell.dashboardTab,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _select(AppShell.dashboardTab);
      },
      child: Scaffold(
        body: IndexedStack(
          index: _index,
          children: [
            for (var i = 0; i < 4; i++)
              TickerMode(
                enabled: i == _index,
                child: _visited.contains(i) ? _buildTab(i) : const SizedBox.shrink(),
              ),
          ],
        ),
        bottomNavigationBar: _GradientNavigationBar(selectedIndex: _index, onSelected: _select),
      ),
    );
  }
}

/// The bottom bar: a full-width, square-cornered strip of the Dashboard header's gradient.
/// It is a standard [NavigationBar] on a transparent background, so labels, semantics,
/// keyboard focus and the system-gesture inset all behave natively.
class _GradientNavigationBar extends StatelessWidget {
  const _GradientNavigationBar({required this.selectedIndex, required this.onSelected});

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static final _unselected = Colors.white.withValues(alpha: 0.68);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: AppGradients.navigationBar,
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryDeep.withValues(alpha: isDark ? 0.45 : 0.25),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: NavigationBarTheme(
        data: NavigationBarThemeData(
          height: 68,
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          elevation: 0,
          indicatorColor: Colors.white.withValues(alpha: 0.18),
          indicatorShape: const StadiumBorder(),
          iconTheme: WidgetStateProperty.resolveWith(
            (states) => IconThemeData(
              size: 24,
              color: states.contains(WidgetState.selected) ? Colors.white : _unselected,
            ),
          ),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? Colors.white : _unselected,
            );
          }),
        ),
        child: NavigationBar(
          selectedIndex: selectedIndex,
          onDestinationSelected: onSelected,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: 'Dashboard',
            ),
            NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline_rounded),
              selectedIcon: Icon(Icons.chat_bubble_rounded),
              label: 'Chat',
            ),
            NavigationDestination(
              icon: Icon(Icons.location_on_outlined),
              selectedIcon: Icon(Icons.location_on_rounded),
              label: 'Location',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline_rounded),
              selectedIcon: Icon(Icons.person_rounded),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}
