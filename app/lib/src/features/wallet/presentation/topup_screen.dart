import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/haptics.dart';
import '../data/wallet_repository.dart';
import '../domain/models.dart';

const List<double> _presetAmounts = [200, 500, 1000, 2000];

/// Amount entry → Khalti hosted checkout (opened as an in-app browser tab,
/// no native webview dependency needed) → on return to the app, confirm.
/// `confirmTopup` is safe to call speculatively since the server always
/// re-verifies with the provider itself — so "the user came back to the
/// app" is a fine trigger, not a trust boundary.
class TopupScreen extends ConsumerStatefulWidget {
  const TopupScreen({super.key});

  @override
  ConsumerState<TopupScreen> createState() => _TopupScreenState();
}

enum _Phase { entry, waiting, success, failed }

class _TopupScreenState extends ConsumerState<TopupScreen>
    with WidgetsBindingObserver {
  final _amount = TextEditingController();
  _Phase _phase = _Phase.entry;
  TopupIntent? _intent;
  double? _confirmedBalance;
  bool _awaitingResume = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _amount.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _awaitingResume) {
      _awaitingResume = false;
      _checkStatus();
    }
  }

  Future<void> _startTopup() async {
    final amount = double.tryParse(_amount.text.trim());
    if (amount == null || amount <= 0) return;
    setState(() => _phase = _Phase.waiting);
    try {
      final intent =
          await ref.read(currentWalletRepositoryProvider).topup(amount);
      _intent = intent;
      final uri = Uri.tryParse(intent.checkoutUrl);
      var opened = false;
      if (uri != null) {
        try {
          opened = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
        } catch (_) {
          opened = false;
        }
      }
      if (!mounted) return;
      if (opened) {
        // Resume back into the app (browser closed/backgrounded) triggers
        // the confirm check — see didChangeAppLifecycleState.
        _awaitingResume = true;
      } else {
        // Dev/mock provider (a non-http checkout_url) or the browser
        // couldn't be launched — just check immediately.
        await _checkStatus();
      }
    } catch (_) {
      Haptics.error();
      if (mounted) setState(() => _phase = _Phase.failed);
    }
  }

  Future<void> _checkStatus() async {
    final intent = _intent;
    if (intent == null) return;
    setState(() => _phase = _Phase.waiting);
    final result = await ref
        .read(currentWalletRepositoryProvider)
        .confirmTopup(intent.reference);
    if (!mounted) return;
    switch (result.status) {
      case TopupStatus.confirmed:
        Haptics.success();
        _confirmedBalance = result.balance;
        ref.invalidate(walletBalanceProvider);
        setState(() => _phase = _Phase.success);
      case TopupStatus.pending:
        // Still not done from the provider's side — let the user check
        // again rather than polling forever in the background.
        setState(() => _phase = _Phase.waiting);
      case TopupStatus.failed:
        Haptics.error();
        setState(() => _phase = _Phase.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.topUp)),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: switch (_phase) {
          _Phase.entry => _EntryForm(
              controller: _amount,
              onSubmit: _startTopup,
            ),
          _Phase.waiting => _StatusView(
              icon: Icons.hourglass_top_rounded,
              title: l.topUpWaiting,
              action: _intent == null
                  ? null
                  : FilledButton(
                      onPressed: _checkStatus,
                      child: Text(l.checkPaymentStatus),
                    ),
            ),
          _Phase.success => _StatusView(
              icon: Icons.check_circle_rounded,
              iconColor: Theme.of(context).colorScheme.primary,
              title: l.topUpSuccess,
              subtitle: _confirmedBalance == null
                  ? null
                  : 'NPR ${_confirmedBalance!.toStringAsFixed(2)}',
              action: FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(l.actionDone),
              ),
            ),
          _Phase.failed => _StatusView(
              icon: Icons.error_rounded,
              iconColor: Theme.of(context).colorScheme.error,
              title: l.topUpFailed,
              action: FilledButton(
                onPressed: () => setState(() => _phase = _Phase.entry),
                child: Text(l.actionRetry),
              ),
            ),
        },
      ),
    );
  }
}

class _EntryForm extends StatelessWidget {
  const _EntryForm({required this.controller, required this.onSubmit});
  final TextEditingController controller;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: l.topUpAmount,
            prefixText: 'NPR ',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            for (final amt in _presetAmounts)
              ActionChip(
                label: Text(amt.toStringAsFixed(0)),
                onPressed: () => controller.text = amt.toStringAsFixed(0),
              ),
          ],
        ),
        const SizedBox(height: 24),
        FilledButton(onPressed: onSubmit, child: Text(l.topUpContinue)),
      ],
    );
  }
}

class _StatusView extends StatelessWidget {
  const _StatusView({
    required this.icon,
    required this.title,
    this.iconColor,
    this.subtitle,
    this.action,
  });

  final IconData icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: iconColor),
          const SizedBox(height: 16),
          Text(title, textAlign: TextAlign.center),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Text(subtitle!, style: Theme.of(context).textTheme.headlineSmall),
          ],
          if (action != null) ...[
            const SizedBox(height: 24),
            action!,
          ],
        ],
      ),
    );
  }
}
