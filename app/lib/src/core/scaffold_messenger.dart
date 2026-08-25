import 'package:flutter/material.dart';

/// Lets non-widget code (deep-link handling, background listeners) show a
/// snackbar without needing a BuildContext of its own — wired into
/// `MaterialApp.router` in app.dart.
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
