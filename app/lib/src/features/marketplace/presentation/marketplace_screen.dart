import 'package:flutter/material.dart';
import 'package:saarathi/l10n/app_localizations.dart';

/// Food & grocery discovery. The merchant catalogue backend isn't live yet, so
/// this is an honest "launching soon in your area" state with a waitlist CTA —
/// structured so the merchant list/menu/cart slots straight in when it lands.
enum MarketplaceKind { food, grocery }

class MarketplaceScreen extends StatefulWidget {
  const MarketplaceScreen({super.key, required this.kind});
  final MarketplaceKind kind;

  @override
  State<MarketplaceScreen> createState() => _MarketplaceScreenState();
}

class _MarketplaceScreenState extends State<MarketplaceScreen> {
  bool _joined = false;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final isFood = widget.kind == MarketplaceKind.food;
    final title = isFood ? l.food : l.grocery;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 120,
                width: 120,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isFood
                      ? Icons.restaurant_rounded
                      : Icons.local_grocery_store_rounded,
                  size: 56,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 28),
              Text(
                l.comingSoonTitle,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                )
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              Text(
                l.comingSoonBody,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 28),
              if (_joined)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_rounded, color: scheme.primary),
                    const SizedBox(width: 8),
                    Text(l.waitlistJoined),
                  ],
                )
              else
                FilledButton.icon(
                  onPressed: () => setState(() => _joined = true),
                  icon: const Icon(Icons.notifications_active_rounded),
                  label: Text(l.notifyMe),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
