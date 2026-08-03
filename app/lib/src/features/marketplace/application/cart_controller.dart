import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models.dart';

typedef CartLine = ({MenuItem item, int qty});

class CartState {
  const CartState({this.merchantId, this.merchantName, this.lines = const {}});

  final String? merchantId;
  final String? merchantName;
  final Map<String, CartLine> lines;

  bool get isEmpty => lines.isEmpty;
  int get count => lines.values.fold(0, (a, l) => a + l.qty);
  double get subtotal =>
      lines.values.fold(0, (a, l) => a + l.item.price * l.qty);

  Map<String, int> get orderLines =>
      {for (final e in lines.entries) e.key: e.value.qty};

  CartState copyWith({
    String? merchantId,
    String? merchantName,
    Map<String, CartLine>? lines,
  }) =>
      CartState(
        merchantId: merchantId ?? this.merchantId,
        merchantName: merchantName ?? this.merchantName,
        lines: lines ?? this.lines,
      );
}

/// A single-merchant cart. Adding an item from a different merchant replaces the
/// cart (you can only order from one place at a time).
class CartController extends Notifier<CartState> {
  @override
  CartState build() => const CartState();

  void add(MenuItem item,
      {required String merchantId, required String merchantName}) {
    final lines = state.merchantId == merchantId
        ? Map<String, CartLine>.from(state.lines)
        : <String, CartLine>{};
    final existing = lines[item.id];
    lines[item.id] = (item: item, qty: (existing?.qty ?? 0) + 1);
    state = CartState(
        merchantId: merchantId, merchantName: merchantName, lines: lines);
  }

  void decrement(String itemId) {
    final lines = Map<String, CartLine>.from(state.lines);
    final existing = lines[itemId];
    if (existing == null) return;
    if (existing.qty <= 1) {
      lines.remove(itemId);
    } else {
      lines[itemId] = (item: existing.item, qty: existing.qty - 1);
    }
    state = lines.isEmpty ? const CartState() : state.copyWith(lines: lines);
  }

  void clear() => state = const CartState();
}

final cartControllerProvider =
    NotifierProvider<CartController, CartState>(CartController.new);
