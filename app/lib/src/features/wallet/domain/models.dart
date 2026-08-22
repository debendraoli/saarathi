class WalletTxn {
  const WalletTxn({
    required this.type,
    required this.amount,
    this.balanceAfter,
    this.reference,
    this.createdAt,
  });

  final String type;
  final double amount;
  final double? balanceAfter;
  final String? reference;
  final DateTime? createdAt;

  factory WalletTxn.fromJson(Map<String, dynamic> j) => WalletTxn(
        type: (j['txn_type'] as String?) ?? '',
        amount: double.tryParse('${j['amount']}') ?? 0,
        balanceAfter: j['balance_after'] == null
            ? null
            : double.tryParse('${j['balance_after']}'),
        reference: j['reference'] as String?,
        createdAt: DateTime.tryParse((j['created_at'] as String?) ?? ''),
      );
}

/// Credit balance + recent activity. Riders get a transaction history from
/// the backend; drivers currently only get a balance (see
/// GET /v1/driver/credits) — [transactions] is empty in that case.
class WalletBalance {
  const WalletBalance({required this.balance, this.transactions = const []});

  final double balance;
  final List<WalletTxn> transactions;

  factory WalletBalance.fromJson(Map<String, dynamic> j) => WalletBalance(
        balance: double.tryParse('${j['balance']}') ?? 0,
        transactions: (j['transactions'] as List?)
                ?.cast<Map<String, dynamic>>()
                .map(WalletTxn.fromJson)
                .toList() ??
            const [],
      );
}

/// A top-up in progress: the provider reference (Khalti's `pidx`) and the
/// hosted checkout URL to send the user to.
class TopupIntent {
  const TopupIntent({required this.reference, required this.checkoutUrl});

  final String reference;
  final String checkoutUrl;

  factory TopupIntent.fromJson(Map<String, dynamic> j) => TopupIntent(
        reference: j['reference'] as String,
        checkoutUrl: j['checkout_url'] as String,
      );
}

enum TopupStatus { confirmed, pending, failed }

class TopupResult {
  const TopupResult(this.status, {this.balance});
  final TopupStatus status;
  final double? balance;

  factory TopupResult.fromJson(Map<String, dynamic> j) {
    if (j['confirmed'] == true) {
      final bal = j['balance'];
      return TopupResult(
        TopupStatus.confirmed,
        balance: bal == null ? null : double.tryParse('$bal'),
      );
    }
    return const TopupResult(TopupStatus.pending);
  }
}
