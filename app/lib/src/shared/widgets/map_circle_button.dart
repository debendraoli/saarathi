import 'package:flutter/material.dart';

/// A floating circular icon button meant to sit over a map (back, recenter,
/// fullscreen-nav handoff, ...) — consistent size/elevation/shape across
/// every screen that needs one.
class MapCircleButton extends StatelessWidget {
  const MapCircleButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.iconColor,
  });
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  /// Overrides the icon's default color — e.g. Google's own blue for the
  /// external-navigation handoff button, so it reads at a glance as "leaves
  /// the app" rather than blending in with every other map control.
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: const CircleBorder(),
      elevation: 2,
      child: IconButton(
        icon: Icon(icon, color: iconColor),
        tooltip: tooltip,
        onPressed: onTap,
      ),
    );
  }
}
