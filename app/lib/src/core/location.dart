import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'config/app_config.dart';

/// Prompts for location permission (and service) as needed. Returns true when
/// the app may read a live position. Safe to call on screen entry — it triggers
/// the native permission dialog the first time.
Future<bool> ensureLocationPermission() async {
  try {
    // Ask for permission first so the OS dialog shows even if GPS is off.
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return false;
    }
    return await Geolocator.isLocationServiceEnabled();
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
