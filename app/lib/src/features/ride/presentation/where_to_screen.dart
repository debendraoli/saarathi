import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/location.dart';
import '../../../core/network/api_client.dart';
import '../../../core/router/app_router.dart';
import '../../../shared/haptics.dart';
import '../../../shared/widgets/map_circle_button.dart';
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
import 'widgets/where_to/booking_sheet.dart';
import 'widgets/where_to/saved_places_bar.dart';

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
  final _mapController = MapViewController();
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

  /// This screen can be reached either by a normal push (Home's "Ride"/
  /// "Send a parcel" tiles — something to pop back to) or via a shared
  /// location link (`deep_links.dart` uses `router.go`, replacing the whole
  /// stack — nothing to pop). A plain `context.pop()` would silently do
  /// nothing in the second case, leaving no way back at all; falling back
  /// to Home covers it either way.
  void _goBack(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Routes.home);
    }
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
    // 2+ stops is where the backend actually has something to reorder
    // (pickup/destination always stay fixed first/last) — see
    // `RouteGeometry.stopOrder`'s doc comment. Applying the optimized order
    // back onto `_stops` re-triggers this same query with the now-already-
    // optimal point sequence, which comes back as the identity order, so
    // this can't loop.
    if (_pickup != null && _dest != null && _stops.length >= 2) {
      ref.listen<AsyncValue<RouteGeometry>>(
        routeGeometryProvider(RouteQuery(path, _vehicle.wire)),
        (_, next) {
          final order = next.value?.stopOrder;
          if (order == null || order.length != _stops.length) return;
          final isIdentity =
              order.indexed.every((e) => e.$2 == e.$1);
          if (isIdentity) return;
          setState(() {
            final reordered = [for (final idx in order) _stops[idx]];
            _stops
              ..clear()
              ..addAll(reordered);
          });
        },
      );
    }
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
          final surge = next.value?.surgeMultiplier;
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
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.whereTo),
          automaticallyImplyLeading: false,
        ),
        body: Stack(
          children: [
            MapView(
              controller: _mapController,
              center: center,
              route: route?.value?.points ?? (path.length >= 2 ? path : const []),
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
                    // Not `colorScheme.tertiary` — this app's amber seed
                    // derives a muddy brown/olive tertiary tone, which read
                    // as unpolished against the map (see the driver-marker
                    // fix in trip_screen.dart for the same issue).
                    Colors.blueGrey.shade600,
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
                if (_dest != null && selectedEstimate?.value != null)
                  MapCallout(
                    point: _dest!,
                    text: l.arriveAt(
                        _arrivalTime(selectedEstimate!.value!.durationMins)),
                  ),
              ],
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: SavedPlacesBar(onPick: _pickSaved),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 12, bottom: 8),
                      child: MapCircleButton(
                        icon: Icons.arrow_back_rounded,
                        onTap: () => _goBack(context),
                      ),
                    ),
                    BookingSheet(
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
                      bargainingEnabled:
                          featureEnabled(ref, 'rides.bargaining'),
                      onBook: selectedEstimate?.value == null ||
                              _booking ||
                              selectedEstimate!.value!.nearbyDrivers == 0 ||
                              !featureEnabled(ref, 'rides.new_requests')
                          ? null
                          : () => _book(selectedEstimate.value!.finalFare),
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
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
