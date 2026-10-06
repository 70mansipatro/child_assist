import 'package:flutter/material.dart';

import '../../../core/permissions/permission_service.dart';

/// One screen of the first-time permission walkthrough: what is asked for and why.
class PermissionOnboardingStep {
  const PermissionOnboardingStep({
    required this.permission,
    required this.title,
    required this.description,
    required this.icon,
  });

  final AppPermission permission;
  final String title;
  final String description;
  final IconData icon;
}

/// The walkthrough, in the order it is shown. Documents is not here: it is a file picker,
/// not a runtime permission.
const List<PermissionOnboardingStep> permissionOnboardingSteps = [
  PermissionOnboardingStep(
    permission: AppPermission.location,
    title: 'Location Access',
    description:
        'Child Assist can use your location to help you remember places you visited.\n\n'
        'Location access is used only when needed.',
    icon: Icons.location_on_outlined,
  ),
  PermissionOnboardingStep(
    permission: AppPermission.camera,
    title: 'Camera Access',
    description:
        'Child Assist can use your camera when you choose to take photos or use camera features.',
    icon: Icons.photo_camera_outlined,
  ),
  PermissionOnboardingStep(
    permission: AppPermission.microphone,
    title: 'Microphone Access',
    description: 'Child Assist can use your microphone when you choose voice features.',
    icon: Icons.mic_none,
  ),
  PermissionOnboardingStep(
    permission: AppPermission.photos,
    title: 'Photos Access',
    description: 'Child Assist can access photos you allow when you choose photo features.',
    icon: Icons.photo_library_outlined,
  ),
  PermissionOnboardingStep(
    permission: AppPermission.notifications,
    title: 'Notifications',
    description: 'Allow Child Assist to send you useful notifications and reminders.',
    icon: Icons.notifications_none,
  ),
];
