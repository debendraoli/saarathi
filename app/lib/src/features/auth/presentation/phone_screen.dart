import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:saarathi/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/common.dart';
import '../application/auth_controller.dart';
import 'otp_screen.dart';

/// E.164 for a Nepali mobile: +977 + 10 digits (starts 97/98).
String? nepaliMobileToE164(String input) {
  final digits = input.replaceAll(RegExp(r'\D'), '');
  if (RegExp(r'^9[78]\d{8}$').hasMatch(digits)) return '+977$digits';
  return null;
}

class PhoneScreen extends ConsumerStatefulWidget {
  const PhoneScreen({super.key});

  @override
  ConsumerState<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends ConsumerState<PhoneScreen> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l = AppL10n.of(context);
    final e164 = nepaliMobileToE164(_controller.text);
    if (e164 == null) {
      setState(() => _error = l.phoneInvalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final devCode = await ref.read(authControllerProvider.notifier).requestOtp(e164);
      ref.read(devOtpCodeProvider.notifier).state = devCode;
      if (mounted) context.push(Routes.otp, extra: e164);
    } catch (_) {
      setState(() => _error = l.errorNetwork);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              const BrandLogo(size: 64),
              const SizedBox(height: 40),
              Text(
                l.phoneTitle,
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                l.phoneSubtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _controller,
                keyboardType: TextInputType.phone,
                autofocus: true,
                maxLength: 10,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onSubmitted: (_) => _submit(),
                style: const TextStyle(fontSize: 20, letterSpacing: 1.5),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: l.phoneHint,
                  errorText: _error,
                  prefixIcon: const _DialCode(),
                ),
              ),
              const Spacer(),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : Text(l.sendCode),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DialCode extends StatelessWidget {
  const _DialCode();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('🇳🇵 +977',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700, color: AppTheme.ink)),
          const SizedBox(width: 8),
          Container(width: 1, height: 24, color: Theme.of(context).dividerColor),
        ],
      ),
    );
  }
}
