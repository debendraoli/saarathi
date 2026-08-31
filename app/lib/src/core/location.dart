import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:location/location.dart' as loc;
import 'package:permission_handler/permission_handler.dart' hide ServiceStatus;

import 'config/app_config.dart';

/// Live location-service (GPS) status: emits the current value, then updates
/// whenever the user toggles GPS. `false` = off.
final locationServiceProvider = StreamProvider<bool>((ref) async* {
  yield await isLocationServiceEnabled();
  yield* Geolocator.getServiceStatusStream()
      .map((s) => s == ServiceStatus.enabled);
});

/// Device compass heading (degrees, 0-360) — kept alive for the app's whole
/// process lifetime once first watched, deliberately never torn down and
/// re-subscribed per trip. `flutter_compass`'s underlying platform listener
/// was found live not to restart reliably once every Dart-side listener had
/// cancelled and a new one attached later (confirmed: it worked for the
/// first trip after app launch, then silently produced no more events for
/// any later trip) — `ref.keepAlive()` here means the very first
/// subscription is also the only one that ever happens, sidestepping that
/// restart path entirely rather than depending on the plugin fixing it.
final compassHeadingProvider = StreamProvider<double?>((ref) {
  ref.keepAlive();
  return (FlutterCompass.events ?? const Stream<CompassEvent>.empty())
      .map((event) => event.heading);
});

// Dedupe concurrent requests — the plugins throw if a second request starts
// while one is pending (e.g. home boot + tapping "Where to" at once).
Future<bool>? _pending;

/// Prompts for location permission via permission_handler (reliable across
/// OEMs incl. MIUI/Xiaomi). Returns true when the app may read a live position.
/// Safe to call repeatedly and from several places simultaneously.
Future<bool> ensureLocationPermission() {
  return _pending ??= _request().whenComplete(() => _pending = null);
}

Future<bool> _request() async {
  try {
    final status = await Permission.locationWhenInUse.status;
    if (status.isGranted || status.isLimited) return true;
    if (status.isPermanentlyDenied) return false;
    final result = await Permission.locationWhenInUse.request();
    return result.isGranted || result.isLimited;
  } catch (_) {
    return false;
  }
}

/// Whether the device's location service (GPS toggle) is on.
Future<bool> isLocationServiceEnabled() async {
  try {
    return await Geolocator.isLocationServiceEnabled();
  } catch (_) {
    return false;
  }
}

/// Opens the OS location settings so the user can switch GPS on.
Future<void> openLocationSettings() async {
  try {
    await Geolocator.openLocationSettings();
  } catch (_) {/* best effort */}
}

/// Triggers the native (Google Play Services) "turn on location" dialog so the
/// user can enable GPS without leaving the app. Returns true if it ends up on.
Future<bool> requestLocationService() async {
  try {
    return await loc.Location().requestService();
  } catch (_) {
    return false;
  }
}

/// A resolved position plus whether it's the Dang-district fallback rather
/// than a real GPS fix — callers that would otherwise act on a fake location
/// as if it were real (e.g. a driver going online) need to know the
/// difference; callers that just want a best-effort point for search/display
/// (the common case) can ignore it via [currentLatLng].
class LocationResult {
  const LocationResult(this.point, {required this.isFallback});
  final LatLng point;
  final bool isFallback;
}

/// Best-effort current position, degrading to the Dang district centre when
/// location is unavailable/denied (offline-tolerant, Nepal rural reality).
Future<LocationResult> currentLocation() async {
  const fallback = LocationResult(
      LatLng(AppConfig.defaultLat, AppConfig.defaultLng),
      isFallback: true);
  try {
    if (!await ensureLocationPermission()) return fallback;
    if (!await Geolocator.isLocationServiceEnabled()) return fallback;
    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
    return LocationResult(LatLng(pos.latitude, pos.longitude),
        isFallback: false);
  } catch (_) {
    return fallback;
  }
}

/// Best-effort current position, degrading to the Dang district centre when
/// location is unavailable/denied (offline-tolerant, Nepal rural reality).
Future<LatLng> currentLatLng() async => (await currentLocation()).point;
