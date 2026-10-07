import 'package:flutter/material.dart';

import '../../../core/widgets/widgets.dart';
import '../services/automatic_location_tracking_service.dart';

/// How Automatic Location History's real state is described everywhere in the app. "Tracking
/// active" is only ever shown while places are actually being collected.
({String label, String? detail, IconData icon, Color color}) describeTracking(AutomaticLocationTrackingService service) {
  final status = service.status;
  if (service.busy && status != AutomaticTrackingStatus.active) {
    return (label: 'Checking...', detail: null, icon: Icons.hourglass_top_rounded, color: AppColors.inkMuted);
  }
  return switch (status) {
    AutomaticTrackingStatus.off => (
      label: 'Tracking off',
      detail: null,
      icon: Icons.location_disabled_rounded,
      color: AppColors.inkMuted,
    ),
    AutomaticTrackingStatus.starting => (
      label: 'Starting...',
      detail: null,
      icon: Icons.hourglass_top_rounded,
      color: AppColors.sky,
    ),
    AutomaticTrackingStatus.active => (
      label: 'Tracking active',
      detail: 'Significant places you visit are being saved.',
      icon: Icons.radar_rounded,
      color: AppColors.success,
    ),
    AutomaticTrackingStatus.paused => (
      label: 'Paused',
      detail: 'Location services are turned off on this device.',
      icon: Icons.pause_circle_outline_rounded,
      color: AppColors.warning,
    ),
    AutomaticTrackingStatus.permissionRequired => (
      label: 'Paused',
      detail: 'Automatic location history is paused because location permission needs attention.',
      icon: Icons.error_outline_rounded,
      color: AppColors.warning,
    ),
    AutomaticTrackingStatus.error => (
      label: service.issue == TrackingIssue.unsupported ? 'Not available' : 'Not tracking',
      detail: service.issue == TrackingIssue.unsupported
          ? 'Automatic location history is not available on this device.'
          : 'Automatic location history could not start. Try switching it off and on again.',
      icon: Icons.error_outline_rounded,
      color: AppColors.danger,
    ),
  };
}

/// The small Dashboard card: "Automatic Location History · Tracking active". Opens Location.
class AutomaticTrackingStatusCard extends StatelessWidget {
  const AutomaticTrackingStatusCard({super.key, required this.service, required this.onTap});

  final AutomaticLocationTrackingService service;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final state = describeTracking(service);
        return AppCard(
          key: const ValueKey('dashboard-tracking-card'),
          onTap: onTap,
          child: Row(
            children: [
              const IconBadge(icon: Icons.route_rounded, gradient: AppGradients.location, size: 44),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Automatic Location History', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(state.icon, size: 15, color: state.color),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            state.label,
                            key: const ValueKey('dashboard-tracking-status'),
                            style: theme.textTheme.bodySmall?.copyWith(color: state.color, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        );
      },
    );
  }
}
