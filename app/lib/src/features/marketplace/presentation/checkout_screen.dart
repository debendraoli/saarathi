import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/location.dart';
import '../../../core/network/api_client.dart';
import '../../../core/router/app_router.dart';
import '../../../shared/haptics.dart';
import '../../../shared/widgets/wallet_balance_hint.dart';
import '../../places/data/places_repository.dart';
import '../../places/presentation/address_search_screen.dart';
import '../application/cart_controller.dart';
import '../data/marketplace_repository.dart';

class CheckoutScreen extends ConsumerStatefulWidget {
  const CheckoutScreen({super.key});

  @override
  ConsumerState<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends ConsumerState<CheckoutScreen> {
  final _note = TextEditingController();
  String _payment = 'cash';
  LatLng? _delivery;
  String? _deliveryLabel;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _initDelivery();
  }

  Future<void> _initDelivery() async {
    await ensureLocationPermission();
    final p = await currentLatLng();
    if (!mounted) return;
    setState(() => _delivery = p);
    // Best-effort address for the default (current) drop point.
    final hit = await ref
        .read(placesRepositoryProvider)
        .reverse(p)
        .catchError((_) => null);
    if (mounted && hit != null) setState(() => _deliveryLabel = hit.label);
  }

  Future<void> _pickDelivery() async {
    final pick = await Navigator.of(context).push<AddressPick>(
      MaterialPageRoute(
        builder: (_) => const AddressSearchScreen(allowMap: false),
      ),
    );
    if (pick?.hit == null || !mounted) return;
    setState(() {
      _delivery = pick!.hit!.point;
      _deliveryLabel = pick.hit!.label;
    });
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _placeOrder() async {
    final cart = ref.read(cartControllerProvider);
    if (cart.isEmpty || cart.merchantId == null || _delivery == null) return;
    setState(() => _busy = true);
    // One key per tap: a dropped response can safely retry same-key without
    // risking a duplicate order, but a fresh tap after a real failure gets a
    // fresh key (see newIdempotencyKey's doc).
    final idemKey = newIdempotencyKey();
    try {
      final order = await ref.read(marketplaceRepositoryProvider).placeOrder(
            merchantId: cart.merchantId!,
            lines: cart.orderLines,
            delivery: _delivery!,
            idempotencyKey: idemKey,
            note: _note.text.trim(),
            paymentMethod: _payment,
          );
      ref.read(cartControllerProvider.notifier).clear();
      Haptics.success();
      if (mounted) context.go('${Routes.order}/${order.id}');
    } on ApiException catch (e) {
      Haptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e.isNetwork ? AppL10n.of(context).errorNetwork : e.message,
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
            SnackBar(content: Text(AppL10n.of(context).errorGeneric)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final cart = ref.watch(cartControllerProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l.checkout)),
      body: cart.isEmpty
          ? Center(child: Text(l.cartEmpty))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  cart.merchantName ?? '',
                  style: Theme.of(
                    context,
                  )
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                for (final line in cart.lines.values)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Text('${line.qty}×'),
                    title: Text(line.item.name),
                    trailing: Text(
                      'NPR ${(line.item.price * line.qty).toStringAsFixed(0)}',
                    ),
                  ),
                const Divider(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(l.subtotal),
                    Text('NPR ${cart.subtotal.toStringAsFixed(0)}'),
                  ],
                ),
                Text(
                  l.deliveryFeeNote,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 16),
                Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    leading: const Icon(Icons.location_on_rounded),
                    title: Text(l.deliverTo),
                    subtitle: Text(
                      _deliveryLabel ?? l.useCurrentLocation,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.edit_location_alt_rounded),
                    onTap: _pickDelivery,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _note,
                  decoration: InputDecoration(labelText: l.deliveryNote),
                ),
                const SizedBox(height: 16),
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: 'cash',
                      icon: const Icon(Icons.payments_rounded),
                      label: Text(l.paymentCash),
                    ),
                    ButtonSegment(
                      value: 'wallet',
                      icon: const Icon(Icons.account_balance_wallet_rounded),
                      label: Text(l.paymentWallet),
                    ),
                  ],
                  selected: {_payment},
                  onSelectionChanged: (s) => setState(() => _payment = s.first),
                ),
                if (_payment == 'wallet')
                  WalletBalanceHint(amount: cart.subtotal),
              ],
            ),
      bottomNavigationBar: cart.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                  onPressed: _busy || _delivery == null ? null : _placeOrder,
                  child: _busy
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        )
                      : Text(l.placeOrder),
                ),
              ),
            ),
    );
  }
}
