import 'package:flutter/material.dart';

/// Shown while the session is being restored (auth status == unknown). The
/// router redirects away automatically once bootstrap resolves.
///
/// Deliberately blank — the actual splash the user sees is the OS-level one
/// (Android's native SplashScreen API, configured via `flutter_native_splash`
/// in pubspec.yaml + the hand-added branding image in the `-v31` styles).
/// This widget only fills the brief gap between Flutter's first frame (which
/// dismisses that native splash) and auth bootstrap finishing; matching its
/// solid white background exactly means that gap is imperceptible rather
/// than reading as a second, different-looking splash screen.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(backgroundColor: Colors.white);
  }
}
