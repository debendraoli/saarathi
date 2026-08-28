import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../../shared/haptics.dart';
import '../../../../shared/widgets/fare_stepper.dart';
import '../../application/ride_controller.dart';
import '../../data/ride_repository.dart';
import '../../domain/models.dart';
import '../trip_screen.dart' show showCancelReasonSheet, RouteSummary, EtaFareRow;
import 'bid_card.dart';

/// Replaces the plain "searching" status sheet while a bid-mode trip is
/// still `requested`: the rider's current ask, a live-sorted bid list, and
/// a manual escalation nudge if nobody's bitten after a while. Bids arrive
/// via `tripBidsProvider`'s 3s poll (the trip's own WS hub also pushes a
/// `bid` frame, but the poll is the source of truth so a missed frame can't
/// leave the list stale).
class BiddingSheet extends ConsumerStatefulWidget {
  const BiddingSheet({super.key, required this.trip});
  final Trip trip;

  @override
  ConsumerState<BiddingSheet> createState() => _BiddingSheetState();
}

class _BiddingSheetState extends ConsumerState<BiddingSheet> {
  static const _nudgeAfter = Duration(seconds: 20);

  Timer? _nudgeTimer;
  bool _showNudge = false;
  bool _raising = false;
  bool _accepting = false;

  @override
  void initState() {
    super.initState();
    _armNudge();
  }

  @override
  void didUpdateWidget(covariant BiddingSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new ask (rider raised it) or a fresh bid should reset the clock —
    // the nudge is about "nothing's happened lately", not a hard deadline.
    if (oldWidget.trip.askFare != widget.trip.askFare) _armNudge();
  }

  void _armNudge() {
    _nudgeTimer?.cancel();
    setState(() => _showNudge = false);
    _nudgeTimer = Timer(_nudgeAfter, () {
      if (mounted) setState(() => _showNudge = true);
    });
  }

  @override
  void dispose() {
    _nudgeTimer?.cancel();
    super.dispose();
  }

  Future<void> _raiseAsk(double amount) async {
    setState(() => _raising = true);
    try {
      await ref.read(rideRepositoryProvider).changeAsk(widget.trip.id, amount);
      Haptics.success();
      _armNudge();
      ref.invalidate(tripStreamProvider(widget.trip.id));
    } catch (_) {
      Haptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).errorNetwork)),
        );
      }
    } finally {
      if (mounted) setState(() => _raising = false);
    }
  }

  Future<void> _acceptBid(Bid bid) async {
    setState(() => _accepting = true);
    try {
      await ref.read(rideRepositoryProvider).acceptBid(widget.trip.id, bid.id);
      Haptics.success();
      ref.invalidate(tripStreamProvider(widget.trip.id));
    } catch (_) {
      Haptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).errorNetwork)),
        );
      }
    } finally {
      if (mounted) setState(() => _accepting = false);
    }
  }

  Future<void> _cancel() => showCancelReasonSheet(
      context, ref, widget.trip.id, false,
      searching: true);

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    // A zero/missing askFare (a bad draft, or a promo that zeroed it out)
    // would otherwise make `min == max == 0` below, permanently disabling
    // both stepper buttons with no way for the rider to raise their offer
    // and no explanation why. Floor it to a value the stepper can actually
    // work with.
    final rawAsk = widget.trip.askFare ?? 0;
    final ask = rawAsk > 0 ? rawAsk : 100.0;
    final bids =
        ref.watch(tripBidsProvider(widget.trip.id)).value ?? const [];
    final originLabelAsync = ref.watch(tripOriginLabelProvider(widget.trip.id));
    final destLabelAsync = ref.watch(tripDestLabelProvider(widget.trip.id));
    // Any live bid quiets the nudge — it's only for a genuinely dead auction.
    if (bids.isNotEmpty && _showNudge) _showNudge = false;

    return DraggableScrollableSheet(
      initialChildSize: 0.42,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      snap: true,
      snapSizes: const [0.3, 0.42, 0.85],
      builder: (context, scrollController) {
        return Material(
          color: scheme.surface,
          elevation: 8,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: ListView(
            controller: scrollController,
            padding: EdgeInsets.fromLTRB(
                18, 10, 18, 18 + MediaQuery.of(context).padding.bottom),
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                l.findingDriver,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 14),
              RouteSummary(pickup: originLabelAsync, dest: destLabelAsync),
              const SizedBox(height: 10),
              EtaFareRow(
                trip: widget.trip,
                driverLoc: null,
                showFare: false,
              ),
              const SizedBox(height: 16),
              FareStepper(
                amount: ask,
                min: ask,
                max: ask * 3,
                // Every tap raises the ask immediately — no separate
                // "update" step. Drivers already invited get re-notified
                // on the next dispatch pass within seconds.
                onChanged: _raiseAsk,
                caption: l.yourOffer,
              ),
              if (_raising) ...[
                const SizedBox(height: 8),
                Center(
                  child: SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
              if (_showNudge && bids.isEmpty) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.trending_up_rounded,
                          color: scheme.onErrorContainer),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          l.noBidsYetRaiseTo((ask + 10).toStringAsFixed(0)),
                          style: TextStyle(color: scheme.onErrorContainer),
                        ),
                      ),
                      TextButton(
                        onPressed: _raising ? null : () => _raiseAsk(ask + 10),
                        child: Text(l.raise),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (bids.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: Text(
                      l.findingDriverBody,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                )
              else
                for (final bid in bids)
                  BidCard(
                    bid: bid,
                    busy: _accepting,
                    onAccept: () => _acceptBid(bid),
                  ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _cancel,
                child: Text(l.cancelRide),
              ),
            ],
          ),
        );
      },
    );
  }
}
