import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../shared/image_url.dart';
import '../../../application/ride_controller.dart';
import '../../../data/ride_repository.dart';
import '../../../domain/models.dart';
import '../../../domain/rating_tags.dart';
import '../rating_sheet.dart';

/// Tiny helpers/widgets shared by more than one extracted trip-screen widget
/// — kept here instead of duplicated since none of them are small enough to
/// justify copy-pasting into every file that needs them.

RatingContext ratingContextFor(Trip trip, bool iAmDriver) => iAmDriver
    ? RatingContext.driverRatesRider
    : trip.tripType == 'delivery'
        ? RatingContext.senderRatesCourier
        : RatingContext.riderRatesDriver;

/// Shows the rating sheet and posts its result, independent of any
/// navigation the caller does around it — see the `TripScreen` completion
/// listener (shown before navigating away) and `_StatusSheet._rate` (the
/// manual "Rate trip"/"Edit rating" button, for revisiting a trip from
/// history) for the two call sites.
Future<void> autoRateTrip(BuildContext context, WidgetRef ref, Trip trip,
    RatingContext ratingContext, TripSummary summary) async {
  final result = await showRatingSheet(
    context,
    useRootNavigator: true,
    ratingContext: ratingContext,
    summary: summary,
  );
  if (result == null) return;
  try {
    await ref
        .read(rideRepositoryProvider)
        .rate(trip.id, result.stars, tags: result.tags);
  } catch (_) {/* non-blocking */}
  ref.invalidate(myTripsProvider);
}

/// Photo (driver) or initials avatar (rider — no photo concept exists).
class Avatar extends StatelessWidget {
  const Avatar({super.key, this.name, this.photoUrl, this.radius = 22});
  final String? name;
  final String? photoUrl;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = asImageUrl(photoUrl);
    if (url != null) {
      return CircleAvatar(
          radius: radius, backgroundImage: CachedNetworkImageProvider(url));
    }
    final initials = (name == null || name!.trim().isEmpty)
        ? '?'
        : name!
            .trim()
            .split(RegExp(r'\s+'))
            .take(2)
            .map((s) => s[0].toUpperCase())
            .join();
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.secondaryContainer,
      child: Text(
        initials,
        style: TextStyle(
          color: scheme.onSecondaryContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class DetailRow extends StatelessWidget {
  const DetailRow({super.key, required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: 10),
        Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
      ],
    );
  }
}
