import '../core/config/app_config.dart';

/// Resolves a backend-provided image reference to a URL the app can load.
///
/// [key] is either an absolute URL (seeded demo photos), a relative API path
/// (an uploaded photo, e.g. `/v1/items/<id>/photo` or
/// `/v1/driver/<id>/photo` — resolved against the configured API base rather
/// than baked in at upload time, since that base differs per build/device),
/// or null.
String? asImageUrl(Object? key) {
  final s = key as String?;
  if (s == null || s.isEmpty) return null;
  if (s.startsWith('http')) return s;
  if (s.startsWith('/')) return '${AppConfig.apiBase}$s';
  return null;
}
