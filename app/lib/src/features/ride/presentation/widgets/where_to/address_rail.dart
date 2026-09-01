import 'package:flutter/material.dart';

/// The dot → (stop dots) → flag rail beside the address lines, sized to
/// match however many lines [CompactAddressCard] is currently rendering.
class AddressRail extends StatelessWidget {
  const AddressRail({super.key, required this.scheme, required this.stopCount});
  final ColorScheme scheme;
  final int stopCount;

  @override
  Widget build(BuildContext context) {
    Widget dot(Color color, {bool square = false}) => Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: square ? BoxShape.rectangle : BoxShape.circle,
            borderRadius: square ? BorderRadius.circular(2) : null,
          ),
        );
    Widget line() => Container(
          width: 1.5,
          height: 16,
          margin: const EdgeInsets.symmetric(vertical: 3),
          color: scheme.outlineVariant,
        );
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          dot(scheme.primary),
          for (var i = 0; i < stopCount; i++) ...[
            line(),
            dot(scheme.tertiary),
          ],
          line(),
          dot(scheme.secondary, square: true),
        ],
      ),
    );
  }
}
