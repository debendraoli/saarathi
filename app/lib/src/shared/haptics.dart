import 'package:flutter/services.dart';

/// Thin, named wrappers around [HapticFeedback] so call sites read as intent
/// ("this was a success") rather than a raw platform-feedback constant —
/// and so the mapping can be tuned in one place later.
abstract final class Haptics {
  /// Routine taps: nav switches, opening a screen, toggles.
  static void tap() => HapticFeedback.lightImpact();

  /// A meaningful action completed: ride confirmed, order placed, offer
  /// accepted, payment settled.
  static void success() => HapticFeedback.mediumImpact();

  /// A request was rejected or a validation/error state was shown.
  static void error() => HapticFeedback.heavyImpact();

  /// A destructive/high-stakes action: cancel ride, SOS, decline offer.
  static void warning() => HapticFeedback.vibrate();
}
