import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// True when the device has some network. Emits on every connectivity change so
/// the UI can show an offline banner and trigger a reconcile on reconnect.
final connectivityProvider = StreamProvider<bool>((ref) async* {
  final conn = Connectivity();
  bool online(List<ConnectivityResult> r) =>
      r.any((x) => x != ConnectivityResult.none);

  yield online(await conn.checkConnectivity());
  yield* conn.onConnectivityChanged.map(online);
});
