import 'package:flutter/material.dart';

class RailButton extends StatelessWidget {
  const RailButton({
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
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon,
              size: 18, color: Theme.of(context).colorScheme.outline),
        ),
      ),
    );
  }
}
