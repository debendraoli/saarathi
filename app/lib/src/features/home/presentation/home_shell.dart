import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/location.dart';
import '../../../core/offline/connectivity.dart';
import '../../../core/router/app_router.dart';
import '../../../shared/haptics.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/domain/models.dart';
import '../../driver/data/driver_kyc_repository.dart';
import '../../driver/domain/models.dart' show KycStatus;
import '../../merchant/data/merchant_repository.dart';
import '../../merchant/presentation/merchant_dashboard_screen.dart';
import '../../notifications/data/notifications_repository.dart';
import '../../places/data/places_repository.dart';
import '../../ride/application/ride_controller.dart';
import 'driver_home.dart';
import 'rider_home.dart';

/// The signed-in shell. The Home tab fills the whole screen — Activity and
/// Account live behind a hamburger menu on the top right instead of eating
/// vertical space with a bottom bar, leaving room to grow the menu with more
/// entries later.
///
/// Which experience fills that Home slot is a one-way ratchet once staff
/// approves something: an approved merchant becomes merchant-only (their
/// store is the home screen — no more rider/driver access at all, though
/// they can still register additional stores from within it), and an
/// approved driver becomes driver-only (the rider/driver switch disappears —
/// no more requesting rides as a rider on this account). Short of that, a
/// driver whose KYC isn't approved yet can still flip modes, and a plain
/// rider sees the normal "become a driver"/"become a merchant" nudges.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  @override
  void initState() {
    super.initState();
    // Ask for location up front so pickup/search have a real position.
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureLocationReady());
  }

  Future<void> _ensureLocationReady() async {
    final granted = await ensureLocationPermission();
    if (!mounted || !granted) return;
    if (await isLocationServiceEnabled()) return;
    // Native Google Play Services "turn on location" dialog (no app exit).
    await requestLocationService();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final auth = ref.watch(authControllerProvider);
    final isDriverMode = auth.mode == AppMode.driver;
    final isDriverAccount = auth.user?.isDriver ?? false;

    // Only fetch KYC status for accounts that could possibly need it — an
    // autoDispose provider a rider account never watches never fires its
    // request at all.
    final driverKycAsync =
        isDriverAccount ? ref.watch(driverKycProvider) : null;
    final driverKycApproved =
        driverKycAsync?.value?.status == KycStatus.approved;
    final merchantsAsync = ref.watch(myMerchantsProvider);
    final hasApprovedMerchant =
        merchantsAsync.value?.any((m) => m.isApproved) ?? false;

    // Reconcile cached data when connectivity is restored — `driverKycProvider`/
    // `myMerchantsProvider` matter most here: a one-shot `FutureProvider` that
    // failed while offline just sits in `AsyncError` forever with nothing to
    // retry it automatically, which (see `identityLoading` below) used to
    // both leave `DriverHome`'s own "Retry" screen stuck and make the
    // rider/driver switch spuriously reappear for an already-approved
    // driver, since an error was being read the same as "not yet approved".
    ref.listen(connectivityProvider, (prev, next) {
      if (prev?.value != false || next.value != true) return;
      // Deferred, not just `if (!mounted) return` right here — confirmed
      // live elsewhere this session that `mounted` alone doesn't catch this:
      // it stays true through Flutter's `deactivate()`, but touching
      // providers through this widget's own Element during that window
      // (even via `ref.invalidate`, no direct `context` use) still throws.
      // Deferring past this frame's build resolves it either way.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.invalidate(myTripsProvider);
        ref.invalidate(inboxProvider);
        ref.invalidate(savedPlacesProvider);
        ref.invalidate(driverKycProvider);
        ref.invalidate(myMerchantsProvider);
      });
    });
    final online = ref.watch(connectivityProvider).value ?? true;
    final gpsOff = ref.watch(locationServiceProvider).value == false;

    // Avoid flashing the rider/driver toggle home (with its "become a
    // merchant"/"become a driver" nudges) for the split second before we
    // actually know whether this account is merchant- or driver-locked —
    // both providers are `autoDispose` and refetch fresh every time Home is
    // (re)entered, so without this every navigation back to Home would
    // flash the wrong body first.
    final identityLoading =
        (!merchantsAsync.hasValue && merchantsAsync.isLoading) ||
            (driverKycAsync != null &&
                !driverKycAsync.hasValue &&
                driverKycAsync.isLoading);
    // A fetch that failed (offline, say) and never got a real value is
    // "still don't know", not "confirmed not approved" — without this, the
    // switch used to spuriously reappear for an already-approved driver the
    // instant one of these providers hit a network error. Deliberately
    // separate from `identityLoading` above: `home`'s own selection stays
    // unchanged, so `DriverHome`/`MerchantHomeBody`'s own `.when(error: …)`
    // branch still gets to show a real "Retry" affordance — this only
    // stops the *switch* from asserting a negative off the back of an error.
    final identityUncertain =
        (!merchantsAsync.hasValue && merchantsAsync.hasError) ||
            (driverKycAsync != null &&
                !driverKycAsync.hasValue &&
                driverKycAsync.hasError);

    final Widget home;
    if (identityLoading) {
      home = _HomeLoading(isDriverMode: isDriverMode);
    } else if (hasApprovedMerchant) {
      home = const MerchantHomeBody();
    } else if (driverKycApproved) {
      home = const DriverHome();
    } else {
      home = isDriverMode ? const DriverHome() : const RiderHome();
    }
    // The rider/driver switch only makes sense while both sides are still
    // reachable — gone once either lock (merchant or approved-driver) kicks
    // in. `driverKycApproved`/`hasApprovedMerchant` both default to false
    // while their providers are still loading, so without the
    // `!identityLoading` guard an approved driver/merchant would see the
    // switch flash into view for a moment right after login before these
    // resolve and hide it again.
    final showModeSwitch = !identityLoading &&
        !identityUncertain &&
        isDriverAccount &&
        !driverKycApproved &&
        !hasApprovedMerchant;

    return Scaffold(
      appBar: AppBar(
        title: Text(_greeting(l, auth.user)),
        actions: [
          if (showModeSwitch) _ModeSwitch(mode: auth.mode),
          const _NotificationBell(),
          IconButton(
            icon: const Icon(Icons.menu_rounded),
            onPressed: () {
              Haptics.tap();
              context.push(Routes.menu);
            },
          ),
        ],
      ),
      // Bottom-only: the AppBar already accounts for the top inset. Neither
      // RiderHome nor DriverHome's scrollable content did anything for the
      // bottom system nav bar on its own, so the last card/button in either
      // one sat flush against it.
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (!online) const _OfflineBar(),
            if (gpsOff) const _LocationOffBar(),
            Expanded(child: home),
          ],
        ),
      ),
    );
  }

  String _greeting(AppL10n l, AppUser? user) {
    final name = user?.fullName;
    return l.greeting(name == null || name.isEmpty ? '' : ', $name');
  }
}

/// The hamburger menu, as a full screen (not a partial-width slide-over) —
/// user identity up top, then the screens that used to be bottom tabs, with
/// room to grow as more sections are added. A real `GoRoute` (see
/// `Routes.menu`), reached via `context.push` — not a raw
/// `Navigator.push(MaterialPageRoute(...))` sitting on top of go_router's
/// own Navigator, which corrupted its route-match bookkeeping badly enough
/// that every screen reached through here had a broken back button.
class MenuScreen extends ConsumerWidget {
  const MenuScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final user = ref.watch(authControllerProvider).user;
    final scheme = Theme.of(context).colorScheme;

    void go(String route) {
      Haptics.tap();
      context.push(route);
    }

    return Scaffold(
      body: SafeArea(
        child: ListView(
          children: [
            Container(
              color: scheme.primaryContainer,
              padding: const EdgeInsets.fromLTRB(12, 8, 16, 20),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.close_rounded,
                        color: scheme.onPrimaryContainer),
                    onPressed: () => context.pop(),
                  ),
                  const SizedBox(width: 6),
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: scheme.primary,
                    child: Text(
                      (user?.fullName?.isNotEmpty ?? false)
                          ? user!.fullName![0].toUpperCase()
                          : '👤',
                      style: TextStyle(fontSize: 20, color: scheme.onPrimary),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          user?.fullName?.isNotEmpty == true
                              ? user!.fullName!
                              : (user?.phone ?? ''),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: scheme.onPrimaryContainer,
                          ),
                        ),
                        if (user?.fullName?.isNotEmpty == true)
                          Text(
                            user?.phone ?? '',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: scheme.onPrimaryContainer,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long_rounded),
              title: Text(l.tabActivity),
              onTap: () => go(Routes.activity),
            ),
            ListTile(
              leading: const Icon(Icons.person_rounded),
              title: Text(l.tabAccount),
              onTap: () => go(Routes.account),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.add_location_alt_rounded),
              title: Text(l.placesHubTitle),
              onTap: () => go(Routes.placesHub),
            ),
            ListTile(
              leading: const Icon(Icons.settings_rounded),
              title: Text(l.settingsTitle),
              onTap: () => go(Routes.settings),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.shield_rounded),
              title: Text(l.safetyTitle),
              onTap: () => go(Routes.safety),
            ),
            ListTile(
              leading: const Icon(Icons.support_agent_rounded),
              title: Text(l.supportTitle),
              onTap: () => go(Routes.support),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: Text(l.aboutSection),
              onTap: () => go(Routes.about),
            ),
          ],
        ),
      ),
    );
  }
}

/// Neutral placeholder shown only until we know which home body an account
/// actually gets — never the rider/driver toggle home itself, so there's
/// nothing to visibly swap away from a moment later.
class _HomeLoading extends StatelessWidget {
  const _HomeLoading({required this.isDriverMode});
  final bool isDriverMode;

  @override
  Widget build(BuildContext context) {
    // The account could still turn out to be merchant-locked once identity
    // resolves (see the comment above this widget's call site) — but that's
    // rarer than a plain rider/driver account, and the current mode toggle
    // (known synchronously, unlike the merchant/KYC lookups this is standing
    // in for) is otherwise a reliable guess at which shape is coming.
    return isDriverMode
        ? const DriverHomeSkeleton()
        : const RiderHomeSkeleton();
  }
}

/// A prominent tap-to-enable banner shown while the device GPS is off.
class _LocationOffBar extends StatelessWidget {
  const _LocationOffBar();

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.tertiaryContainer,
      child: InkWell(
        onTap: requestLocationService,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.location_off_rounded,
                  size: 20, color: scheme.onTertiaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.locationOffTitle,
                      style: TextStyle(
                        color: scheme.onTertiaryContainer,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      l.locationOffShort,
                      style: TextStyle(
                        color: scheme.onTertiaryContainer,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: requestLocationService,
                child: Text(l.enable),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OfflineBar extends StatelessWidget {
  const _OfflineBar();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            AppL10n.of(context).offlineBanner,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onErrorContainer, fontSize: 12.5),
          ),
        ),
      ),
    );
  }
}

class _NotificationBell extends ConsumerWidget {
  const _NotificationBell();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(inboxProvider).value?.unread ?? 0;
    return IconButton(
      onPressed: () => context.push(Routes.notifications),
      icon: Badge(
        isLabelVisible: unread > 0,
        label: Text('$unread'),
        child: const Icon(Icons.notifications_rounded),
      ),
    );
  }
}

class _ModeSwitch extends ConsumerWidget {
  const _ModeSwitch({required this.mode});
  final AppMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SegmentedButton<AppMode>(
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        showSelectedIcon: false,
        segments: [
          ButtonSegment(value: AppMode.rider, label: Text(l.modeRider)),
          ButtonSegment(value: AppMode.driver, label: Text(l.modeDriver)),
        ],
        selected: {mode},
        onSelectionChanged: (s) =>
            ref.read(authControllerProvider.notifier).setMode(s.first),
      ),
    );
  }
}
