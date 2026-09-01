import 'package:flutter/material.dart';

import '../../../../../shared/widgets/skeleton.dart';

class FareStepperSkeleton extends StatelessWidget {
  const FareStepperSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _StepButtonSkeleton(scheme: scheme),
        const SizedBox(width: 8),
        const SkeletonBox(width: 100, height: 32, borderRadius: 999),
        const SizedBox(width: 8),
        _StepButtonSkeleton(scheme: scheme),
      ],
    );
  }
}

class _StepButtonSkeleton extends StatelessWidget {
  const _StepButtonSkeleton({required this.scheme});
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
    );
  }
}
