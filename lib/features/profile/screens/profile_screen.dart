import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/navigation/app_menu.dart';
import '../../../core/notifications/notification_service.dart';
import '../../../core/widgets/widgets.dart';
import '../models/profile.dart';
import '../services/profile_photo_service.dart';
import '../services/profile_service.dart';

/// The Profile tab: the account's name and email, links to Permissions, Notifications and
/// App Settings, and Logout.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.profileService,
    required this.photoService,
    required this.onOpenPermissions,
    required this.onOpenNotifications,
    this.notificationService,
    required this.onOpenSettings,
    required this.onLogout,
  });

  final ProfileService profileService;
  final ProfilePhotoService photoService;
  final VoidCallback onOpenPermissions;
  final VoidCallback onOpenNotifications;

  /// Shows the unread count on the Notifications row when set.
  final NotificationService? notificationService;
  final VoidCallback onOpenSettings;
  final Future<void> Function() onLogout;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Profile? _profile;
  String? _error;
  bool _loading = true;
  bool _loggingOut = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final profile = await widget.profileService.load();
      if (mounted) setState(() => _profile = profile);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _editProfile() async {
    final updated = await showDialog<Profile>(
      context: context,
      builder: (_) => _EditNameDialog(
        profileService: widget.profileService,
        initialName: _profile?.name ?? '',
      ),
    );
    if (updated != null && mounted) {
      setState(() => _profile = updated);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profile saved')));
    }
  }

  /// Choose a new photo from the gallery, or remove the current one. Photos stay on this phone.
  Future<void> _changePhoto() async {
    final hasPhoto = widget.photoService.photo != null;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MenuTile(
              icon: Icons.photo_library_rounded,
              gradient: AppGradients.photos,
              title: hasPhoto ? 'Change photo' : 'Choose photo',
              subtitle: 'Pick from your gallery. It stays on this phone.',
              onTap: () => Navigator.of(sheetContext).pop('choose'),
            ),
            if (hasPhoto)
              MenuTile(
                icon: Icons.delete_outline_rounded,
                gradient: AppGradients.danger,
                title: 'Remove photo',
                onTap: () => Navigator.of(sheetContext).pop('remove'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (action == 'choose') {
        if (await widget.photoService.choosePhoto()) {
          messenger.showSnackBar(const SnackBar(content: Text('Photo updated')));
        }
      } else {
        await widget.photoService.removePhoto();
        messenger.showSnackBar(const SnackBar(content: Text('Photo removed')));
      }
    } on ProfilePhotoException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text("Couldn't use that photo. Please try another one.")));
    }
  }

  Future<void> _logout() async {
    setState(() => _loggingOut = true);
    // AuthService clears the token and notifies listeners; the app switches to Login.
    await widget.onLogout();
  }

  @override
  Widget build(BuildContext context) {
    // Once loaded, the title sits inside the gradient header and scrolls away with it.
    return Scaffold(
      appBar: _profile == null ? AppBar(
              flexibleSpace: const AppBarGradient(),
              title: const Text('Profile'),
              actions: const [AppMenuButton(current: AppDestination.profile)],
            ) : null,
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading && _profile == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final profile = _profile;
    if (profile == null) {
      return SafeArea(
        child: StateMessage(
          icon: Icons.person_off_outlined,
          gradient: AppGradients.profile,
          title: 'Profile unavailable',
          body: _error ?? 'Could not load your profile.',
          action: OutlinedButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
          ),
          secondaryAction: TextButton(onPressed: _loggingOut ? null : _logout, child: const Text('Logout')),
        ),
      );
    }

    final theme = Theme.of(context);
    final hasName = profile.name?.isNotEmpty == true;
    final divider = Divider(height: 1, indent: 72, endIndent: 16, color: theme.colorScheme.outlineVariant);
    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        HeroHeader(
          gradient: AppGradients.hero,
          padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top, 16, 64),
          child: Column(
            children: [
              SizedBox(
                height: kToolbarHeight,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const Align(
                      alignment: Alignment.centerRight,
                      child: AppMenuButton(current: AppDestination.profile, color: Colors.white),
                    ),
                    Semantics(
                      header: true,
                      child: Text(
                        'Profile',
                        style: theme.appBarTheme.titleTextStyle?.copyWith(color: Colors.white) ??
                            theme.textTheme.titleLarge?.copyWith(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              PopIn(
                child: ListenableBuilder(
                  listenable: widget.photoService,
                  builder: (context, _) => _ProfileAvatar(
                    profile: profile,
                    photo: widget.photoService.photo,
                    onChangePhoto: _changePhoto,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              FadeSlideIn(
                child: Text(
                  'My Account',
                  style: theme.textTheme.titleMedium?.copyWith(color: Colors.white.withValues(alpha: 0.9)),
                ),
              ),
            ],
          ),
        ),
        Transform.translate(
          offset: const Offset(0, -40),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FadeSlideIn(
                      index: 1,
                      child: AppCard(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          children: [
                            _InfoRow(
                              icon: Icons.badge_outlined,
                              gradient: AppGradients.profile,
                              label: 'Name',
                              value: hasName ? profile.name! : 'Not set',
                              muted: !hasName,
                            ),
                            Divider(indent: 72, endIndent: 16, color: theme.colorScheme.outlineVariant),
                            _InfoRow(
                              icon: Icons.mail_outline_rounded,
                              gradient: AppGradients.notifications,
                              label: 'Email',
                              value: profile.email,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    FadeSlideIn(
                      index: 2,
                      child: AppCard(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          children: [
                            MenuTile(
                              icon: Icons.manage_accounts_rounded,
                              gradient: AppGradients.profile,
                              title: 'Account',
                              subtitle: 'Edit your name',
                              onTap: _editProfile,
                            ),
                            divider,
                            MenuTile(
                              icon: Icons.verified_user_rounded,
                              gradient: AppGradients.permissions,
                              title: 'Permissions',
                              subtitle: 'Manage your app permissions',
                              onTap: widget.onOpenPermissions,
                            ),
                            divider,
                            ListenableBuilder(
                              listenable: widget.notificationService ?? const _NoUpdates(),
                              builder: (context, _) {
                                final unread = widget.notificationService?.unreadCount ?? 0;
                                return MenuTile(
                                  icon: Icons.notifications_rounded,
                                  gradient: AppGradients.notifications,
                                  title: 'Notifications',
                                  subtitle: unread > 0 ? '$unread unread' : 'View your notifications',
                                  onTap: widget.onOpenNotifications,
                                  trailing: unread > 0 ? _UnreadBadge(count: unread) : null,
                                );
                              },
                            ),
                            divider,
                            MenuTile(
                              icon: Icons.settings_rounded,
                              gradient: AppGradients.brand,
                              title: 'App Settings',
                              subtitle: 'Voice, language and theme',
                              onTap: widget.onOpenSettings,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FadeSlideIn(
                      index: 3,
                      child: InfoBanner(
                        icon: Icons.shield_outlined,
                        message: const Text(
                          'Your profile is only visible to you. Only your name can be changed here.',
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    FadeSlideIn(index: 4, child: LogoutButton(busy: _loggingOut, onPressed: _logout)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.gradient,
    required this.label,
    required this.value,
    this.muted = false,
  });

  final IconData icon;
  final Gradient gradient;
  final String label;
  final String value;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          IconBadge(icon: icon, gradient: gradient, size: 42, glow: false),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.labelMedium),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: muted ? theme.colorScheme.onSurfaceVariant : null,
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

/// Shows the profile image if one is set, otherwise (or if it fails to load) a placeholder.
/// A gradient ring frames it and a small pencil badge opens the editor.
class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({required this.profile, required this.photo, required this.onChangePhoto});

  final Profile profile;

  /// The photo chosen on this phone; preferred over [Profile.profileImageUrl].
  final Uint8List? photo;
  final VoidCallback onChangePhoto;

  @override
  Widget build(BuildContext context) {
    final url = profile.profileImageUrl;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(colors: [Colors.white, Color(0xFFD9D4FF)]),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 24, offset: const Offset(0, 10))],
          ),
          child: CircleAvatar(
            radius: 50,
            backgroundColor: const Color(0xFFEDEBFF),
            foregroundColor: AppColors.primary,
            foregroundImage: photo != null
                ? ResizeImage(MemoryImage(photo!), width: 320)
                : (url != null ? NetworkImage(url) : null),
            onForegroundImageError: photo != null || url != null ? (_, _) {} : null,
            child: const Icon(Icons.person, size: 52),
          ),
        ),
        Positioned(
          right: 0,
          bottom: 4,
          child: Material(
            color: AppColors.amber,
            shape: const CircleBorder(side: BorderSide(color: Colors.white, width: 3)),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onChangePhoto,
              child: const Padding(
                padding: EdgeInsets.all(7),
                child: Icon(Icons.photo_camera_rounded, size: 16, color: Colors.white, semanticLabel: 'Change photo'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _EditNameDialog extends StatefulWidget {
  const _EditNameDialog({required this.profileService, required this.initialName});

  final ProfileService profileService;
  final String initialName;

  @override
  State<_EditNameDialog> createState() => _EditNameDialogState();
}

class _EditNameDialogState extends State<_EditNameDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _nameController = TextEditingController(text: widget.initialName);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final profile = await widget.profileService.updateName(_nameController.text);
      if (mounted) Navigator.of(context).pop(profile);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.fieldErrors['name'] ?? e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const IconBadge(icon: Icons.edit_rounded, gradient: AppGradients.profile, size: 52),
      title: const Text('Edit Profile'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _nameController,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Name',
            prefixIcon: const Icon(Icons.person_outline_rounded),
            errorText: _error,
          ),
          textCapitalization: TextCapitalization.words,
          maxLength: ProfileService.maxNameLength,
          textInputAction: TextInputAction.done,
          onFieldSubmitted: (_) => _saving ? null : _save(),
          validator: (v) => (v == null || v.trim().isEmpty) ? 'Name is required' : null,
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }
}

/// The unread-notification count on the Notifications row.
class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Badge(
          label: Text(count > 99 ? '99+' : '$count'),
          backgroundColor: AppColors.coral,
          textColor: Colors.white,
        ),
        const SizedBox(width: 6),
        Icon(Icons.chevron_right_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant),
      ],
    );
  }
}

class _NoUpdates implements Listenable {
  const _NoUpdates();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
