import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/widgets/widgets.dart';
import '../models/profile.dart';
import '../services/profile_service.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.profileService});

  final ProfileService profileService;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Profile? _profile;
  String? _error;
  bool _loading = true;

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

  @override
  Widget build(BuildContext context) {
    final hasProfile = _profile != null;
    return Scaffold(
      extendBodyBehindAppBar: hasProfile,
      appBar: AppBar(
        title: const Text('Profile'),
        foregroundColor: hasProfile ? Colors.white : null,
        titleTextStyle: hasProfile
            ? Theme.of(context).appBarTheme.titleTextStyle?.copyWith(color: Colors.white)
            : null,
      ),
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
        ),
      );
    }

    final theme = Theme.of(context);
    final hasName = profile.name?.isNotEmpty == true;
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        HeroHeader(
          gradient: AppGradients.hero,
          padding: EdgeInsets.fromLTRB(24, MediaQuery.paddingOf(context).top + kToolbarHeight + 8, 24, 64),
          child: Column(
            children: [
              PopIn(child: _ProfileAvatar(profile: profile, onEdit: _editProfile)),
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
                      child: GradientButton(
                        onPressed: _editProfile,
                        icon: const Icon(Icons.edit_rounded, size: 20),
                        label: const Text('Edit Profile'),
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
  const _ProfileAvatar({required this.profile, required this.onEdit});

  final Profile profile;
  final VoidCallback onEdit;

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
            foregroundImage: url != null ? NetworkImage(url) : null,
            onForegroundImageError: url != null ? (_, _) {} : null,
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
              onTap: onEdit,
              child: const Padding(
                padding: EdgeInsets.all(7),
                child: Icon(Icons.edit_rounded, size: 16, color: Colors.white, semanticLabel: 'Edit name'),
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
