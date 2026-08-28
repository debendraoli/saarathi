import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/haptics.dart';
import '../application/auth_controller.dart';

/// Carries the dev-mode OTP from the request step so we can prefill it in dev.
final devOtpCodeProvider = StateProvider<String?>((ref) => null);

class OtpScreen extends ConsumerStatefulWidget {
  const OtpScreen({super.key, required this.phone});

  final String phone;

  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends ConsumerState<OtpScreen> {
  final _controller = TextEditingController();
  bool _busy = false;
  bool _resending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final dev = ref.read(devOtpCodeProvider);
    if (dev != null) _controller.text = dev;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    // The auto-submit-on-6-digits path (onChanged below) and the manual
    // button can both invoke this before a rebuild reflects `_busy` — the
    // button's own `_busy ? null : _verify` guard only matters once Flutter
    // actually rebuilds with the disabled state, not synchronously.
    if (_busy) return;
    final l = AppL10n.of(context);
    if (_controller.text.length < 4) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authControllerProvider.notifier)
          .verifyOtp(widget.phone, _controller.text.trim());
      // Router redirect takes over on success.
      Haptics.success();
    } on ApiException catch (e) {
      Haptics.error();
      setState(() => _error = e.isNetwork ? l.errorNetwork : e.message);
    } on SessionSaveException {
      Haptics.error();
      setState(() => _error = l.otpSessionSaveFailed);
    } catch (_) {
      Haptics.error();
      setState(() => _error = l.otpInvalid);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    if (_resending) return;
    final l = AppL10n.of(context);
    setState(() => _resending = true);
    try {
      final code = await ref
          .read(authControllerProvider.notifier)
          .requestOtp(widget.phone);
      if (!mounted) return;
      ref.read(devOtpCodeProvider.notifier).state = code;
      if (code != null) _controller.text = code;
    } on ApiException catch (e) {
      Haptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.isNetwork ? l.errorNetwork : e.message)),
        );
      }
    } catch (_) {
      Haptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.errorGeneric)));
      }
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final devCode = ref.watch(devOtpCodeProvider);
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l.otpTitle,
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                l.otpSubtitle(widget.phone),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 28),
              TextField(
                controller: _controller,
                keyboardType: TextInputType.number,
                autofocus: true,
                maxLength: 6,
                textAlign: TextAlign.center,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (v) {
                  if (v.length == 6) _verify();
                },
                style: const TextStyle(
                  fontSize: 30,
                  letterSpacing: 14,
                  fontWeight: FontWeight.w700,
                ),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: '••••••',
                  errorText: _error,
                ),
              ),
              if (devCode != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    l.otpDevCode(devCode),
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.tertiary),
                  ),
                ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _resending ? null : _resend,
                  child: Text(l.otpResend),
                ),
              ),
              const Spacer(),
              FilledButton(
                onPressed: _busy ? null : _verify,
                child: _busy
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : Text(l.verify),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
