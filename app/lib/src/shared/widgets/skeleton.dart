import 'package:flutter/material.dart';

/// A shimmering placeholder box — the base primitive for skeleton loading
/// states. Composes into per-screen skeleton layouts (see [SkeletonListTile])
/// so a loading screen shows the shape of what's coming instead of a blank
/// spinner, which feels faster even when the wait time is identical.
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height = 14,
    this.borderRadius = 8,
  });

  final double? width;
  final double height;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: width,
        height: height,
        child: const _Shimmer(),
      ),
    );
  }
}

/// One shared shimmer animation ticks every [SkeletonBox]/[_Shimmer] on
/// screen so a list of skeletons sweeps in sync rather than each running its
/// own out-of-phase [AnimationController].
class _Shimmer extends StatefulWidget {
  const _Shimmer();

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.surfaceContainerHighest;
    final highlight = scheme.surfaceContainerHighest.withValues(alpha: 0.4);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) {
            final t = _controller.value;
            return LinearGradient(
              colors: [base, highlight, base],
              stops: const [0.35, 0.5, 0.65],
              begin: Alignment(-1 - t * 2, 0),
              end: Alignment(1 - t * 2, 0),
            ).createShader(bounds);
          },
          child: Container(color: Colors.white),
        );
      },
    );
  }
}

/// A skeleton standing in for a [ListTile]-shaped row (leading circle, two
/// text lines) — the most common list-item shape across the app.
class SkeletonListTile extends StatelessWidget {
  const SkeletonListTile({super.key, this.leadingSize = 44});

  final double leadingSize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          ClipOval(
            child: SizedBox(
              width: leadingSize,
              height: leadingSize,
              child: const _Shimmer(),
            ),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox(width: double.infinity, height: 14),
                SizedBox(height: 8),
                SkeletonBox(width: 120, height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A list of [SkeletonListTile]s, for screens still fetching their first page.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.count = 6, this.padding});

  final int count;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: padding ?? const EdgeInsets.all(16),
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      itemCount: count,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, __) => const SkeletonListTile(),
    );
  }
}

/// A skeleton standing in for a "big number" stat card — `Card > Padding >
/// Column(label, value)`, the shared visual language across the stats,
/// wallet, and store-analytics screens (see e.g. `_StatCard` in
/// `rider_stats_screen.dart`).
class SkeletonStatCard extends StatelessWidget {
  const SkeletonStatCard({super.key});

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SkeletonBox(width: 70, height: 11),
            SizedBox(height: 8),
            SkeletonBox(width: 90, height: 20),
          ],
        ),
      ),
    );
  }
}

/// A 2-column grid of [SkeletonStatCard]s, [rows] deep — the loading state
/// for any screen built from paired stat cards (rider stats, store
/// analytics).
class SkeletonStatGrid extends StatelessWidget {
  const SkeletonStatGrid({super.key, this.rows = 2});
  final int rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < rows; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          const Row(
            children: [
              Expanded(child: SkeletonStatCard()),
              SizedBox(width: 12),
              Expanded(child: SkeletonStatCard()),
            ],
          ),
        ],
      ],
    );
  }
}

/// A skeleton standing in for a card-shaped grid item (image + two lines) —
/// the merchant/item card shape used in marketplace grids.
class SkeletonCard extends StatelessWidget {
  const SkeletonCard({super.key});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(aspectRatio: 16 / 10, child: _Shimmer()),
          Padding(
            padding: EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox(width: double.infinity, height: 13),
                SizedBox(height: 6),
                SkeletonBox(width: 80, height: 11),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
