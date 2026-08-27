import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/notifications/push_service.dart';
import '../../../core/offline/json_cache.dart';
import '../../../core/prefs.dart';
import '../../../core/storage/token_store.dart';
import '../../driver/data/driver_kyc_repository.dart';
import '../../merchant/data/merchant_repository.dart';
import '../../notifications/data/notifications_repository.dart';
import '../../places/data/places_repository.dart';
import '../../ride/application/ride_controller.dart';
import '../data/auth_repository.dart';
import '../domain/models.dart';

/// Thrown when the OTP was verified server-side (and consumed — it can't be
/// reused) but saving the resulting session locally failed. Distinct from a
/// wrong/expired code so the UI doesn't tell the user their code was
/// invalid when it was actually a device storage problem.
class SessionSaveException implements Exception {}

class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() {
    // Force re-login if a refresh ever fails mid-session.
    ref.read(apiClientProvider).onSessionExpired = _onExpired;
    Future.microtask(_bootstrap);
    return const AuthState();
  }

  AuthRepository get _repo => ref.read(authRepositoryProvider);
  TokenStore get _tokens => ref.read(tokenStoreProvider);

  /// The splash screen's entrance animation runs on this same clock — on a
  /// fast connection (or a cached/instant token check) the network work
  /// below can finish well inside that animation, and without this floor the
  /// router would yank the splash away mid-animation the instant status
  /// changes. A flat minimum keeps the transition feeling intentional either
  /// way, and costs nothing on a slow connection where the real work already
  /// takes longer than this.
  static const _minSplashDuration = Duration(milliseconds: 900);

  Future<void> _bootstrap() async {
    final started = DateTime.now();
    Future<void> settle() {
      final elapsed = DateTime.now().difference(started);
      final remaining = _minSplashDuration - elapsed;
      return remaining > Duration.zero
          ? Future.delayed(remaining)
          : Future.value();
    }

    final access = await _tokens.access;
    if (access == null) {
      await settle();
      state = state.copyWith(status: AuthStatus.unauthenticated);
      return;
    }
    try {
      final user = await _repo.me();
      await settle();
      state = AuthState(
        status: AuthStatus.authenticated,
        user: user,
        mode: user.isDriver ? AppMode.driver : AppMode.rider,
      );
      _registerPush();
    } catch (_) {
      await _tokens.clear();
      await settle();
      state = state.copyWith(status: AuthStatus.unauthenticated);
    }
  }

  void _registerPush() {
    PushService.instance.register(ref.read(apiClientProvider));
  }

  Future<String?> requestOtp(String phone) => _repo.requestOtp(phone);

  Future<void> verifyOtp(String phone, String code,
      {bool asDriver = false}) async {
    final session = await _repo.verifyOtp(phone, code, asDriver: asDriver);
    try {
      await _tokens.save(access: session.access, refresh: session.refresh);
    } catch (_) {
      throw SessionSaveException();
    }
    state = AuthState(
      status: AuthStatus.authenticated,
      user: session.user,
      mode: session.user.isDriver ? AppMode.driver : AppMode.rider,
    );
    // Belt-and-suspenders alongside signOut()'s cache clear: these
    // account-identity providers are plain `autoDispose` (one instance for
    // the whole app, not scoped per-session), so force a fresh fetch here
    // rather than trust that the widgets watching them always fully
    // unmount-and-remount across a sign-out/sign-in on the same device.
    ref.invalidate(myTripsProvider);
    ref.invalidate(inboxProvider);
    ref.invalidate(savedPlacesProvider);
    ref.invalidate(driverKycProvider);
    ref.invalidate(myMerchantsProvider);
    _registerPush();
  }

  void setMode(AppMode mode) => state = state.copyWith(mode: mode);

  /// Re-fetch the account (e.g. after KYC registration promotes rider→driver).
  Future<void> refresh() async {
    try {
      final user = await _repo.me();
      state = state.copyWith(status: AuthStatus.authenticated, user: user);
    } catch (_) {/* keep current state */}
  }

  Future<void> updateName(String name) async {
    final user = await _repo.updateName(name);
    state = state.copyWith(user: user);
  }

  Future<void> signOut() async {
    // Must happen before clearing tokens — unregister needs the still-valid
    // session to prove which device/user pairing to drop.
    await PushService.instance.unregister(ref.read(apiClientProvider));
    await _tokens.clear();
    // These `cacheThroughList` caches are device-local, keyed by endpoint
    // rather than by account — without this, the next account to log in on
    // this device could have its very first fetch fall back to *this*
    // account's cached data (e.g. a transient network hiccup right after
    // login), silently showing them someone else's rides/orders/merchant
    // list. Confirmed live: this is exactly how a rider→merchant switch on
    // the same device briefly showed the merchant account as the rider.
    await clearAllCaches(ref.read(sharedPreferencesProvider));
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  void _onExpired() {
    state = const AuthState(status: AuthStatus.unauthenticated);
  }
}

final authControllerProvider =
    NotifierProvider<AuthController, AuthState>(AuthController.new);
