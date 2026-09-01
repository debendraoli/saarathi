import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../shared/haptics.dart';
import '../../../../../shared/widgets/swipe_to_confirm.dart';
import '../../../application/ride_controller.dart';

/// The driver's forward trip-progression control (arrived → start → complete).
/// Owns its own busy/error handling — unlike a plain inline `SwipeToConfirm`,
/// a failed request here must not leave the thumb stuck showing "confirmed"
/// with no feedback, since it's real money/obligation on the line.
class DriverNextSwipe extends ConsumerStatefulWidget {
  const DriverNextSwipe({super.key, required this.tripId, required this.next});
  final String tripId;
  final (String, String) next;

  @override
  ConsumerState<DriverNextSwipe> createState() => _DriverNextSwipeState();
}

class _DriverNextSwipeState extends ConsumerState<DriverNextSwipe> {
  bool _busy = false;

  /// Applies the status change optimistically and hands the actual `POST`
  /// off to [TripStatusUpdater], which keeps retrying independently of
  /// this widget's own lifetime — this swipe control is very likely to be
  /// unmounted the instant the optimistic status takes effect (advancing
  /// past `inProgress` means there's no more "next" swipe to show at all),
  /// so nothing here can afford to own the retry itself. The brief
  /// `busy: true → false` flip isn't gating on the network at all anymore —
  /// it purely exists to replay `SwipeToConfirm`'s own confirmed→ready reset
  /// (see its `didUpdateWidget`) across two real frames, so the thumb is
  /// clean and ready in case this exact widget somehow gets a *different*
  /// `next` transition to show before the trip poll catches up.
  Future<void> _confirm() async {
    try {
      ref.read(tripStatusUpdaterProvider(widget.tripId)).update(widget.next.$1);
      Haptics.success();
    } catch (_) {
      // Fall through regardless — the busy-cycle below is what resets
      // SwipeToConfirm's own `_confirmed` flag (see its didUpdateWidget).
      // Skipping it on an exception here would leave the thumb visually
      // locked in "confirmed" forever with no way to retry, confirmed live
      // as a stuck "I've arrived" swipe.
    }
    if (mounted) setState(() => _busy = true);
    await Future<void>.delayed(Duration.zero);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      // Previously stretched to the sheet's full width (minus its 18px
      // margins) — on a typical phone that's most of the screen, both
      // reading as visually oversized and requiring a swipe long enough
      // that it was easy to under-drag past the commit threshold and land
      // right back at the start, confirmed live as feeling "stuck".
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: SwipeToConfirm(
          label: widget.next.$2,
          busy: _busy,
          onConfirmed: _confirm,
          // Green — reads as "go/forward" opposite the cancel button's red,
          // instead of both actions sharing the same brand-amber look.
          color: Colors.green.shade600,
        ),
      ),
    );
  }
}
