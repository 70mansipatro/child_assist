import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';
import '../models/chat_message.dart';

/// What Child Assist is doing, in plain words. Internal tool names are never shown.
String toolProgressText(ChatToolKind kind) => switch (kind) {
      ChatToolKind.locationHistory => 'Checking your location history...',
      ChatToolKind.currentLocation => 'Checking your location...',
      ChatToolKind.documents => 'Searching your documents...',
      ChatToolKind.documentText => 'Reading your document...',
      ChatToolKind.photos => 'Finding your photo...',
      ChatToolKind.photoAnalysis => 'Analyzing image...',
      ChatToolKind.photoShare => 'Preparing to share your photo...',
      ChatToolKind.permissions => 'Checking permissions...',
      ChatToolKind.profile => 'Checking your profile...',
      ChatToolKind.webSearch => 'Searching the web...',
      ChatToolKind.contacts => 'Looking up your contacts...',
      ChatToolKind.sendAction => 'Preparing your request...',
      ChatToolKind.unknown => 'Working on it...',
    };

/// The same step once it has finished.
String toolDoneText(ChatToolKind kind) => switch (kind) {
      ChatToolKind.locationHistory => 'Checked your location history',
      ChatToolKind.currentLocation => 'Checked your location',
      ChatToolKind.documents => 'Searched your documents',
      ChatToolKind.documentText => 'Read your document',
      ChatToolKind.photos => 'Checked your photos',
      ChatToolKind.photoAnalysis => 'Looked at your photo',
      ChatToolKind.photoShare => 'Prepared to share your photo',
      ChatToolKind.permissions => 'Checked permissions',
      ChatToolKind.profile => 'Checked your profile',
      ChatToolKind.webSearch => 'Searched the web',
      ChatToolKind.contacts => 'Looked up your contacts',
      ChatToolKind.sendAction => 'Prepared your request',
      ChatToolKind.unknown => 'Done',
    };

IconData toolIcon(ChatToolKind kind) => switch (kind) {
      ChatToolKind.locationHistory || ChatToolKind.currentLocation => Icons.location_on_rounded,
      ChatToolKind.documents || ChatToolKind.documentText => Icons.description_rounded,
      ChatToolKind.photos || ChatToolKind.photoShare => Icons.photo_library_rounded,
      ChatToolKind.photoAnalysis => Icons.image_search_rounded,
      ChatToolKind.permissions => Icons.verified_user_rounded,
      ChatToolKind.profile => Icons.person_rounded,
      ChatToolKind.webSearch => Icons.travel_explore_rounded,
      ChatToolKind.contacts => Icons.contacts_rounded,
      ChatToolKind.sendAction => Icons.send_rounded,
      ChatToolKind.unknown => Icons.auto_awesome_rounded,
    };

/// A small chip saying which of the user's information Child Assist looked at.
class ToolStatusCard extends StatelessWidget {
  const ToolStatusCard({super.key, required this.kind, this.inProgress = false});

  final ChatToolKind kind;
  final bool inProgress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: theme.brightness == Brightness.dark ? 0.18 : 0.08),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          inProgress
              ? ButtonSpinner(size: 12, color: color)
              : Icon(toolIcon(kind), size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              inProgress ? toolProgressText(kind) : toolDoneText(kind),
              style: theme.textTheme.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
