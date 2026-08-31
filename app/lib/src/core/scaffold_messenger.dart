import 'package:flutter/material.dart';
import 'package:saarathi/l10n/app_localizations.dart';

/// Lets non-widget code (deep-link handling, background listeners) show a
/// snackbar without needing a BuildContext of its own — wired into
/// `MaterialApp.router` in app.dart.
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// A transient network/backend hiccup, surfaced without disturbing whatever
/// the user is doing (no dialog, no navigation, tokens untouched) — for the
/// callers (the API client's token refresh, session bootstrap) that used to
/// react to this class of failure by forcing a logout.
void showOfflineToast() {
  String message = 'Network problem — retrying…';
  final context = rootScaffoldMessengerKey.currentContext;
  if (context != null) {
    try {
      message = AppL10n.of(context).errorNetwork;
    } catch (_) {/* fall back to the default above */}
  }
  rootScaffoldMessengerKey.currentState?.showSnackBar(
    SnackBar(content: Text(message)),
  );
}
