import 'package:flutter/material.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import 'trip_widgets_shared.dart';

/// The map-pin icon for a driver of the given vehicle class — same mapping
/// [_VehicleClassChip] uses for the trip-details chip, so the live driver
/// marker reads as "a two-wheeler/rickshaw/car", not a generic arrow.
IconData vehicleIconFor(String? vehicleClass) => switch (vehicleClass) {
      'three_wheeler' => Icons.electric_rickshaw_rounded,
      'four_wheeler' => Icons.directions_car_rounded,
      _ => Icons.two_wheeler_rounded,
    };

class VehicleClassChip extends StatelessWidget {
  const VehicleClassChip({super.key, required this.vehicleClass});
  final String vehicleClass;

  (IconData, String) _display(AppL10n l) => switch (vehicleClass) {
        'three_wheeler' => (
            vehicleIconFor(vehicleClass),
            l.vehicleThreeWheeler
          ),
        'four_wheeler' => (vehicleIconFor(vehicleClass), l.vehicleFourWheeler),
        _ => (vehicleIconFor(vehicleClass), l.vehicleTwoWheeler),
      };

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final (icon, label) = _display(l);
    return DetailRow(icon: icon, label: label);
  }
}
