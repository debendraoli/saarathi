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
  // Guards both `_startTopup` and `_checkStatus` against a double-tap firing
  // two in-flight requests — `_phase` alone doesn't catch this because both
  // methods set it to `waiting` synchronously before their first `await`,
  // and the "waiting" phase's own "Check status" button stays visible (and
  // tappable) for the whole time a confirm call is outstanding. A second tap
  // on `_startTopup` in particular would mint a brand-new idempotency key
  // and could create a second real checkout session, not just retry the
  // first one.
  bool _busy = false;

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
    if (_busy) return;
    final amount = double.tryParse(_amount.text.trim());
    if (amount == null || amount <= 0) return;
    setState(() {
      _phase = _Phase.waiting;
      _busy = true;
    });
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
        setState(() => _busy = false);
      } else {
        // Dev/mock provider (a non-http checkout_url) or the browser
        // couldn't be launched — just check immediately. `_busy` stays
        // true; `_checkStatus` clears it itself.
        await _checkStatus(internal: true);
      }
    } catch (_) {
      Haptics.error();
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _busy = false;
        });
      }
    }
  }

  /// [internal]: called from `_startTopup`, which already holds `_busy` —
  /// skips the re-entrancy guard so it doesn't block on its own caller.
  Future<void> _checkStatus({bool internal = false}) async {
    if (_busy && !internal) return;
    final intent = _intent;
    if (intent == null) return;
    setState(() {
      _phase = _Phase.waiting;
      _busy = true;
    });
    final result = await ref
        .read(currentWalletRepositoryProvider)
        .confirmTopup(intent.reference);
    if (!mounted) return;
    switch (result.status) {
      case TopupStatus.confirmed:
        Haptics.success();
        _confirmedBalance = result.balance;
        ref.invalidate(walletBalanceProvider);
        setState(() {
          _phase = _Phase.success;
          _busy = false;
        });
      case TopupStatus.pending:
        // Still not done from the provider's side — let the user check
        // again rather than polling forever in the background.
        setState(() {
          _phase = _Phase.waiting;
          _busy = false;
        });
      case TopupStatus.failed:
        Haptics.error();
        setState(() {
          _phase = _Phase.failed;
          _busy = false;
        });
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
                      onPressed: _busy ? null : _checkStatus,
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
