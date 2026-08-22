import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/foreground/driver_foreground_service.dart';
import '../../../core/notifications/push_service.dart';
import '../../../core/prefs.dart';
import '../../../core/router/app_router.dart';
import '../../../shared/haptics.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/domain/models.dart';
import '../../merchant/data/merchant_repository.dart';

class AccountTab extends ConsumerWidget {
  const AccountTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final user = ref.watch(authControllerProvider).user;
    final locale = ref.watch(localeControllerProvider);
    final merchants = ref.watch(myMerchantsProvider);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.all(12),
            leading: CircleAvatar(
              radius: 26,
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Text(
                (user?.fullName?.isNotEmpty ?? false)
                    ? user!.fullName![0].toUpperCase()
                    : '👤',
                style: const TextStyle(fontSize: 20),
              ),
            ),
            title: Text(
              user?.fullName?.isNotEmpty == true
                  ? user!.fullName!
                  : (user?.phone ?? ''),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(user?.phone ?? ''),
            trailing: IconButton(
              icon: const Icon(Icons.edit_rounded),
              onPressed: () => _editName(context, ref, user?.fullName ?? ''),
            ),
          ),
        ),
        const _NotificationPermissionCard(),
        merchants.maybeWhen(
          data: (list) => list.isEmpty
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Card(
                    child: ListTile(
                      leading: const Icon(Icons.storefront_rounded),
                      title: Text(l.merchantStore),
                      subtitle: Text(l.merchantStoreSubtitle),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => context.push(Routes.merchantDashboard),
                    ),
                  ),
                ),
          orElse: () => const SizedBox.shrink(),
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.account_balance_wallet_rounded),
            title: Text(ref.watch(authControllerProvider).mode == AppMode.driver
                ? l.creditsTitle
                : l.walletTitle),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => context.push(Routes.wallet),
          ),
        ),
        // Only relevant to roles that need to keep *receiving* things while
        // backgrounded — a driver's job offers, a merchant's incoming orders.
        // A plain rider has nothing that needs the app alive in the
        // background, so the section would just be confusing noise for them.
        if ((user?.isDriver ?? false) ||
            (merchants.valueOrNull?.isNotEmpty ?? false)) ...[
          const SizedBox(height: 16),
          const _BackgroundRunningCard(),
        ],
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.bookmark_rounded),
            title: Text(l.savedPlaces),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => context.push(Routes.savedPlaces),
          ),
        ),
        const SizedBox(height: 16),
        Text(l.chooseLanguage, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'en', label: Text(l.languageEnglish)),
            ButtonSegment(value: 'ne', label: Text(l.languageNepali)),
          ],
          selected: {locale?.languageCode ?? 'en'},
          onSelectionChanged: (s) =>
              ref.read(localeControllerProvider.notifier).set(Locale(s.first)),
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: () {
            Haptics.warning();
            ref.read(authControllerProvider.notifier).signOut();
          },
          icon: const Icon(Icons.logout_rounded),
          label: const Text('Sign out'),
        ),
      ],
    );
  }

  Future<void> _editName(
      BuildContext context, WidgetRef ref, String current) async {
    final controller = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(AppL10n.of(context).editName),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(hintText: AppL10n.of(context).yourName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppL10n.of(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(AppL10n.of(context).saveAction),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await ref.read(authControllerProvider.notifier).updateName(name);
    }
  }
}

/// Surfaces a denied OS notification permission — otherwise every push and
/// local notification (driver arriving, order approved, …) is silently
/// dropped with nothing in the UI to explain why. Hidden entirely once
/// granted; only action available is "open settings" since re-requesting
/// from inside the app is a no-op after the first denial on both Android 13+
/// and iOS.
class _NotificationPermissionCard extends StatefulWidget {
  const _NotificationPermissionCard();

  @override
  State<_NotificationPermissionCard> createState() =>
      _NotificationPermissionCardState();
}

class _NotificationPermissionCardState
    extends State<_NotificationPermissionCard> with WidgetsBindingObserver {
  bool _granted = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from the system settings screen — pick up the new value.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    await PushService.instance.refreshPermissionStatus();
    if (mounted) setState(() => _granted = PushService.instance.permissionGranted);
  }

  @override
  Widget build(BuildContext context) {
    if (_granted) return const SizedBox.shrink();
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        color: scheme.errorContainer,
        child: ListTile(
          contentPadding: const EdgeInsets.all(12),
          leading: Icon(Icons.notifications_off_rounded,
              color: scheme.onErrorContainer),
          title: Text(
            l.notificationsOffTitle,
            style: TextStyle(
                fontWeight: FontWeight.w700, color: scheme.onErrorContainer),
          ),
          subtitle: Text(l.notificationsOffBody,
              style: TextStyle(color: scheme.onErrorContainer)),
          trailing: TextButton(
            onPressed: () {
              Haptics.tap();
              PushService.instance.openSettings();
            },
            child: Text(l.enable),
          ),
        ),
      ),
    );
  }
}

/// Lets a driver grant the battery-optimisation exemption ahead of time (not
/// just from the online card) so the sticky "receiving offers" notification
/// and background heartbeat survive Android's Doze/App Standby. There's no
/// iOS equivalent setting — the OS decides background execution itself — so
/// iOS just gets an explanatory note instead of a dead button.
class _BackgroundRunningCard extends StatefulWidget {
  const _BackgroundRunningCard();

  @override
  State<_BackgroundRunningCard> createState() => _BackgroundRunningCardState();
}

class _BackgroundRunningCardState extends State<_BackgroundRunningCard>
    with WidgetsBindingObserver {
  bool? _ignoringOptimizations;
  bool _serviceRunning = false;
  bool _serviceBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from the system settings screen — pick up the new value.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    if (kIsWeb || !Platform.isAndroid) return;
    final ignoring = await DriverForegroundService.isBatteryOptimizationIgnored;
    final running = await DriverForegroundService.isRunning;
    if (mounted) {
      setState(() {
        _ignoringOptimizations = ignoring;
        _serviceRunning = running;
      });
    }
  }

  Future<void> _toggleService(bool value) async {
    setState(() => _serviceBusy = true);
    Haptics.tap();
    if (value) {
      await DriverForegroundService.start();
    } else {
      await DriverForegroundService.stop();
    }
    if (mounted) setState(() => _serviceBusy = false);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final isAndroid = !kIsWeb && Platform.isAndroid;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.notifications_active_rounded, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(l.backgroundRunning,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(l.backgroundRunningBody,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            if (isAndroid) ...[
              Row(
                children: [
                  Icon(
                    _ignoringOptimizations == true
                        ? Icons.check_circle_rounded
                        : Icons.error_outline_rounded,
                    size: 18,
                    color: _ignoringOptimizations == true
                        ? scheme.primary
                        : scheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _ignoringOptimizations == true
                          ? l.batteryExclusionActive
                          : l.batteryExclusionInactive,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              if (_ignoringOptimizations != true) ...[
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () async {
                    Haptics.tap();
                    await DriverForegroundService.requestBatteryExclusion();
                    await _refresh();
                  },
                  child: Text(l.batteryExclusion),
                ),
              ],
              const Divider(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l.stickyNotification,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        Text(l.stickyNotificationBody,
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _serviceBusy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.2),
                        )
                      : Switch(
                          value: _serviceRunning,
                          onChanged: _toggleService,
                        ),
                ],
              ),
            ] else
              Text(l.batteryExclusionIosNote,
                  style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
