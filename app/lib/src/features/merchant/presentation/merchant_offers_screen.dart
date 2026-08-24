import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../shared/haptics.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../marketplace/domain/models.dart';
import '../data/merchant_repository.dart';
import '../domain/models.dart';

/// Store-owner offer management: free delivery or a %/flat discount over a
/// minimum order amount, optionally boxed to a date range and/or a daily
/// time-of-day window. Auto-applied at checkout — nothing for the customer
/// to enter, so there's no code field here either.
class MerchantOffersScreen extends ConsumerWidget {
  const MerchantOffersScreen({super.key, required this.merchant});
  final Merchant merchant;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final async = ref.watch(merchantOffersProvider(merchant.id));

    return Scaffold(
      appBar: AppBar(title: Text(l.storeOffersTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createOffer(context, ref),
        icon: const Icon(Icons.add_rounded),
        label: Text(l.storeOfferNew),
      ),
      body: async.when(
        loading: () => const SkeletonList(),
        error: (_, __) => ErrorRetry(
          message: l.errorNetwork,
          onRetry: () => ref.invalidate(merchantOffersProvider(merchant.id)),
        ),
        data: (offers) {
          if (offers.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(l.storeOffersEmpty, textAlign: TextAlign.center),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async =>
                ref.invalidate(merchantOffersProvider(merchant.id)),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                for (final offer in offers)
                  _OfferTile(
                    offer: offer,
                    onDeactivate: offer.active
                        ? () async {
                            await ref
                                .read(merchantRepositoryProvider)
                                .deactivateOffer(merchant.id, offer.id);
                            ref.invalidate(merchantOffersProvider(merchant.id));
                          }
                        : null,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _createOffer(BuildContext context, WidgetRef ref) async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _NewOfferSheet(merchantId: merchant.id),
    );
    if (created == true) {
      ref.invalidate(merchantOffersProvider(merchant.id));
    }
  }
}

class _OfferTile extends StatelessWidget {
  const _OfferTile({required this.offer, this.onDeactivate});
  final MerchantOffer offer;
  final VoidCallback? onDeactivate;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          offer.kind == 'free_delivery'
              ? Icons.delivery_dining_rounded
              : Icons.local_offer_rounded,
          color: offer.active ? scheme.primary : scheme.outline,
        ),
        title: Text(
          offer.summaryLine,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: offer.active ? null : scheme.outline,
          ),
        ),
        subtitle: Text(
          offer.active ? l.storeOfferActive : l.storeOfferInactive,
          style: TextStyle(color: offer.active ? scheme.primary : scheme.outline),
        ),
        trailing: onDeactivate == null
            ? null
            : TextButton(
                onPressed: onDeactivate,
                child: Text(l.storeOfferDeactivate),
              ),
      ),
    );
  }
}

class _NewOfferSheet extends ConsumerStatefulWidget {
  const _NewOfferSheet({required this.merchantId});
  final String merchantId;

  @override
  ConsumerState<_NewOfferSheet> createState() => _NewOfferSheetState();
}

class _NewOfferSheetState extends ConsumerState<_NewOfferSheet> {
  String _kind = 'free_delivery';
  final _valueController = TextEditingController();
  final _maxDiscountController = TextEditingController();
  final _minOrderController = TextEditingController(text: '0');
  DateTime? _endsAt;
  bool _dailyWindow = false;
  TimeOfDay _dailyStart = const TimeOfDay(hour: 17, minute: 0);
  TimeOfDay _dailyEnd = const TimeOfDay(hour: 20, minute: 0);
  bool _submitting = false;

  @override
  void dispose() {
    _valueController.dispose();
    _maxDiscountController.dispose();
    _minOrderController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l = AppL10n.of(context);
    if (_kind != 'free_delivery' && _valueController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l.storeOfferValueRequired)));
      return;
    }
    setState(() => _submitting = true);
    try {
      await ref.read(merchantRepositoryProvider).createOffer(
            merchantId: widget.merchantId,
            kind: _kind,
            value: _kind == 'free_delivery'
                ? null
                : double.tryParse(_valueController.text.trim()),
            maxDiscount: _kind == 'percent'
                ? double.tryParse(_maxDiscountController.text.trim())
                : null,
            minOrderAmount:
                double.tryParse(_minOrderController.text.trim()) ?? 0,
            endsAt: _endsAt,
            dailyStartMinute:
                _dailyWindow ? _dailyStart.hour * 60 + _dailyStart.minute : null,
            dailyEndMinute:
                _dailyWindow ? _dailyEnd.hour * 60 + _dailyEnd.minute : null,
          );
      Haptics.success();
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      Haptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.errorNetwork)));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final media = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 8,
        bottom: media.viewInsets.bottom + media.padding.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l.storeOfferNew,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(
                  value: 'free_delivery', label: Text(l.storeOfferFreeDelivery)),
              ButtonSegment(value: 'percent', label: Text(l.storeOfferPercent)),
              ButtonSegment(value: 'flat', label: Text(l.storeOfferFlat)),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: 16),
          if (_kind != 'free_delivery') ...[
            TextField(
              controller: _valueController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: _kind == 'percent'
                    ? l.storeOfferPercentLabel
                    : l.storeOfferFlatLabel,
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (_kind == 'percent') ...[
            TextField(
              controller: _maxDiscountController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: l.storeOfferMaxDiscount),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _minOrderController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: l.storeOfferMinOrder),
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l.storeOfferEndsAt),
            subtitle: Text(_endsAt == null
                ? l.storeOfferNoEndDate
                : '${_endsAt!.year}-${_endsAt!.month.toString().padLeft(2, '0')}-${_endsAt!.day.toString().padLeft(2, '0')}'),
            trailing: TextButton(
              onPressed: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: DateTime.now().add(const Duration(days: 7)),
                  firstDate: DateTime.now(),
                  lastDate: DateTime.now().add(const Duration(days: 365)),
                );
                if (picked != null) setState(() => _endsAt = picked);
              },
              child: Text(l.storeOfferPickDate),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l.storeOfferDailyWindow),
            subtitle: Text(l.storeOfferDailyWindowBody),
            value: _dailyWindow,
            onChanged: (v) => setState(() => _dailyWindow = v),
          ),
          if (_dailyWindow) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: _dailyStart,
                      );
                      if (picked != null) setState(() => _dailyStart = picked);
                    },
                    child: Text(
                        '${l.storeOfferFrom} ${_dailyStart.format(context)}'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: _dailyEnd,
                      );
                      if (picked != null) setState(() => _dailyEnd = picked);
                    },
                    child: Text('${l.storeOfferTo} ${_dailyEnd.format(context)}'),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l.submit),
          ),
        ],
      ),
    );
  }
}
