import 'package:flutter/material.dart';
import 'package:saarathi/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_controller.dart';
import '../../auth/domain/models.dart';
import 'account_tab.dart';
import 'driver_home.dart';
import 'rider_home.dart';

/// The signed-in shell. Bottom tabs (Home / Activity / Account); the Home tab
/// shows the rider or driver experience based on the active mode. Drivers can
/// flip modes from the top switch; riders see a "become a driver" nudge.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final auth = ref.watch(authControllerProvider);
    final isDriverMode = auth.mode == AppMode.driver;

    final home = isDriverMode ? const DriverHome() : const RiderHome();
    final body = [home, const _ActivityTab(), const AccountTab()][_tab];

    return Scaffold(
      appBar: AppBar(
        title: Text(_greeting(l, auth.user)),
        actions: [
          if (auth.user?.isDriver ?? false) _ModeSwitch(mode: auth.mode),
          const SizedBox(width: 8),
        ],
      ),
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.home_outlined),
            selectedIcon: const Icon(Icons.home_rounded),
            label: l.tabHome,
          ),
          NavigationDestination(
            icon: const Icon(Icons.receipt_long_outlined),
            selectedIcon: const Icon(Icons.receipt_long_rounded),
            label: l.tabActivity,
          ),
          NavigationDestination(
            icon: const Icon(Icons.person_outline_rounded),
            selectedIcon: const Icon(Icons.person_rounded),
            label: l.tabAccount,
          ),
        ],
      ),
    );
  }

  String _greeting(AppL10n l, AppUser? user) {
    final name = user?.fullName;
    return l.greeting(name == null || name.isEmpty ? '' : ', $name');
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

class _ActivityTab extends StatelessWidget {
  const _ActivityTab();

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.receipt_long_rounded,
              size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(l.tabActivity),
        ],
      ),
    );
  }
}
