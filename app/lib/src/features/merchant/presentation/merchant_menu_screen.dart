import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../shared/widgets/common.dart';
import '../../marketplace/domain/models.dart';
import '../data/merchant_repository.dart';

/// Menu management for one store: list every item (available or not), toggle
/// availability, and add new items.
class MerchantMenuScreen extends ConsumerWidget {
  const MerchantMenuScreen({super.key, required this.merchant});
  final Merchant merchant;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final async = ref.watch(merchantMenuProvider(merchant.id));

    return Scaffold(
      appBar: AppBar(title: Text(merchant.name)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addItem(context, ref),
        icon: const Icon(Icons.add),
        label: Text(l.merchantAddItem),
      ),
      body: async.when(
        loading: () => const LoadingView(),
        error: (_, __) => ErrorRetry(
          message: l.errorNetwork,
          onRetry: () => ref.invalidate(merchantMenuProvider(merchant.id)),
        ),
        data: (items) {
          if (items.isEmpty) {
            return Center(child: Text(l.merchantNoItems));
          }
          return RefreshIndicator(
            onRefresh: () async =>
                ref.invalidate(merchantMenuProvider(merchant.id)),
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) =>
                  _ItemTile(item: items[i], merchantId: merchant.id),
            ),
          );
        },
      ),
    );
  }

  Future<void> _addItem(BuildContext context, WidgetRef ref) async {
    final added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AddItemSheet(merchantId: merchant.id),
    );
    if (added == true) ref.invalidate(merchantMenuProvider(merchant.id));
  }
}

class _ItemTile extends ConsumerStatefulWidget {
  const _ItemTile({required this.item, required this.merchantId});
  final MenuItem item;
  final String merchantId;

  @override
  ConsumerState<_ItemTile> createState() => _ItemTileState();
}

class _ItemTileState extends ConsumerState<_ItemTile> {
  late bool _available = widget.item.isAvailable;
  bool _busy = false;

  Future<void> _toggle(bool value) async {
    setState(() => _busy = true);
    try {
      await ref
          .read(merchantRepositoryProvider)
          .setItemAvailable(widget.item.id, value);
      if (mounted) setState(() => _available = value);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).errorNetwork)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(it.name),
      subtitle: Text(
        [
          if (it.category != null) it.category!,
          'NPR ${it.price.toStringAsFixed(2)}',
        ].join(' · '),
      ),
      trailing: _busy
          ? const SizedBox(
              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : Switch(value: _available, onChanged: _toggle),
    );
  }
}

class _AddItemSheet extends ConsumerStatefulWidget {
  const _AddItemSheet({required this.merchantId});
  final String merchantId;

  @override
  ConsumerState<_AddItemSheet> createState() => _AddItemSheetState();
}

class _AddItemSheetState extends ConsumerState<_AddItemSheet> {
  final _name = TextEditingController();
  final _price = TextEditingController();
  final _category = TextEditingController();
  final _description = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    _category.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final price = double.tryParse(_price.text.trim());
    if (name.isEmpty || price == null || price <= 0) return;
    setState(() => _busy = true);
    try {
      await ref.read(merchantRepositoryProvider).addItem(
            merchantId: widget.merchantId,
            name: name,
            price: price,
            category: _category.text.trim(),
            description: _description.text.trim(),
          );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).errorNetwork)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final media = MediaQuery.of(context);
    // Clear the keyboard (viewInsets) and the system nav bar (padding).
    final bottom = media.viewInsets.bottom + media.padding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.merchantAddItem, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: l.merchantItemName),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: l.merchantItemPrice,
              prefixText: 'NPR ',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _category,
            decoration: InputDecoration(labelText: l.merchantItemCategory),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _description,
            decoration: InputDecoration(labelText: l.merchantItemDescription),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(l.merchantAddItem),
          ),
        ],
      ),
    );
  }
}
