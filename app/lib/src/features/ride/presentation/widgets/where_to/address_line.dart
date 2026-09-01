import 'package:flutter/material.dart';

import '../../../../../shared/widgets/skeleton.dart';

/// One line of text inside [CompactAddressCard] — a pickup, a stop, or the
/// destination.
class AddressLine extends StatelessWidget {
  const AddressLine({
    super.key,
    required this.text,
    required this.isPlaceholder,
    required this.onTap,
    this.loading = false,
    this.dim = false,
    this.last = false,
    this.trailing,
  });

  final String text;
  final bool isPlaceholder;
  final VoidCallback onTap;

  /// True while a coordinate dropped in from a Maps link is still being
  /// reverse-geocoded to a human label — shows a shimmer instead of the raw
  /// "27.700, 85.300" the line would otherwise flash.
  final bool loading;

  /// Stop lines render a touch lighter than pickup/destination.
  final bool dim;
  final bool last;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: EdgeInsets.only(bottom: last ? 0 : 8, top: 1),
        child: Row(
          children: [
            Expanded(
              child: loading
                  ? const SkeletonBox(width: 150, height: 14)
                  : Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: isPlaceholder
                          ? TextStyle(color: Theme.of(context).hintColor)
                          : TextStyle(
                              fontWeight:
                                  dim ? FontWeight.w500 : FontWeight.w700,
                              fontSize: 13.5,
                            ),
                    ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}
