import 'package:flutter/material.dart';

import '../../../domain/models.dart';
import 'trip_widgets_shared.dart';

/// Revealed when the sheet is swiped up: bigger photo, fleet-partner name,
/// vehicle + plate, and the fare breakdown. Rider-only (the counterpart
/// being expanded is always the driver — a driver has no analogous "vehicle"
/// to show about their rider).
class DriverExpandedDetail extends StatelessWidget {
  const DriverExpandedDetail(
      {super.key, required this.driver, required this.trip});
  final TripDriverPerson driver;
  final Trip trip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child:
              Avatar(name: driver.name, photoUrl: driver.photoUrl, radius: 40),
        ),
        if (driver.partnerName != null) ...[
          const SizedBox(height: 10),
          Center(
            child: Text(
              driver.partnerName!,
              style: textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
        const SizedBox(height: 18),
        if (driver.vehicleLabel.isNotEmpty || driver.plateNumber != null)
          DetailRow(
            icon: Icons.two_wheeler_rounded,
            label: [
              if (driver.vehicleLabel.isNotEmpty) driver.vehicleLabel,
              if (driver.plateNumber != null && driver.plateNumber!.isNotEmpty)
                driver.plateNumber!,
            ].join(' · '),
          ),
        const SizedBox(height: 10),
        DetailRow(
          icon: Icons.payments_rounded,
          label: 'NPR ${trip.finalFare.toStringAsFixed(0)}'
              '${trip.distanceKm > 0 ? ' · ${trip.distanceKm.toStringAsFixed(1)} km' : ''}',
        ),
      ],
    );
  }
}
