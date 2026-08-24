import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../data/ride_repository.dart';
import 'map_view.dart';

/// Drives a "radar" map animation centered on [origin]: polls approximate
/// nearby-driver positions and gives them a small continuous organic wander
/// (so they read as "moving around" between polls, not just snapping every
/// few seconds), plus concentric rings pulsing outward from [origin] like a
/// radar ping. Purely cosmetic — these aren't real-time driver positions,
/// just a sense that the search radius is active.
///
/// Builder-based so each screen decides what else to draw: the rider's
/// "finding you a driver" screen renders the wandering pins as nearby
/// drivers over the pickup point; the driver's own idle map ignores the
/// pins entirely and instead marks the driver's own position at the center.
class SearchRadar extends ConsumerStatefulWidget {
  const SearchRadar({super.key, required this.origin, required this.builder});

  final LatLng origin;
  final Widget Function(
    BuildContext context,
    List<LatLng> driverPins,
    List<MapCircle> circles,
  ) builder;

  @override
  ConsumerState<SearchRadar> createState() => _SearchRadarState();
}

class _SearchRadarState extends ConsumerState<SearchRadar>
    with SingleTickerProviderStateMixin {
  static const _radiusKm = 2.5;
  static const _wanderDeg = 0.0009; // ~90m wander radius at this latitude
  static const _ringCount = 3;

  late final AnimationController _ticker;
  Timer? _poll;
  List<LatLng> _base = const [];

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
    _fetch();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _fetch());
  }

  Future<void> _fetch() async {
    try {
      final pts = await ref
          .read(rideRepositoryProvider)
          .nearbyDrivers(widget.origin, radiusKm: _radiusKm);
      if (mounted) setState(() => _base = pts);
    } catch (_) {/* keep the last known positions */}
  }

  @override
  void dispose() {
    _ticker.dispose();
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _ticker,
      builder: (context, _) {
        final t = _ticker.value * 2 * math.pi;
        final driverPins = [
          for (var i = 0; i < _base.length; i++)
            LatLng(
              _base[i].latitude + _wanderDeg * math.cos(t + i * 2.4),
              _base[i].longitude + _wanderDeg * math.sin(t + i * 2.4),
            ),
        ];
        final circles = [
          for (var ring = 0; ring < _ringCount; ring++)
            _pulseRing(scheme, ring),
        ];
        return widget.builder(context, driverPins, circles);
      },
    );
  }

  MapCircle _pulseRing(ColorScheme scheme, int ring) {
    final progress = (_ticker.value + ring / _ringCount) % 1.0;
    final fade = 1 - progress;
    return MapCircle(
      center: widget.origin,
      radiusMeters: _radiusKm * 1000 * progress,
      color: scheme.primary.withValues(alpha: fade * 0.14),
      borderColor: scheme.primary.withValues(alpha: fade * 0.55),
    );
  }
}
