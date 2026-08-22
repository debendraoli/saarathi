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
import '../../notifications/data/notifications_repository.dart';
import '../../places/data/places_repository.dart';
import '../../ride/application/ride_controller.dart';
import 'driver_home.dart';
import 'rider_home.dart';

/// The signed-in shell. The Home tab (rider or driver experience, based on
/// the active mode) fills the whole screen — Activity and Account live behind
/// a hamburger menu on the top right instead of eating vertical space with a
/// bottom bar, leaving room to grow the menu with more entries later.
/// Drivers can flip modes from the top switch; riders see a "become a
/// driver" nudge.
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

    // Reconcile cached data when connectivity is restored.
    ref.listen(connectivityProvider, (prev, next) {
      if (prev?.valueOrNull == false && next.valueOrNull == true) {
        ref.invalidate(myTripsProvider);
        ref.invalidate(inboxProvider);
        ref.invalidate(savedPlacesProvider);
      }
    });
    final online = ref.watch(connectivityProvider).valueOrNull ?? true;
    final gpsOff = ref.watch(locationServiceProvider).valueOrNull == false;

    final home = isDriverMode ? const DriverHome() : const RiderHome();

    return Scaffold(
      appBar: AppBar(
        title: Text(_greeting(l, auth.user)),
        actions: [
          if (auth.user?.isDriver ?? false) _ModeSwitch(mode: auth.mode),
          const _NotificationBell(),
          Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.menu_rounded),
              onPressed: () {
                Haptics.tap();
                Scaffold.of(context).openEndDrawer();
              },
            ),
          ),
        ],
      ),
      endDrawer: const _MenuDrawer(),
      body: Column(
        children: [
          if (!online) const _OfflineBar(),
          if (gpsOff) const _LocationOffBar(),
          Expanded(child: home),
        ],
      ),
    );
  }

  String _greeting(AppL10n l, AppUser? user) {
    final name = user?.fullName;
    return l.greeting(name == null || name.isEmpty ? '' : ', $name');
  }
}

/// The top-right hamburger menu: user identity up top, then the screens that
/// used to be bottom tabs, with room to grow as more sections are added.
class _MenuDrawer extends ConsumerWidget {
  const _MenuDrawer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final user = ref.watch(authControllerProvider).user;
    final scheme = Theme.of(context).colorScheme;

    void go(String route) {
      Haptics.tap();
      Navigator.of(context).pop();
      context.push(route);
    }

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(color: scheme.primaryContainer),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: scheme.primary,
                    child: Text(
                      (user?.fullName?.isNotEmpty ?? false)
                          ? user!.fullName![0].toUpperCase()
                          : '👤',
                      style: TextStyle(
                          fontSize: 20, color: scheme.onPrimary),
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
          ],
        ),
      ),
    );
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
    final unread = ref.watch(inboxProvider).valueOrNull?.unread ?? 0;
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
