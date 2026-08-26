import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
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
import '../../../shared/contact_picker.dart';
import '../../wallet/data/wallet_repository.dart';
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
  String? _preferredDriverPhone;

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

  /// "now + [durationMins]" formatted as a local HH:mm clock time, for the
  /// "arrive at …" callout floated over the destination pin.
  String _arrivalTime(int durationMins) => DateFormat.Hm()
      .format(DateTime.now().add(Duration(minutes: durationMins)));

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
      preferredDriverPhone: _preferredDriverPhone,
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
            // A fare estimate resolving right as this screen is being
            // navigated away from (e.g. the rider tapped back mid-fetch)
            // can fire this listener while the widget is deactivated but
            // not yet disposed — `context` isn't safe to touch synchronously
            // there. Defer past the frame where Flutter resolves that.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l.surgeNotice)),
              );
            });
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
            autoFitPins: true,
            // Always on: acts as a plain "my location" button before a
            // route exists, and swaps to "back to route" once one does and
            // the rider has panned away from it — see MapView's doc comment.
            showRecenterButton: true,
            pins: [
              if (_pickup != null)
                MapPin(
                  _pickup!,
                  Icons.emoji_people_rounded,
                  Theme.of(context).colorScheme.primary,
                  id: 'pickup',
                ),
              for (var i = 0; i < _stops.length; i++)
                MapPin(
                  _stops[i].point,
                  Icons.adjust_rounded,
                  Theme.of(context).colorScheme.tertiary,
                  id: 'stop-$i',
                  label: '${i + 1}',
                ),
              if (_dest != null)
                MapPin(
                  _dest!,
                  Icons.sports_score_rounded,
                  Theme.of(context).colorScheme.secondary,
                  id: 'dest',
                ),
            ],
            callouts: [
              if (_dest != null && selectedEstimate?.valueOrNull != null)
                MapCallout(
                  point: _dest!,
                  text: l.arriveAt(_arrivalTime(
                      selectedEstimate!.valueOrNull!.durationMins)),
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
                bargainingEnabled: featureEnabled(ref, 'rides.bargaining'),
                onBook: selectedEstimate?.valueOrNull == null ||
                        _booking ||
                        selectedEstimate!.valueOrNull!.nearbyDrivers == 0 ||
                        !featureEnabled(ref, 'rides.new_requests')
                    ? null
                    : () => _book(selectedEstimate.valueOrNull!.finalFare),
                ridesPaused: !featureEnabled(ref, 'rides.new_requests'),
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
                onPreferredDriverPhone: (phone) =>
                    setState(() => _preferredDriverPhone = phone),
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
                  _ModeChip(
                    icon: Icons.two_wheeler_rounded,
                    label: l.modeRider,
                    selected: mode == RideMode.ride,
                    onTap: () => onMode(RideMode.ride),
                  ),
                  const SizedBox(width: 8),
                  _ModeChip(
                    icon: Icons.inventory_2_rounded,
                    label: l.parcelTitle,
                    selected: mode == RideMode.delivery,
                    onTap: () => onMode(RideMode.delivery),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _CompactAddressCard(
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
                          child: _VehicleChip(
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
                    _CtaIconButton(
                      icon: payment == 'wallet'
                          ? Icons.account_balance_wallet_rounded
                          : Icons.payments_rounded,
                      tooltip: l.paymentMethodTitle,
                      onTap: () => _showPaymentMethodSheet(
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
                                            selected?.valueOrNull
                                                    ?.nearbyDrivers ==
                                                0
                                        ? l.noDriversNearby
                                        : estimates.isEmpty
                                            ? l.actionContinue
                                            : '${l.confirmRide} · $currencySymbol '
                                                '${(ask ?? selected?.valueOrNull?.finalFare)?.toStringAsFixed(0) ?? ''}',
                              ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _CtaIconButton(
                      icon: Icons.tune_rounded,
                      tooltip: l.requestSpecificDriver,
                      onTap: () => _showRequestDriverSheet(
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

/// A compact circular icon button flanking the Request button — payment
/// method on the left, driver-request options on the right, Yango-style.
class _CtaIconButton extends StatelessWidget {
  const _CtaIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: scheme.surfaceContainerHighest,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 52,
            height: 52,
            child: Icon(icon, color: scheme.onSurfaceVariant, size: 22),
          ),
        ),
      ),
    );
  }
}

/// Payment method picker — cash or wallet, with the live wallet balance
/// shown right on the wallet row instead of a separate hint line.
void _showPaymentMethodSheet(
  BuildContext context, {
  required String payment,
  required ValueChanged<String> onPayment,
}) {
  final l = AppL10n.of(context);
  showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
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
                  color: Theme.of(sheetContext).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              l.paymentMethodTitle,
              style: Theme.of(sheetContext)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            _PaymentMethodTile(
              icon: Icons.payments_rounded,
              label: l.paymentCash,
              selected: payment == 'cash',
              onTap: () {
                onPayment('cash');
                Navigator.pop(sheetContext);
              },
            ),
            Consumer(
              builder: (context, ref, _) {
                final wallet = ref.watch(walletBalanceProvider);
                return _PaymentMethodTile(
                  icon: Icons.account_balance_wallet_rounded,
                  label: l.paymentWallet,
                  trailing: wallet.when(
                    loading: () => const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    error: (_, __) => null,
                    data: (w) => Text(
                      '$currencySymbol ${w.balance.toStringAsFixed(0)}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                  ),
                  selected: payment == 'wallet',
                  onTap: () {
                    onPayment('wallet');
                    Navigator.pop(sheetContext);
                  },
                );
              },
            ),
          ],
        ),
      ),
    ),
  );
}

class _PaymentMethodTile extends StatelessWidget {
  const _PaymentMethodTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.trailing,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Row(
          children: [
            Icon(icon, color: scheme.onSurfaceVariant),
            const SizedBox(width: 14),
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 15)),
            ),
            if (trailing != null) ...[trailing!, const SizedBox(width: 10)],
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
              color: selected ? scheme.primary : scheme.outline,
            ),
          ],
        ),
      ),
    );
  }
}

/// Request a specific driver by phone number — sends them the trip first,
/// ahead of normal matching. UI shell only for now: wiring this to a real
/// backend "priority offer" endpoint is a separate, explicitly-scoped
/// backend change (driver lookup + a priority-offer dispatch path), not yet
/// built — this dialog is where that submission will hook in.
void _showRequestDriverSheet(
  BuildContext context,
  ValueChanged<String> onSubmit,
) {
  final l = AppL10n.of(context);
  final controller = TextEditingController();
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8,
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
      ),
      child: SafeArea(
        child: StatefulBuilder(
          builder: (sheetContext, setSheetState) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: Theme.of(sheetContext).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                l.requestSpecificDriver,
                style: Theme.of(sheetContext)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                l.requestSpecificDriverBody,
                style: Theme.of(sheetContext).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                keyboardType: TextInputType.phone,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: l.driverPhoneLabel,
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.contacts_rounded),
                    tooltip: l.pickFromContacts,
                    onPressed: () async {
                      final phone = await pickContactPhone();
                      if (phone != null) {
                        controller.text = phone;
                        setSheetState(() {});
                      }
                    },
                  ),
                ),
                onChanged: (_) => setSheetState(() {}),
              ),
              const SizedBox(height: 16),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                onPressed: controller.text.trim().isEmpty
                    ? null
                    : () {
                        onSubmit(controller.text.trim());
                        Navigator.of(sheetContext).pop();
                      },
                child: Text(l.requestSpecificDriver),
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.notifications_active_rounded,
                    size: 16,
                    color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l.driverWillBeNotified,
                      style:
                          Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                                color: Theme.of(sheetContext)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

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

/// A compact selectable vehicle-class chip (icon + label + price in one tight
/// column), Yango/Pathao/inDrive style — replaces the old taller card so a
/// row of these takes noticeably less vertical space and leaves more of the
/// sheet's height to the map.
class _VehicleChip extends StatelessWidget {
  const _VehicleChip({
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
    // Selected = solid inverse fill (reads as "chosen" at a glance, like the
    // reference apps); unselected = a quiet neutral chip.
    final fg = selected ? scheme.onInverseSurface : scheme.onSurfaceVariant;
    return Material(
      color: selected ? scheme.inverseSurface : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: fg),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                  color: fg,
                ),
              ),
              if (price != null) ...[
                const SizedBox(height: 1),
                price!.when(
                  // A shimmer the size of the eventual price text, not a
                  // spinner — the number then lands in the space already
                  // held for it instead of popping the layout.
                  loading: () => const SkeletonBox(width: 40, height: 12),
                  error: (_, __) =>
                      Text('—', style: TextStyle(fontSize: 11.5, color: fg)),
                  data: (fare) => Text(
                    '$currencySymbol ${fare.finalFare.toStringAsFixed(0)}',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: fg,
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

/// Pickup/destination collapsed onto one connected block: a dot-and-flag
/// rail on the left, one compact line per point on the right, and a swap
/// button — the single biggest space saving over the old two-full-row
/// layout. Tapping a line still opens the same search screen as before;
/// stops (uncommon) render as extra rail segments rather than a separate
/// section.
class _CompactAddressCard extends StatelessWidget {
  const _CompactAddressCard({
    required this.pickupText,
    required this.resolvingPickup,
    required this.destText,
    required this.resolvingDest,
    required this.stops,
    required this.onPickupTap,
    required this.onDestTap,
    required this.onAddStop,
    required this.onRemoveStop,
    required this.onSave,
    required this.onClearDest,
  });

  final String pickupText;
  final bool resolvingPickup;
  final String? destText;
  final bool resolvingDest;
  final List<String> stops;
  final VoidCallback onPickupTap;
  final VoidCallback onDestTap;
  final VoidCallback? onAddStop;
  final ValueChanged<int> onRemoveStop;
  final VoidCallback? onSave;
  final VoidCallback? onClearDest;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _AddressRail(scheme: scheme, stopCount: stops.length),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _AddressLine(
                      text: pickupText,
                      isPlaceholder: false,
                      loading: resolvingPickup,
                      onTap: onPickupTap,
                    ),
                    for (var i = 0; i < stops.length; i++)
                      _AddressLine(
                        text: stops[i],
                        isPlaceholder: false,
                        onTap: onAddStop ?? () {},
                        dim: true,
                        trailing: GestureDetector(
                          onTap: () => onRemoveStop(i),
                          child: Icon(Icons.close_rounded,
                              size: 16, color: scheme.outline),
                        ),
                      ),
                    _AddressLine(
                      text: destText ?? l.searchAddressHint,
                      isPlaceholder: destText == null,
                      loading: resolvingDest,
                      onTap: onDestTap,
                      last: true,
                    ),
                  ],
                ),
              ),
              if (onSave != null || onClearDest != null)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (onClearDest != null)
                        _RailButton(
                          icon: Icons.close_rounded,
                          tooltip: l.clearDestination,
                          onTap: onClearDest!,
                        ),
                      if (onSave != null)
                        _RailButton(
                          icon: Icons.bookmark_add_outlined,
                          tooltip: l.saveAction,
                          onTap: onSave!,
                        ),
                    ],
                  ),
                ),
            ],
          ),
          // A labeled row, not another bare icon — "stops is missing" was the
          // exact feedback the icon-only version got, so this one spells
          // itself out even at compact height.
          if (onAddStop != null) ...[
            Divider(height: 14, color: scheme.outlineVariant),
            InkWell(
              onTap: onAddStop,
              borderRadius: BorderRadius.circular(8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_location_alt_outlined,
                      size: 17, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    l.addStop,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The dot → (stop dots) → flag rail beside the address lines, sized to
/// match however many lines [_CompactAddressCard] is currently rendering.
class _AddressRail extends StatelessWidget {
  const _AddressRail({required this.scheme, required this.stopCount});
  final ColorScheme scheme;
  final int stopCount;

  @override
  Widget build(BuildContext context) {
    Widget dot(Color color, {bool square = false}) => Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: square ? BoxShape.rectangle : BoxShape.circle,
            borderRadius: square ? BorderRadius.circular(2) : null,
          ),
        );
    Widget line() => Container(
          width: 1.5,
          height: 16,
          margin: const EdgeInsets.symmetric(vertical: 3),
          color: scheme.outlineVariant,
        );
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          dot(scheme.primary),
          for (var i = 0; i < stopCount; i++) ...[
            line(),
            dot(scheme.tertiary),
          ],
          line(),
          dot(scheme.secondary, square: true),
        ],
      ),
    );
  }
}

/// One line of text inside [_CompactAddressCard] — a pickup, a stop, or the
/// destination.
class _AddressLine extends StatelessWidget {
  const _AddressLine({
    required this.text,
    required this.isPlaceholder,
    required this.onTap,
    this.loading = false,
    this.dim = false,
    this.last = false,
    this.trailing,
  });

  final String text;
  final bool isPlaceholder;
  final VoidCallback onTap;

  /// True while a coordinate dropped in from a Maps link is still being
  /// reverse-geocoded to a human label — shows a shimmer instead of the raw
  /// "27.700, 85.300" the line would otherwise flash.
  final bool loading;

  /// Stop lines render a touch lighter than pickup/destination.
  final bool dim;
  final bool last;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: EdgeInsets.only(bottom: last ? 0 : 8, top: 1),
        child: Row(
          children: [
            Expanded(
              child: loading
                  ? const SkeletonBox(width: 150, height: 14)
                  : Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: isPlaceholder
                          ? TextStyle(color: Theme.of(context).hintColor)
                          : TextStyle(
                              fontWeight:
                                  dim ? FontWeight.w500 : FontWeight.w700,
                              fontSize: 13.5,
                            ),
                    ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon,
              size: 18, color: Theme.of(context).colorScheme.outline),
        ),
      ),
    );
  }
}

/// The Ride/Delivery mode switch — a pair of compact chips instead of the
/// old full-width [SegmentedButton], so the header takes less vertical space.
class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    return Material(
      color: selected ? scheme.secondaryContainer : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: fg,
                ),
              ),
            ],
          ),
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
