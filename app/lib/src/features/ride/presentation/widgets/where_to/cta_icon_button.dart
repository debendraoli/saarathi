import 'package:flutter/material.dart';

/// A compact circular icon button flanking the Request button — payment
/// method on the left, driver-request options on the right, Yango-style.
class CtaIconButton extends StatelessWidget {
  const CtaIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: scheme.surfaceContainerHighest,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 52,
            height: 52,
            child: Icon(icon, color: scheme.onSurfaceVariant, size: 22),
          ),
        ),
      ),
    );
  }
}
