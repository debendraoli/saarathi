import 'package:flutter/material.dart';

import '../haptics.dart';

/// A slide-to-confirm control for committing actions (accepting an offer,
/// advancing a trip/order) — deliberately harder to trigger by accident than
/// a plain button, since each of these commits real money or a real
/// obligation on a single tap. Destructive actions (decline/reject/cancel)
/// intentionally do NOT use this: they keep tap + confirm-dialog, since that
/// friction is interruptible and a swipe's isn't — see plan §5.
class SwipeToConfirm extends StatefulWidget {
  const SwipeToConfirm({
    super.key,
    required this.label,
    required this.onConfirmed,
    this.busy = false,
    this.icon = Icons.chevron_right_rounded,
    this.color,
  });

  final String label;
  final VoidCallback onConfirmed;
  final bool busy;
  final IconData icon;

  /// Track fill / thumb color — defaults to the theme's primary (brand
  /// amber). Callers whose action reads as "the positive/forward one" next
  /// to a red cancel button (e.g. the driver's arrived/start/complete swipe)
  /// pass a green here so the two read as a pair at a glance.
  final Color? color;

  @override
  State<SwipeToConfirm> createState() => _SwipeToConfirmState();
}

class _SwipeToConfirmState extends State<SwipeToConfirm>
    with SingleTickerProviderStateMixin {
  static const _thumbSize = 52.0;
  static const _commitThreshold = 0.8;

  double _drag = 0; // 0..1, fraction of the travel distance
  bool _dragging = false;
  bool _crossedThreshold = false;
  bool _confirmed = false;

  /// A gentle, repeating nudge-right-and-back on the thumb — the swipe
  /// affordance (a plain circle sitting at the left edge) otherwise reads as
  /// a static button, not something draggable. Runs continuously while
  /// idle; stops the moment a real drag starts or the action confirms, so
  /// it never fights the actual gesture-driven position.
  late final AnimationController _hintAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);
  late final Animation<double> _hintCurve =
      CurvedAnimation(parent: _hintAnim, curve: Curves.easeInOut);

  @override
  void dispose() {
    _hintAnim.dispose();
    super.dispose();
  }

  void _onDragUpdate(double delta, double travel) {
    if (widget.busy || _confirmed || travel <= 0) return;
    setState(() {
      _dragging = true;
      _drag = (_drag + delta / travel).clamp(0.0, 1.0);
    });
    final crossed = _drag >= _commitThreshold;
    if (crossed && !_crossedThreshold) Haptics.tap();
    _crossedThreshold = crossed;
  }

  void _onDragEnd() {
    if (widget.busy || _confirmed) return;
    if (_drag >= _commitThreshold) {
      setState(() {
        _confirmed = true;
        _drag = 1;
        _dragging = false;
      });
      Haptics.success();
      widget.onConfirmed();
    } else {
      setState(() {
        _dragging = false;
        _drag = 0;
      });
      _crossedThreshold = false;
    }
  }

  @override
  void didUpdateWidget(covariant SwipeToConfirm oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A caller that resets `busy` after a failed attempt should get its
    // thumb back, not a permanently-stuck "confirmed" control.
    if (!widget.busy && oldWidget.busy && !_dragging) {
      _confirmed = false;
      _drag = 0;
      _crossedThreshold = false;
    }
    // A changed label means this control now represents a genuinely
    // different action than whatever was just confirmed (e.g. the trip
    // status moved on and the caller is now offering "Start trip" instead
    // of "I've arrived") — reset unconditionally rather than relying only
    // on the caller's own busy-flip timing, which a caller driving this
    // optimistically (status applied locally before the request that makes
    // it real even resolves) can't always guarantee lines up with this
    // widget's own rebuild — confirmed live as a swipe staying stuck on
    // its previous action's checkmark, label hidden, refusing all further
    // input, even though the underlying transition had already succeeded.
    if (widget.label != oldWidget.label && !_dragging) {
      _confirmed = false;
      _drag = 0;
      _crossedThreshold = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = widget.color ?? scheme.primary;
    final onColor = widget.color != null ? Colors.white : scheme.onPrimary;
    final hintActive = !_dragging && !_confirmed && !widget.busy;
    return LayoutBuilder(
      builder: (context, constraints) {
        final trackWidth = constraints.maxWidth;
        final travel =
            (trackWidth - _thumbSize - 8).clamp(1.0, double.infinity);
        final thumbLeft = 4 + _drag * travel;
        final fillWidth = thumbLeft + _thumbSize / 2;

        return SizedBox(
          height: 56,
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              // Track.
              Container(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(28),
                ),
              ),
              // Fill, growing with drag progress.
              AnimatedContainer(
                duration: _dragging
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                width: fillWidth.clamp(_thumbSize, trackWidth),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: _confirmed ? 1 : 0.85),
                  borderRadius: BorderRadius.circular(28),
                ),
              ),
              // Label, fades as the thumb covers it.
              Positioned.fill(
                child: Center(
                  child: Opacity(
                    opacity: (1 - _drag * 1.4).clamp(0.0, 1.0),
                    child: Text(
                      widget.label,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              // Thumb.
              AnimatedPositioned(
                duration: _dragging
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                left: thumbLeft,
                top: 4,
                child: GestureDetector(
                  onHorizontalDragUpdate: widget.busy
                      ? null
                      : (d) => _onDragUpdate(d.delta.dx, travel),
                  onHorizontalDragEnd: widget.busy ? null : (_) => _onDragEnd(),
                  child: AnimatedBuilder(
                    animation: _hintCurve,
                    // Additive to the drag-driven `left` above, not a
                    // replacement for it — a plain Positioned/Transform
                    // layered on top so the two never fight: the moment a
                    // real drag starts, `hintActive` goes false and this
                    // collapses back to zero offset.
                    builder: (context, child) => Transform.translate(
                      offset: Offset(hintActive ? _hintCurve.value * 12 : 0, 0),
                      child: child,
                    ),
                    child: Container(
                      width: _thumbSize,
                      height: _thumbSize,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.2),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Center(
                        child: widget.busy
                            ? SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                  color: onColor,
                                ),
                              )
                            : Icon(
                                _confirmed ? Icons.check_rounded : widget.icon,
                                color: onColor,
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
