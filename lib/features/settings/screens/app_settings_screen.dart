import 'package:flutter/material.dart';

import '../../../core/navigation/app_menu.dart';
import '../../../core/widgets/widgets.dart';
import '../../chat/services/text_to_speech_service.dart';

/// App-wide preferences: voice replies, language, theme, about and logout.
class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({
    super.key,
    required this.textToSpeech,
    required this.themeMode,
    required this.onLogout,
    this.onOpenNotificationSettings,
    this.onOpenVoiceAssistant,
  });

  /// Holds the "Voice replies" choice shared with Chat.
  final TextToSpeechService textToSpeech;
  final ValueNotifier<ThemeMode> themeMode;
  final Future<void> Function() onLogout;

  /// Opens Notification settings (which kinds of notifications the account receives).
  final VoidCallback? onOpenNotificationSettings;

  /// Opens Voice Assistant (the "Hey Child" wake word).
  final VoidCallback? onOpenVoiceAssistant;

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  bool _loggingOut = false;

  static String _themeLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.system => 'Same as device',
    ThemeMode.light => 'Light',
    ThemeMode.dark => 'Dark',
  };

  Future<void> _chooseTheme() async {
    final current = widget.themeMode.value;
    final chosen = await showDialog<ThemeMode>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Theme'),
        children: [
          for (final mode in ThemeMode.values)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(mode),
              child: Row(
                children: [
                  Expanded(child: Text(_themeLabel(mode))),
                  if (mode == current) Icon(Icons.check_rounded, color: Theme.of(dialogContext).colorScheme.primary),
                ],
              ),
            ),
        ],
      ),
    );
    if (chosen != null) widget.themeMode.value = chosen;
  }

  Future<void> _logout() async {
    setState(() => _loggingOut = true);
    // AuthService clears the token and notifies listeners; the app closes this screen and shows Login.
    await widget.onLogout();
  }

  @override
  Widget build(BuildContext context) {
    final tts = widget.textToSpeech;
    final divider = Divider(height: 1, indent: 72, endIndent: 16, color: Theme.of(context).colorScheme.outlineVariant);
    return Scaffold(
      appBar: AppBar(flexibleSpace: const AppBarGradient(), title: const Text('App Settings'),
        actions: const [AppMenuButton(current: AppDestination.settings)],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
              children: [
                const SectionTitle('Chat'),
                const SizedBox(height: 10),
                FadeSlideIn(
                  child: AppCard(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      children: [
                        ListenableBuilder(
                          listenable: tts,
                          builder: (context, _) => MenuTile(
                            icon: Icons.record_voice_over_rounded,
                            gradient: AppGradients.microphone,
                            title: 'Voice Replies',
                            subtitle: tts.isAvailable
                                ? 'Read Child Assist\'s replies aloud'
                                : 'Not available on this device',
                            onTap: tts.isAvailable ? () => tts.repliesEnabled = !tts.repliesEnabled : null,
                            trailing: Switch(
                              value: tts.isAvailable && tts.repliesEnabled,
                              onChanged: tts.isAvailable ? (on) => tts.repliesEnabled = on : null,
                            ),
                          ),
                        ),
                        if (widget.onOpenVoiceAssistant != null) ...[
                          divider,
                          MenuTile(
                            icon: Icons.settings_voice_rounded,
                            gradient: AppGradients.brand,
                            title: 'Voice Assistant',
                            subtitle: 'Wake Word: say “Hey Child” hands-free',
                            onTap: widget.onOpenVoiceAssistant,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                const SectionTitle('General'),
                const SizedBox(height: 10),
                FadeSlideIn(
                  index: 1,
                  child: AppCard(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      children: [
                        // English is the only language the app supports today.
                        const MenuTile(
                          icon: Icons.translate_rounded,
                          gradient: AppGradients.location,
                          title: 'Language',
                          subtitle: 'English',
                        ),
                        divider,
                        ValueListenableBuilder(
                          valueListenable: widget.themeMode,
                          builder: (context, mode, _) => MenuTile(
                            icon: Icons.dark_mode_rounded,
                            gradient: AppGradients.brand,
                            title: 'Theme',
                            subtitle: _themeLabel(mode),
                            onTap: _chooseTheme,
                          ),
                        ),
                        if (widget.onOpenNotificationSettings != null) ...[
                          divider,
                          MenuTile(
                            icon: Icons.notifications_active_rounded,
                            gradient: AppGradients.notifications,
                            title: 'Notification settings',
                            subtitle: 'Choose what Child Assist notifies you about',
                            onTap: widget.onOpenNotificationSettings,
                          ),
                        ],
                        divider,
                        MenuTile(
                          icon: Icons.info_outline_rounded,
                          gradient: AppGradients.profile,
                          title: 'About',
                          subtitle: 'About Child Assist',
                          onTap: () => showAboutDialog(
                            context: context,
                            applicationName: 'Child Assist',
                            applicationIcon: const AppLogo(size: 48),
                            applicationLegalese: 'Your friendly personal assistant. '
                                'You decide what Child Assist can use.',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                FadeSlideIn(index: 2, child: LogoutButton(busy: _loggingOut, onPressed: _logout)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
