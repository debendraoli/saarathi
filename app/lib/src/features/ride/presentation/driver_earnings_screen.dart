import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/skeleton.dart';
import '../application/ride_controller.dart';
import '../domain/models.dart';

/// A driver's own earnings — day/week/month toggle, current-period total
/// with a trend indicator against the previous period, and a compact
/// recent-history bar list. Backed by `GET /v1/rides/driver/earnings`,
/// which already returns gap-filled buckets (a zero-trip day/week/month
/// still shows as NPR 0, not missing).
class DriverEarningsScreen extends ConsumerStatefulWidget {
  const DriverEarningsScreen({super.key});

  @override
  ConsumerState<DriverEarningsScreen> createState() =>
      _DriverEarningsScreenState();
}

class _DriverEarningsScreenState extends ConsumerState<DriverEarningsScreen> {
  String _period = 'day';

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final async = ref.watch(driverEarningsProvider(_period));

    return Scaffold(
      appBar: AppBar(title: Text(l.driverEarningsTitle)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'day', label: Text(l.periodDay)),
                ButtonSegment(value: 'week', label: Text(l.periodWeek)),
                ButtonSegment(value: 'month', label: Text(l.periodMonth)),
              ],
              selected: {_period},
              onSelectionChanged: (s) => setState(() => _period = s.first),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: async.when(
                loading: () => const SkeletonList(),
                error: (_, __) => ErrorRetry(
                  message: l.errorNetwork,
                  onRetry: () =>
                      ref.invalidate(driverEarningsProvider(_period)),
                ),
                data: (earnings) => RefreshIndicator(
                  onRefresh: () async =>
                      ref.invalidate(driverEarningsProvider(_period)),
                  child: _EarningsBody(earnings: earnings),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EarningsBody extends StatelessWidget {
  const _EarningsBody({required this.earnings});
  final DriverEarnings earnings;

  String _periodLabel(AppL10n l) => switch (earnings.period) {
        'week' => l.driverEarningsThisWeek,
        'month' => l.driverEarningsThisMonth,
        _ => l.driverEarningsToday,
      };

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final theme = Theme.of(context);
    final current = earnings.current;
    final change = earnings.changePct;
    final maxTotal = earnings.buckets
        .fold<double>(0, (m, b) => b.total > m ? b.total : m);

    return ListView(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_periodLabel(l), style: theme.textTheme.bodyMedium),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      'NPR ${(current?.total ?? 0).toStringAsFixed(0)}',
                      style: theme.textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    if (change != null) ...[
                      const SizedBox(width: 12),
                      _TrendChip(changePct: change),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  l.driverEarningsTrips(current?.trips ?? 0),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(l.driverEarningsHistory,
            style: theme.textTheme.labelLarge
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              children: [
                for (final b in earnings.buckets)
                  _EarningsBar(
                    bucket: b,
                    period: earnings.period,
                    maxTotal: maxTotal,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TrendChip extends StatelessWidget {
  const _TrendChip({required this.changePct});
  final double changePct;

  @override
  Widget build(BuildContext context) {
    final up = changePct >= 0;
    final color = up ? Colors.green : Colors.red;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 2),
          Text(
            '${changePct.abs().toStringAsFixed(0)}%',
            style: TextStyle(
                color: color, fontWeight: FontWeight.w700, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _EarningsBar extends StatelessWidget {
  const _EarningsBar({
    required this.bucket,
    required this.period,
    required this.maxTotal,
  });
  final EarningsBucket bucket;
  final String period;
  final double maxTotal;

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  String get _label {
    final d = bucket.start;
    return switch (period) {
      'week' => '${_months[d.month - 1]} ${d.day}',
      'month' => _months[d.month - 1],
      _ => '${_weekdays[d.weekday - 1]} ${d.day}',
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fraction = maxTotal == 0 ? 0.0 : bucket.total / maxTotal;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Text(_label, style: Theme.of(context).textTheme.bodySmall),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 8,
                backgroundColor: scheme.surfaceContainerHighest,
                color: scheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 68,
            child: Text(
              'NPR ${bucket.total.toStringAsFixed(0)}',
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
