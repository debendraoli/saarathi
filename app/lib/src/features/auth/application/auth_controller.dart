import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/notifications/push_service.dart';
import '../../../core/storage/token_store.dart';
import '../data/auth_repository.dart';
import '../domain/models.dart';

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
    await _tokens.save(access: session.access, refresh: session.refresh);
    state = AuthState(
      status: AuthStatus.authenticated,
      user: session.user,
      mode: session.user.isDriver ? AppMode.driver : AppMode.rider,
    );
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
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  void _onExpired() {
    state = const AuthState(status: AuthStatus.unauthenticated);
  }
}

final authControllerProvider =
    NotifierProvider<AuthController, AuthState>(AuthController.new);
