/// The account's server role. A person is a `rider` by default and can also
/// become a `driver`; anything else is staff (not an app user).
enum UserRole {
  rider,
  driver,
  staff;

  static UserRole fromWire(String? s) {
    switch (s) {
      case 'rider':
        return UserRole.rider;
      case 'driver':
        return UserRole.driver;
      default:
        return UserRole.staff;
    }
  }
}

/// Which experience the user is currently looking at. One account, two modes;
/// driver mode is only reachable once the account's role is `driver`.
enum AppMode { rider, driver }

class AppUser {
  const AppUser({
    required this.id,
    required this.phone,
    required this.role,
    this.fullName,
    this.status,
  });

  final String id;
  final String phone;
  final UserRole role;
  final String? fullName;
  final String? status;

  bool get isDriver => role == UserRole.driver;

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        id: j['id'] as String,
        phone: j['phone'] as String,
        role: UserRole.fromWire(j['role'] as String?),
        fullName: j['full_name'] as String?,
        status: j['status'] as String?,
      );
}

class Session {
  const Session(
      {required this.access, required this.refresh, required this.user});

  final String access;
  final String refresh;
  final AppUser user;

  factory Session.fromJson(Map<String, dynamic> j) => Session(
        access: j['access_token'] as String,
        refresh: j['refresh_token'] as String,
        user: AppUser.fromJson(j['user'] as Map<String, dynamic>),
      );
}

enum AuthStatus { unknown, unauthenticated, authenticated }

class AuthState {
  const AuthState(
      {this.status = AuthStatus.unknown, this.user, this.mode = AppMode.rider});

  final AuthStatus status;
  final AppUser? user;
  final AppMode mode;

  bool get isAuthenticated =>
      status == AuthStatus.authenticated && user != null;

  AuthState copyWith({AuthStatus? status, AppUser? user, AppMode? mode}) =>
      AuthState(
        status: status ?? this.status,
        user: user ?? this.user,
        mode: mode ?? this.mode,
      );
}
