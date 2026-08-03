import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'config/app_config.dart';

/// Prompts for location permission (and service) as needed. Returns true when
/// the app may read a live position. Safe to call on screen entry — it triggers
/// the native permission dialog the first time.
Future<bool> ensureLocationPermission() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    return perm == LocationPermission.always ||
        perm == LocationPermission.whileInUse;
  } catch (_) {
    return false;
  }
}

/// Best-effort current position, degrading to the Dang district centre when
/// location is unavailable/denied (offline-tolerant, Nepal rural reality).
Future<LatLng> currentLatLng() async {
  const fallback = LatLng(AppConfig.defaultLat, AppConfig.defaultLng);
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return fallback;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return fallback;
    }
    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
    return LatLng(pos.latitude, pos.longitude);
  } catch (_) {
    return fallback;
  }
}
