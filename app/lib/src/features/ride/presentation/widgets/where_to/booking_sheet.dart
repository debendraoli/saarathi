import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../../../shared/widgets/currency_chip.dart';
import '../../../../../shared/widgets/fare_stepper.dart';
import '../../../../../shared/widgets/skeleton.dart';
import '../../../../../shared/widgets/wallet_balance_hint.dart';
import '../../../../delivery/domain/models.dart' as delivery;
import '../../../domain/models.dart';
import '../../where_to_screen.dart' show RideMode;
import 'compact_address_card.dart';
import 'cta_icon_button.dart';
import 'fare_stepper_skeleton.dart';
import 'mode_chip.dart';
import 'payment_method_sheet.dart';
import 'request_driver_sheet.dart';
import 'vehicle_chip.dart';

class BookingSheet extends StatelessWidget {
  const BookingSheet({
    super.key,
    required this.mode,
    required this.onMode,
    required this.pickupText,
    required this.resolvingPickup,
    required this.destText,
    required this.resolvingDest,
    required this.stops,
    required this.vehicle,
    required this.estimates,
    required this.payment,
    required this.ask,
    required this.booking,
    required this.onPickupTap,
    required this.onDestTap,
    required this.onAddStop,
    required this.onRemoveStop,
    required this.onVehicle,
    required this.onPayment,
    required this.onAsk,
    required this.bargainingEnabled,
    required this.onBook,
    required this.ridesPaused,
    required this.onSave,
    required this.onClearDest,
    required this.deliveryEstimate,
    required this.parcelSize,
    required this.onParcelSize,
    required this.fragile,
    required this.onFragile,
    required this.recipientName,
    required this.recipientPhone,
    required this.codAmount,
    required this.pickupNote,
    required this.canBookDelivery,
    required this.onBookDelivery,
    required this.onFieldChanged,
    required this.onPreferredDriverPhone,
  });

  final RideMode mode;
  final ValueChanged<RideMode> onMode;
  final String pickupText;

  /// True while a Directions-link-dropped pickup's human label is still
  /// being resolved in the background.
  final bool resolvingPickup;
  final String? destText;

  /// True while a Maps-link-dropped destination's human label is still
  /// being resolved in the background.
  final bool resolvingDest;
  final List<String> stops;
  final VehicleClass vehicle;

  /// Live price per class, keyed once pickup + destination are both set —
  /// empty beforehand, so the price row only appears once there's something
  /// to price.
  final Map<VehicleClass, AsyncValue<FareEstimate>> estimates;
  final String payment;

  /// The rider's current price for the selected class — null means "use the
  /// platform default for that class", same convention as the booking flow.
  final double? ask;
  final bool booking;
  final VoidCallback onPickupTap;
  final VoidCallback onDestTap;
  final VoidCallback? onAddStop;
  final ValueChanged<int> onRemoveStop;
  final ValueChanged<VehicleClass> onVehicle;
  final ValueChanged<String> onPayment;
  final ValueChanged<double> onAsk;

  /// `rides.bargaining` dashboard flag — false hides the drag-to-offer
  /// stepper in favour of a plain fixed-price display, since the backend
  /// silently ignores any custom ask while the flag is off.
  final bool bargainingEnabled;
  final VoidCallback? onBook;

  /// `rides.new_requests` dashboard flag (inverted) — true replaces the
  /// book button's label/state the same way a zero-nearby-drivers gate
  /// already does, instead of letting the rider tap and only find out
  /// booking is paused from the resulting error.
  final bool ridesPaused;
  final VoidCallback? onSave;
  final VoidCallback? onClearDest;

  // Delivery mode.
  final AsyncValue<delivery.DeliveryEstimate>? deliveryEstimate;
  final delivery.ParcelSize parcelSize;
  final ValueChanged<delivery.ParcelSize> onParcelSize;
  final bool fragile;
  final ValueChanged<bool> onFragile;
  final TextEditingController recipientName;
  final TextEditingController recipientPhone;
  final TextEditingController codAmount;
  final TextEditingController pickupNote;
  final bool canBookDelivery;
  final VoidCallback onBookDelivery;
  final VoidCallback onFieldChanged;
  final ValueChanged<String> onPreferredDriverPhone;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final selected = estimates[vehicle];
    return Card(
      margin: const EdgeInsets.all(12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.78,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ModeChip(
                    icon: Icons.two_wheeler_rounded,
                    label: l.modeRider,
                    selected: mode == RideMode.ride,
                    onTap: () => onMode(RideMode.ride),
                  ),
                  const SizedBox(width: 8),
                  ModeChip(
                    icon: Icons.inventory_2_rounded,
                    label: l.parcelTitle,
                    selected: mode == RideMode.delivery,
                    onTap: () => onMode(RideMode.delivery),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              CompactAddressCard(
                pickupText: pickupText,
                resolvingPickup: resolvingPickup,
                destText: destText,
                resolvingDest: resolvingDest,
                stops: stops,
                onPickupTap: onPickupTap,
                onDestTap: onDestTap,
                onAddStop: mode == RideMode.ride ? onAddStop : null,
                onRemoveStop: onRemoveStop,
                onSave: onSave,
                onClearDest: onClearDest,
              ),
              const SizedBox(height: 10),
              if (mode == RideMode.ride) ...[
                Row(
                  children: [
                    for (final v in VehicleClass.values)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                            right: v == VehicleClass.values.last ? 0 : 8,
                          ),
                          child: VehicleChip(
                            selected: vehicle == v,
                            icon: _vehicleIcon(v),
                            label: _vehicleLabel(l, v),
                            // Only the selected chip shows a price — tapping
                            // another chip selects it and reveals its price
                            // (already fetched, all classes are watched
                            // concurrently above; this only changes what's
                            // displayed, not what's fetched).
                            price: v == vehicle ? estimates[v] : null,
                            onTap: () => onVehicle(v),
                          ),
                        ),
                      ),
                  ],
                ),
                if (selected != null) ...[
                  const SizedBox(height: 10),
                  selected.when(
                    // Shaped like the FareStepper it's about to become —
                    // two round step-button placeholders either side of a
                    // pill the size of the price — so the fare landing
                    // doesn't shove the rest of the sheet around.
                    loading: () => const Padding(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      child: FareStepperSkeleton(),
                    ),
                    error: (_, __) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        l.errorNetwork,
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                    data: (fare) => Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (bargainingEnabled)
                          FareStepper(
                            amount: ask ?? fare.finalFare,
                            min: fare.finalFare,
                            max: fare.fareCeiling > 0
                                ? fare.fareCeiling
                                : fare.finalFare * 2,
                            onChanged: onAsk,
                            caption: l.distanceDuration(
                              fare.distanceKm.toStringAsFixed(1),
                              fare.durationMins,
                            ),
                          )
                        else
                          // Bargaining is off — the backend ignores any
                          // custom ask, so don't offer a stepper that
                          // silently wouldn't do anything.
                          Column(
                            children: [
                              Text(
                                '$currencySymbol ${fare.finalFare.toStringAsFixed(0)}',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              Text(
                                l.distanceDuration(
                                  fare.distanceKm.toStringAsFixed(1),
                                  fare.durationMins,
                                ),
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        if (payment == 'wallet') ...[
                          const SizedBox(height: 8),
                          WalletBalanceHint(amount: fare.finalFare),
                        ],
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    CtaIconButton(
                      icon: payment == 'wallet'
                          ? Icons.account_balance_wallet_rounded
                          : Icons.payments_rounded,
                      tooltip: l.paymentMethodTitle,
                      onTap: () => showPaymentMethodSheet(
                        context,
                        payment: payment,
                        onPayment: onPayment,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                        ),
                        onPressed: onBook,
                        child: booking
                            ? const SizedBox(
                                height: 22,
                                width: 22,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2.4),
                              )
                            : Text(
                                mode == RideMode.ride && ridesPaused
                                    ? l.ridesPaused
                                    : mode == RideMode.ride &&
                                            selected?.value?.nearbyDrivers == 0
                                        ? l.noDriversNearby
                                        : estimates.isEmpty
                                            ? l.actionContinue
                                            : '${l.confirmRide} · $currencySymbol '
                                                '${(ask ?? selected?.value?.finalFare)?.toStringAsFixed(0) ?? ''}',
                              ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    CtaIconButton(
                      icon: Icons.tune_rounded,
                      tooltip: l.requestSpecificDriver,
                      onTap: () => showRequestDriverSheet(
                          context, onPreferredDriverPhone),
                    ),
                  ],
                ),
              ] else ...[
                SegmentedButton<delivery.ParcelSize>(
                  segments: [
                    for (final s in delivery.ParcelSize.values)
                      ButtonSegment(value: s, label: Text(s.label)),
                  ],
                  selected: {parcelSize},
                  onSelectionChanged: (s) => onParcelSize(s.first),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.fragile),
                  value: fragile,
                  onChanged: onFragile,
                ),
                if (deliveryEstimate != null)
                  deliveryEstimate!.when(
                    loading: () => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(l.deliveryFee),
                          const SkeletonBox(
                              width: 70, height: 20, borderRadius: 999),
                        ],
                      ),
                    ),
                    error: (_, __) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(l.errorNetwork,
                          style: TextStyle(color: scheme.error)),
                    ),
                    data: (fee) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(l.deliveryFee),
                          CurrencyChip(
                            amount: fee.deliveryFee.toStringAsFixed(0),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                TextField(
                  controller: recipientName,
                  onChanged: (_) => onFieldChanged(),
                  decoration: InputDecoration(labelText: l.recipientName),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: recipientPhone,
                  keyboardType: TextInputType.phone,
                  onChanged: (_) => onFieldChanged(),
                  decoration: InputDecoration(labelText: l.recipientPhone),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: codAmount,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: l.codLabel),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: pickupNote,
                  decoration: InputDecoration(labelText: l.pickupNoteLabel),
                ),
                const SizedBox(height: 14),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed:
                      canBookDelivery && !booking ? onBookDelivery : null,
                  child: booking
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        )
                      : Text(l.bookDelivery),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

IconData _vehicleIcon(VehicleClass v) => switch (v) {
      VehicleClass.twoWheeler => Icons.two_wheeler_rounded,
      VehicleClass.threeWheeler => Icons.electric_rickshaw_rounded,
      VehicleClass.fourWheeler => Icons.directions_car_rounded,
    };

String _vehicleLabel(AppL10n l, VehicleClass v) => switch (v) {
      VehicleClass.twoWheeler => l.vehicleTwoWheeler,
      VehicleClass.threeWheeler => l.vehicleThreeWheeler,
      VehicleClass.fourWheeler => l.vehicleFourWheeler,
    };
