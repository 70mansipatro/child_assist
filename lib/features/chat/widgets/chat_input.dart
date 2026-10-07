import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';
import '../services/voice_chat_controller.dart';

/// Message box with Send and a tap-to-talk microphone button. The microphone only calls
/// [onMicrophone]; permission checks and listening are handled by the voice controller.
class ChatInput extends StatefulWidget {
  const ChatInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.onMicrophone,
    this.enabled = true,
    this.voiceState = VoiceState.idle,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSend;
  final VoidCallback onMicrophone;

  /// False while a reply is on its way; typing is still allowed, sending and talking are not.
  final bool enabled;

  /// Drives the microphone button: idle, listening (tap to stop) or busy.
  final VoiceState voiceState;

  /// Matches the server's limit, so a message is never rejected after typing it.
  static const maxLength = 4000;

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(ChatInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  bool get _listening => widget.voiceState == VoiceState.listening;

  bool get _canSend => widget.enabled && !_listening && widget.controller.text.trim().isNotEmpty;

  void _send() {
    if (!_canSend) return;
    final text = widget.controller.text;
    widget.controller.clear();
    widget.onSend(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.2),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _MicrophoneButton(
                state: widget.voiceState,
                enabled: widget.enabled,
                onPressed: widget.onMicrophone,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: widget.focusNode,
                  minLines: 1,
                  maxLines: 5,
                  maxLength: ChatInput.maxLength,
                  textCapitalization: TextCapitalization.sentences,
                  keyboardType: TextInputType.multiline,
                  decoration: const InputDecoration(
                    hintText: 'Ask Child Assist...',
                    counterText: '',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              PressableScale(
                enabled: _canSend,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: _canSend ? AppGradients.brand : null,
                    color: _canSend ? null : theme.disabledColor.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    tooltip: 'Send',
                    onPressed: _canSend ? _send : null,
                    icon: Icon(Icons.arrow_upward_rounded, color: _canSend ? Colors.white : theme.disabledColor),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Idle: an outlined microphone. Listening: a filled, pulsing stop button so recording is
/// always obvious. Waiting for permission or the transcript: a small spinner.
class _MicrophoneButton extends StatelessWidget {
  const _MicrophoneButton({required this.state, required this.enabled, required this.onPressed});

  final VoiceState state;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    switch (state) {
      case VoiceState.requestingPermission || VoiceState.processing:
        return const SizedBox.square(
          dimension: 48,
          child: Center(child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2.4))),
        );
      case VoiceState.listening:
        final button = Container(
          decoration: const BoxDecoration(gradient: AppGradients.brand, shape: BoxShape.circle),
          child: IconButton(
            tooltip: 'Stop listening',
            onPressed: onPressed,
            icon: const Icon(Icons.stop_rounded, color: Colors.white),
          ),
        );
        if (MediaQuery.disableAnimationsOf(context)) return button;
        return SizedBox.square(
          dimension: 48,
          child: OverflowBox(
            maxWidth: 72,
            maxHeight: 72,
            child: PulseHalo(color: theme.colorScheme.primary, size: 72, child: button),
          ),
        );
      case VoiceState.idle || VoiceState.speaking || VoiceState.error:
        return IconButton(
          tooltip: 'Voice input',
          onPressed: enabled ? onPressed : null,
          icon: const Icon(Icons.mic_none_rounded),
        );
    }
  }
}
