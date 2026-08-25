import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/location.dart';
import '../../../core/network/api_client.dart';
import '../../../core/router/app_router.dart';
import '../../../shared/haptics.dart';
import '../../../shared/widgets/currency_chip.dart';
import '../../../shared/widgets/fare_stepper.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../../shared/widgets/wallet_balance_hint.dart';
import '../../delivery/application/delivery_controller.dart';
import '../../delivery/data/delivery_repository.dart';
import '../../delivery/domain/models.dart' as delivery;
import '../../places/data/maps_url_parser.dart' show coordLabel;
import '../../places/data/places_repository.dart';
import '../../places/presentation/address_search_screen.dart';
import '../application/ride_controller.dart';
import '../data/ride_repository.dart';
import '../domain/models.dart';
import 'widgets/map_view.dart';

/// Ride (a personal trip) or Delivery (send a parcel) — one shared
/// pickup/destination picker, matching the tabbed layout Pathao/Yango/
/// inDrive all use instead of hiding parcel-sending behind a separate flow.
enum RideMode { ride, delivery }

/// Pick pickup (defaults to current location) + destination (search, tap the map,
/// or a saved place), choose bike/car — or switch to Delivery to send a parcel
/// along the same route — then book. Landmark-friendly for Dang.
class WhereToScreen extends ConsumerStatefulWidget {
  const WhereToScreen({
    super.key,
    this.initialDest,
    this.initialPickup,
    this.initialMode = RideMode.ride,
  });

  /// Destination chosen upstream (from the home address search), if any.
  final PlaceHit? initialDest;

  /// Pickup chosen upstream — only ever set by a Google Maps "Directions"
  /// link that encoded both ends (see `deep_links.dart`); every other entry
  /// point defaults pickup to the rider's current location via
  /// [_loadLocation] instead.
  final LatLng? initialPickup;

  /// Lets the parcel showcase card on the home screen land directly in
  /// Delivery mode instead of Ride.
  final RideMode initialMode;

  @override
  ConsumerState<WhereToScreen> createState() => _WhereToScreenState();
}

class _WhereToScreenState extends ConsumerState<WhereToScreen> {
  final _mapController = MapController();
  final _destLabel = TextEditingController();
  LatLng? _pickup;
  String? _pickupLabel; // null → current location
  LatLng? _dest;
  final List<Place> _stops = [];
  VehicleClass _vehicle = VehicleClass.twoWheeler;
  String _payment = 'cash';
  late RideMode _mode;

  /// Null until the rider touches the stepper for the currently-selected
  /// vehicle class — stays at the platform's default price for that class.
  double? _ask;
  bool _booking = false;

  /// Guards `_openSearch`/`_addStop`/`_saveDest` — a rapid double-tap on
  /// their triggering row/button before the first push/dialog opens could
  /// otherwise stack two `AddressSearchScreen` routes or two save dialogs.
  bool _navigating = false;

  /// True while [_destLabel] is still the raw "lat, lng" placeholder a
  /// Maps-link deep link/share hands over (see [_rawCoordPattern]) and the
  /// background reverse-geocode to a human label hasn't landed yet.
  bool _resolvingDest = false;
  /// Same, for [_pickupLabel] when [WhereToScreen.initialPickup] came from a
  /// Directions link.
  bool _resolvingPickup = false;
  static final _rawCoordPattern = RegExp(r'^-?\d+\.\d+, -?\d+\.\d+$');

  // Re-fetches the selected class's fare periodically while the sheet is
  // open so a supply crunch mid-request (surge kicking in while the rider
  // is still deciding) is reflected here, not just discovered on booking.
  Timer? _surgeCheckTimer;
  double? _lastSurge;

  // Delivery-mode-only fields.
  final _recipientName = TextEditingController();
  final _recipientPhone = TextEditingController();
  final _codAmount = TextEditingController();
  final _pickupNote = TextEditingController();
  delivery.ParcelSize _parcelSize = delivery.ParcelSize.small;
  bool _fragile = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    final d = widget.initialDest;
    if (d != null) {
      _dest = d.point;
      _destLabel.text = d.label;
      if (_rawCoordPattern.hasMatch(d.label)) {
        _resolvingDest = true;
        _resolveDestLabel(d.point);
      }
    }
    final p = widget.initialPickup;
    if (p != null) {
      _pickup = p;
      _pickupLabel = coordLabel(p);
      _resolvingPickup = true;
      _resolvePickupLabel(p);
    }
    _loadLocation();
    _surgeCheckTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!mounted || _mode != RideMode.ride) return;
      // _openSearch/_addStop push another screen on top without disposing
      // this one — skip the tick while it's covered, so the fare provider
      // isn't invalidated (and the surge snackbar can't fire) for a screen
      // the rider isn't even looking at right now.
      if (ModalRoute.of(context)?.isCurrent == false) return;
      final draft = _draft();
      if (draft == null) return;
      ref.invalidate(fareEstimateProvider(draft));
    });
  }

  @override
  void dispose() {
    _surgeCheckTimer?.cancel();
    _destLabel.dispose();
    _recipientName.dispose();
    _recipientPhone.dispose();
    _codAmount.dispose();
    _pickupNote.dispose();
    super.dispose();
  }

  Future<void> _loadLocation() async {
    await ensureLocationPermission();
    final here = await currentLatLng();
    if (!mounted) return;
    // A Directions-link pickup (widget.initialPickup) already claimed
    // _pickup in initState — GPS shouldn't override a rider's actual
    // chosen start point with "here".
    if (widget.initialPickup == null) setState(() => _pickup = here);
    // Keep an upstream-chosen destination centred; otherwise centre on pickup.
    _mapController.move(_dest ?? _pickup ?? here, 15);
  }

  /// Fills in the real address for a destination that arrived as bare
  /// coordinates (a Maps link deep link/share navigates straight here
  /// without waiting on this — see `deep_links.dart` — so the request
  /// sheet is never blocked behind it, just shows a shimmer until it lands).
  Future<void> _resolveDestLabel(LatLng point) async {
    final hit = await ref
        .read(placesRepositoryProvider)
        .reverse(point)
        .catchError((_) => null);
    if (!mounted) return;
    setState(() {
      _resolvingDest = false;
      if (hit != null) _destLabel.text = hit.label;
    });
  }

  /// Same as [_resolveDestLabel], for a Directions link's origin point.
  Future<void> _resolvePickupLabel(LatLng point) async {
    final hit = await ref
        .read(placesRepositoryProvider)
        .reverse(point)
        .catchError((_) => null);
    if (!mounted) return;
    setState(() {
      _resolvingPickup = false;
      if (hit != null) _pickupLabel = hit.label;
    });
  }

  Future<void> _openSearch({required bool forPickup}) async {
    if (_navigating) return;
    _navigating = true;
    final l = AppL10n.of(context);
    final pick = await Navigator.of(context).push<AddressPick>(
      MaterialPageRoute(
        builder: (_) => AddressSearchScreen(
          allowMap: false,
          title: forPickup ? l.searchPickupTitle : l.searchDestinationTitle,
        ),
      ),
    );
    _navigating = false;
    if (pick?.hit == null || !mounted) return;
    final hit = pick!.hit!;
    // A pasted Maps link always means "this is the destination" — regardless
    // of which field was open when it was pasted — unless it was a
    // "Directions" link that also carried an origin, in which case that
    // becomes pickup too (see AddressPick.mapsLink).
    final setPickup = forPickup && !pick.forceDestination;
    setState(() {
      if (setPickup) {
        _pickup = hit.point;
        _pickupLabel = hit.label;
      } else {
        _dest = hit.point;
        _destLabel.text = hit.label;
      }
      final origin = pick.originHit;
      if (origin != null) {
        _pickup = origin.point;
        _pickupLabel = origin.label;
      }
    });
    _mapController.move(hit.point, 15);
  }

  Future<void> _addStop() async {
    if (_navigating) return;
    _navigating = true;
    final pick = await Navigator.of(context).push<AddressPick>(
      MaterialPageRoute(
        builder: (_) => const AddressSearchScreen(allowMap: false),
      ),
    );
    _navigating = false;
    if (pick?.hit == null || !mounted) return;
    final hit = pick!.hit!;
    // Same "it's the destination" rule as pickup/destination search — a
    // Maps link pasted while adding a stop still isn't a stop, it's where
    // the rider is actually going.
    if (pick.forceDestination) {
      setState(() {
        _dest = hit.point;
        _destLabel.text = hit.label;
        final origin = pick.originHit;
        if (origin != null) {
          _pickup = origin.point;
          _pickupLabel = origin.label;
        }
      });
    } else {
      setState(() => _stops.add(Place(point: hit.point, label: hit.label)));
    }
    _mapController.move(hit.point, 15);
  }

  void _removeStop(int index) {
    setState(() => _stops.removeAt(index));
  }

  /// The current draft — null until pickup + destination are both set and
  /// distinct, so this doubles as the "can we price/book yet" gate.
  RideDraft? _draft() {
    if (_pickup == null || _dest == null) return null;
    if (const Distance().as(LengthUnit.Meter, _pickup!, _dest!) < 30) {
      return null;
    }
    return RideDraft(
      pickup: Place(
        point: _pickup!,
        label: _pickupLabel ?? AppL10n.of(context).useCurrentLocation,
      ),
      destination: Place(point: _dest!, label: _destLabel.text.trim()),
      stops: List.unmodifiable(_stops),
      vehicleClass: _vehicle,
      paymentMethod: _payment,
    );
  }

  Future<void> _book(double defaultFare) async {
    if (_pickup != null &&
        _dest != null &&
        const Distance().as(LengthUnit.Meter, _pickup!, _dest!) < 30) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).samePickupDrop)),
      );
      return;
    }
    final draft = _draft()?.copyWith(
      pricingMode: 'bid',
      askFare: _ask ?? defaultFare,
    );
    if (draft == null) return;
    setState(() => _booking = true);
    try {
      final trip = await ref.read(rideRepositoryProvider).book(draft);
      Haptics.success();
      if (mounted) context.go('${Routes.trip}/${trip.id}');
    } on ApiException catch (e) {
      Haptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.isNetwork ? AppL10n.of(context).errorNetwork : e.message,
            ),
          ),
        );
      }
    } catch (_) {
      Haptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).errorGeneric)),
        );
      }
    } finally {
      if (mounted) setState(() => _booking = false);
    }
  }

  bool get _canBookDelivery =>
      _pickup != null &&
      _dest != null &&
      _recipientName.text.trim().isNotEmpty &&
      _recipientPhone.text.trim().isNotEmpty;

  Future<void> _bookDelivery() async {
    if (!_canBookDelivery) return;
    setState(() => _booking = true);
    try {
      final booking = await ref.read(deliveryRepositoryProvider).book(
            delivery.ParcelDraft(
              origin: Place(
                point: _pickup!,
                label: _pickupLabel ?? AppL10n.of(context).useCurrentLocation,
              ),
              dest: Place(point: _dest!, label: _destLabel.text.trim()),
              size: _parcelSize,
              recipientName: _recipientName.text.trim(),
              recipientPhone: _recipientPhone.text.trim(),
              fragile: _fragile,
              codAmount: double.tryParse(_codAmount.text.trim()) ?? 0,
              pickupNote: _pickupNote.text.trim(),
              paymentMethod: _payment,
            ),
          );
      Haptics.success();
      if (mounted && booking.deliveryOtp != null) {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: Text(AppL10n.of(context).deliveryOtpTitle),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(AppL10n.of(context).deliveryOtpBody),
                const SizedBox(height: 12),
                Text(
                  booking.deliveryOtp!,
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 4,
                  ),
                ),
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: Text(AppL10n.of(context).actionContinue),
              ),
            ],
          ),
        );
      }
      if (mounted) context.go('${Routes.trip}/${booking.trip.id}');
    } catch (_) {
      Haptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).errorGeneric)),
        );
      }
    } finally {
      if (mounted) setState(() => _booking = false);
    }
  }

  void _pickSaved(SavedPlace place) {
    setState(() {
      _dest = place.point;
      _destLabel.text = place.label;
    });
    _mapController.move(place.point, 15);
  }

  Future<void> _saveDest() async {
    if (_dest == null || _navigating) return;
    _navigating = true;
    final controller = TextEditingController(text: _destLabel.text.trim());
    final label = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Save place'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Home, Work, …'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppL10n.of(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(AppL10n.of(context).saveAction),
          ),
        ],
      ),
    );
    _navigating = false;
    if (label == null || label.isEmpty) return;
    try {
      await ref
          .read(placesRepositoryProvider)
          .add(label, _dest!, address: _destLabel.text.trim());
      ref.invalidate(savedPlacesProvider);
    } catch (_) {/* non-blocking */}
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final center = _pickup ?? const LatLng(28.033, 82.484);
    // Draw the road route as soon as pickup + destination are both chosen.
    final path = [
      if (_pickup != null) _pickup!,
      for (final s in _stops) s.point,
      if (_dest != null) _dest!,
    ];
    final route = (_pickup != null && _dest != null)
        ? ref.watch(routeGeometryProvider(RouteQuery(path, _vehicle.wire)))
        : null;
    final baseDraft = _mode == RideMode.ride ? _draft() : null;
    // Live per-class prices as soon as pickup + destination are both set —
    // shown directly on the vehicle cards, no separate "continue" step
    // needed to see them. Each class is its own cached provider call, so
    // switching the selected class never re-fetches what's already shown.
    final estimates = baseDraft == null
        ? const <VehicleClass, AsyncValue<FareEstimate>>{}
        : {
            for (final v in VehicleClass.values)
              v: ref.watch(
                  fareEstimateProvider(baseDraft.copyWith(vehicleClass: v))),
          };
    final selectedEstimate = estimates[_vehicle];
    if (baseDraft != null) {
      ref.listen<AsyncValue<FareEstimate>>(
        fareEstimateProvider(baseDraft),
        (_, next) {
          final surge = next.valueOrNull?.surgeMultiplier;
          if (surge == null) return;
          if (_lastSurge != null && surge > _lastSurge!) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l.surgeNotice)),
            );
          }
          _lastSurge = surge;
        },
      );
    }
    final deliveryEstimate =
        (_mode == RideMode.delivery && _pickup != null && _dest != null)
            ? ref.watch(deliveryEstimateProvider(DeliveryEstimateQuery(
                origin: _pickup!,
                dest: _dest!,
                size: _parcelSize,
                fragile: _fragile,
              )))
            : null;
    return Scaffold(
      appBar: AppBar(title: Text(l.whereTo)),
      body: Stack(
        children: [
          MapView(
            controller: _mapController,
            center: center,
            route: route?.valueOrNull ?? (path.length >= 2 ? path : const []),
            onTap: (p) => setState(() => _dest = p),
            pins: [
              if (_pickup != null)
                MapPin(
                  _pickup!,
                  Icons.emoji_people_rounded,
                  Theme.of(context).colorScheme.primary,
                ),
              for (final s in _stops)
                MapPin(
                  s.point,
                  Icons.adjust_rounded,
                  Theme.of(context).colorScheme.tertiary,
                ),
              if (_dest != null)
                MapPin(
                  _dest!,
                  Icons.sports_score_rounded,
                  Theme.of(context).colorScheme.secondary,
                ),
            ],
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: _SavedPlacesBar(onPick: _pickSaved),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              top: false,
              child: _Sheet(
                mode: _mode,
                onMode: (m) => setState(() {
                  _mode = m;
                  _ask = null;
                }),
                pickupText: _pickupLabel ?? l.useCurrentLocation,
                resolvingPickup: _resolvingPickup,
                destText: _dest == null ? null : _destLabel.text,
                resolvingDest: _resolvingDest,
                stops: [for (final s in _stops) s.label],
                vehicle: _vehicle,
                estimates: estimates,
                payment: _payment,
                ask: _ask,
                booking: _booking,
                onPickupTap: () => _openSearch(forPickup: true),
                onDestTap: () => _openSearch(forPickup: false),
                onAddStop: _stops.length >= 3 ? null : _addStop,
                onRemoveStop: _removeStop,
                onVehicle: (v) => setState(() {
                  _vehicle = v;
                  _ask = null;
                }),
                onPayment: (p) => setState(() => _payment = p),
                onAsk: (v) => setState(() => _ask = v),
                onBook: selectedEstimate?.valueOrNull == null || _booking
                    ? null
                    : () => _book(selectedEstimate!.valueOrNull!.finalFare),
                onSave: _dest == null ? null : _saveDest,
                onClearDest: _dest == null
                    ? null
                    : () => setState(() {
                          _dest = null;
                          _destLabel.clear();
                          _ask = null;
                        }),
                deliveryEstimate: deliveryEstimate,
                parcelSize: _parcelSize,
                onParcelSize: (s) => setState(() => _parcelSize = s),
                fragile: _fragile,
                onFragile: (v) => setState(() => _fragile = v),
                recipientName: _recipientName,
                recipientPhone: _recipientPhone,
                codAmount: _codAmount,
                pickupNote: _pickupNote,
                canBookDelivery: _canBookDelivery,
                onBookDelivery: _bookDelivery,
                onFieldChanged: () => setState(() {}),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Sheet extends StatelessWidget {
  const _Sheet({
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
    required this.onBook,
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
  final VoidCallback? onBook;
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
              SegmentedButton<RideMode>(
                segments: [
                  ButtonSegment(
                    value: RideMode.ride,
                    icon: const Icon(Icons.two_wheeler_rounded),
                    label: Text(l.modeRider),
                  ),
                  ButtonSegment(
                    value: RideMode.delivery,
                    icon: const Icon(Icons.inventory_2_rounded),
                    label: Text(l.parcelTitle),
                  ),
                ],
                selected: {mode},
                onSelectionChanged: (s) => onMode(s.first),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    _LocationRow(
                      label: l.pickup,
                      dotColor: scheme.primary,
                      icon: Icons.emoji_people_rounded,
                      text: pickupText,
                      isPlaceholder: false,
                      loading: resolvingPickup,
                      onTap: onPickupTap,
                    ),
                    for (var i = 0; i < stops.length; i++) ...[
                      Divider(
                          height: 1, indent: 48, color: scheme.outlineVariant),
                      _LocationRow(
                        label: l.stopLabel,
                        dotColor: scheme.tertiary,
                        icon: Icons.adjust_rounded,
                        text: stops[i],
                        isPlaceholder: false,
                        onTap: onAddStop ?? () {},
                        trailing: IconButton(
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => onRemoveStop(i),
                        ),
                      ),
                    ],
                    Divider(
                        height: 1, indent: 48, color: scheme.outlineVariant),
                    _LocationRow(
                      label: l.destination,
                      dotColor: scheme.secondary,
                      icon: Icons.sports_score_rounded,
                      text: destText ?? l.searchAddressHint,
                      isPlaceholder: destText == null,
                      loading: resolvingDest,
                      onTap: onDestTap,
                      trailing: onSave == null && onClearDest == null
                          ? null
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (onClearDest != null)
                                  IconButton(
                                    icon: const Icon(Icons.close_rounded),
                                    tooltip: l.clearDestination,
                                    onPressed: onClearDest,
                                  ),
                                if (onSave != null)
                                  IconButton(
                                    icon:
                                        const Icon(Icons.bookmark_add_outlined),
                                    onPressed: onSave,
                                  ),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
              if (mode == RideMode.ride && onAddStop != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: onAddStop,
                    icon: const Icon(Icons.add_location_alt_outlined, size: 20),
                    label: Text(l.addStop),
                  ),
                ),
              const SizedBox(height: 14),
              if (mode == RideMode.ride) ...[
                Row(
                  children: [
                    for (final v in VehicleClass.values)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                            right: v == VehicleClass.values.last ? 0 : 8,
                          ),
                          child: _VehicleCard(
                            selected: vehicle == v,
                            icon: _vehicleIcon(v),
                            label: _vehicleLabel(l, v),
                            // Only the selected card shows a price — tapping
                            // another card selects it and reveals its price
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
                  const SizedBox(height: 16),
                  selected.when(
                    // Shaped like the FareStepper it's about to become —
                    // two round step-button placeholders either side of a
                    // pill the size of the price — so the fare landing
                    // doesn't shove the rest of the sheet around.
                    loading: () => const Padding(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      child: _FareStepperSkeleton(),
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
                        ),
                        const SizedBox(height: 14),
                        SegmentedButton<String>(
                          segments: [
                            ButtonSegment(
                              value: 'cash',
                              icon: const Icon(Icons.payments_rounded),
                              label: Text(l.paymentCash),
                            ),
                            ButtonSegment(
                              value: 'wallet',
                              icon: const Icon(
                                  Icons.account_balance_wallet_rounded),
                              label: Text(l.paymentWallet),
                            ),
                          ],
                          selected: {payment},
                          onSelectionChanged: (s) => onPayment(s.first),
                        ),
                        if (payment == 'wallet')
                          WalletBalanceHint(amount: fare.finalFare),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: onBook,
                  child: booking
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        )
                      : Text(
                          estimates.isEmpty ? l.actionContinue : l.confirmRide),
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

class _FareStepperSkeleton extends StatelessWidget {
  const _FareStepperSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _StepButtonSkeleton(scheme: scheme),
        const SizedBox(width: 8),
        const SkeletonBox(width: 100, height: 32, borderRadius: 999),
        const SizedBox(width: 8),
        _StepButtonSkeleton(scheme: scheme),
      ],
    );
  }
}

class _StepButtonSkeleton extends StatelessWidget {
  const _StepButtonSkeleton({required this.scheme});
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// A selectable vehicle-class card (icon + label), inDrive/Yango style.
class _VehicleCard extends StatelessWidget {
  const _VehicleCard({
    required this.selected,
    required this.icon,
    required this.label,
    required this.price,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String label;

  /// Live price for this class — null before pickup/destination are set.
  final AsyncValue<FareEstimate>? price;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color:
          selected ? scheme.primaryContainer : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? scheme.primary : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 28,
                color: selected
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 12.5,
                  color:
                      selected ? scheme.onPrimaryContainer : scheme.onSurface,
                ),
              ),
              if (price != null) ...[
                const SizedBox(height: 4),
                price!.when(
                  // A shimmer the size of the eventual price text, not a
                  // spinner — the number then lands in the space already
                  // held for it instead of popping the layout.
                  loading: () => const SkeletonBox(width: 46, height: 12),
                  error: (_, __) => Text(
                    '—',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: selected
                          ? scheme.onPrimaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                  data: (fare) => Text(
                    '$currencySymbol ${fare.finalFare.toStringAsFixed(0)}',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? scheme.onPrimaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One tappable pickup/destination row inside the ride sheet.
class _LocationRow extends StatelessWidget {
  const _LocationRow({
    required this.label,
    required this.dotColor,
    required this.icon,
    required this.text,
    required this.isPlaceholder,
    required this.onTap,
    this.trailing,
    this.loading = false,
  });

  final String label;
  final Color dotColor;
  final IconData icon;
  final String text;
  final bool isPlaceholder;
  final VoidCallback onTap;
  final Widget? trailing;

  /// True while a coordinate dropped in from a Maps link is still being
  /// reverse-geocoded to a human label — shows a shimmer in its place
  /// instead of the raw "27.700, 85.300" the row would otherwise flash.
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: dotColor),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label.toUpperCase(),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.outline,
                          letterSpacing: 0.6,
                        ),
                  ),
                  const SizedBox(height: 2),
                  if (loading)
                    const SkeletonBox(width: 160, height: 14)
                  else
                    Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: isPlaceholder
                          ? TextStyle(color: Theme.of(context).hintColor)
                          : const TextStyle(fontWeight: FontWeight.w600),
                    ),
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

/// Quick-pick chips for the user's saved places (Home / Work / favourites).
class _SavedPlacesBar extends ConsumerWidget {
  const _SavedPlacesBar({required this.onPick});
  final void Function(SavedPlace) onPick;

  IconData _iconFor(String label) {
    final l = label.toLowerCase();
    if (l.contains('home')) return Icons.home_rounded;
    if (l.contains('work') || l.contains('office')) return Icons.work_rounded;
    return Icons.bookmark_rounded;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final places = ref.watch(savedPlacesProvider).valueOrNull ?? const [];
    if (places.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final p in places)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                avatar: Icon(_iconFor(p.label), size: 18),
                label: Text(p.label),
                onPressed: () => onPick(p),
              ),
            ),
        ],
      ),
    );
  }
}
