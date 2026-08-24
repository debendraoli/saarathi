import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/haptics.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/domain/models.dart';
import '../../driver/data/driver_kyc_repository.dart';
import '../../driver/domain/models.dart' show KycStatus;
import '../../marketplace/domain/models.dart' show Merchant;
import '../../merchant/data/merchant_repository.dart';

class AccountTab extends ConsumerWidget {
  const AccountTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final user = ref.watch(authControllerProvider).user;
    final mode = ref.watch(authControllerProvider).mode;
    final merchants = ref.watch(myMerchantsProvider);
    final driverKyc = user?.isDriver ?? false
        ? ref.watch(driverKycProvider).valueOrNull
        : null;

    return ListView(
      // This route's Scaffold has no SafeArea, so without the extra bottom
      // inset the sign-out button (the last item) sits right under a
      // gesture/button nav bar and is barely tappable.
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
      children: [
        _ProfileHeader(
          user: user,
          isDriverMode: mode == AppMode.driver,
          driverKycApproved: driverKyc?.status == KycStatus.approved,
          onEditName: () => _editName(context, ref, user?.fullName ?? ''),
        ),
        merchants.maybeWhen(
          data: (list) => list.isEmpty
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: _MerchantCard(
                    merchant: list.firstWhere((m) => m.isApproved,
                        orElse: () => list.first),
                  ),
                ),
          orElse: () => const SizedBox.shrink(),
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.account_balance_wallet_rounded),
            title: Text(mode == AppMode.driver ? l.creditsTitle : l.walletTitle),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => context.push(Routes.wallet),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.insights_rounded),
            title: Text(l.myStatsAction),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => context.push(Routes.myStats),
          ),
        ),
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
        Card(
          child: ListTile(
            leading: const Icon(Icons.settings_rounded),
            title: Text(l.settingsTitle),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => context.push(Routes.settings),
          ),
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

/// Identity header: avatar, name, role + verified badge, phone number.
///
/// "Verified" for the base rider role just means "phone confirmed via
/// OTP" — every account in this app satisfies that by construction (there's
/// no unverified/password signup path, `POST /v1/auth/otp/verify` is the
/// only way a `users` row is ever created), so the badge shows whenever
/// [isDriverMode] is false. In driver mode it only shows once KYC is
/// actually approved — a real, separate gate, reusing the same
/// `driverKycProvider`/`KycStatus.approved` check `home_shell.dart` already
/// does for routing.
class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({
    required this.user,
    required this.isDriverMode,
    required this.driverKycApproved,
    required this.onEditName,
  });

  final AppUser? user;
  final bool isDriverMode;
  final bool driverKycApproved;
  final VoidCallback onEditName;

  bool get _verified => isDriverMode ? driverKycApproved : true;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = user?.fullName?.isNotEmpty == true
        ? user!.fullName!
        : (user?.phone ?? '');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: scheme.primaryContainer,
              child: Text(
                (user?.fullName?.isNotEmpty ?? false)
                    ? user!.fullName![0].toUpperCase()
                    : '👤',
                style: const TextStyle(fontSize: 20),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (_verified) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.verified_rounded,
                            size: 16, color: scheme.primary),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isDriverMode ? l.modeDriver : l.modeRider,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  if (user?.phone != null) ...[
                    const SizedBox(height: 2),
                    Text(user!.phone, style: theme.textTheme.bodySmall),
                  ],
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.edit_rounded),
              onPressed: onEditName,
            ),
          ],
        ),
      ),
    );
  }
}

class _MerchantCard extends StatelessWidget {
  const _MerchantCard({required this.merchant});
  final Merchant merchant;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.storefront_rounded),
        title: Row(
          children: [
            Flexible(child: Text(l.merchantStore, overflow: TextOverflow.ellipsis)),
            if (merchant.isApproved) ...[
              const SizedBox(width: 4),
              Icon(Icons.verified_rounded, size: 16, color: scheme.primary),
            ],
          ],
        ),
        subtitle: Text(l.merchantStoreSubtitle),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => context.push(Routes.merchantDashboard),
      ),
    );
  }
}
