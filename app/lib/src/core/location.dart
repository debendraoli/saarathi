import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

import 'config/app_config.dart';

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

/// Best-effort current position, degrading to the Dang district centre when
/// location is unavailable/denied (offline-tolerant, Nepal rural reality).
Future<LatLng> currentLatLng() async {
  const fallback = LatLng(AppConfig.defaultLat, AppConfig.defaultLng);
  try {
    if (!await ensureLocationPermission()) return fallback;
    if (!await Geolocator.isLocationServiceEnabled()) return fallback;
    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
    return LatLng(pos.latitude, pos.longitude);
  } catch (_) {
    return fallback;
  }
}
