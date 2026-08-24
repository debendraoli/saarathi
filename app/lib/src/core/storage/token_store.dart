import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure JWT storage (Keychain / Keystore backed).
class TokenStore {
  TokenStore(this._storage);

  final FlutterSecureStorage _storage;

  static const _kAccess = 'saarathi.access';
  static const _kRefresh = 'saarathi.refresh';
  // Deliberately a separate key from access/refresh — this identifies the
  // physical install, not a session, so `clear()` (sign-out) must never
  // touch it. Otherwise every re-login on the same phone would look like a
  // brand new device to the single-device-per-account enforcement.
  static const _kDeviceId = 'saarathi.device_id';

  Future<String?> get access => _storage.read(key: _kAccess);
  Future<String?> get refresh => _storage.read(key: _kRefresh);

  Future<void> save({required String access, required String refresh}) async {
    await _storage.write(key: _kAccess, value: access);
    await _storage.write(key: _kRefresh, value: refresh);
  }

  Future<void> clear() async {
    await _storage.delete(key: _kAccess);
    await _storage.delete(key: _kRefresh);
  }

  /// This install's persistent id — generated once and kept forever
  /// (survives sign-out/sign-in), so the backend can tell "this same
  /// device logging back in" apart from "a genuinely different device"
  /// when enforcing single-device-per-account.
  Future<String> get deviceId async {
    final existing = await _storage.read(key: _kDeviceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final id = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await _storage.write(key: _kDeviceId, value: id);
    return id;
  }
}

final tokenStoreProvider = Provider<TokenStore>((ref) {
  return TokenStore(
    const FlutterSecureStorage(
      aOptions: AndroidOptions(),
    ),
  );
});
