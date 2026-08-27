import 'package:flutter/material.dart';
import 'package:saarathi/l10n/app_localizations.dart';

class Partner {
  const Partner({
    required this.name,
    required this.panVat,
    required this.address,
    required this.contact,
  });

  final String name;
  final String panVat;
  final String address;
  final String contact;
}

// PLACEHOLDER — replace with each partner's real registered details before
// release; Nepal's digital-service disclosure rules expect PAN/VAT, a
// registered address, and a live contact number to actually be reachable,
// not filler text. Once partners are managed from the dashboard rather than
// hardcoded here, swap this for a real paginated `GET /v1/partners` fetch —
// the screen below is already built as a plain item-count `ListView.builder`
// so that swap doesn't change its structure, only where `partners` comes
// from.
const _partners = [
  Partner(
    name: 'PLACEHOLDER — Partner Pvt. Ltd.',
    panVat: 'PLACEHOLDER — 000000000',
    address: 'PLACEHOLDER — Ghorahi, Dang, Lumbini Province',
    contact: 'PLACEHOLDER — +977-00-000000',
  ),
];

/// Full list of operating/business partners — split out of the About screen
/// (which used to embed every partner's card inline) so the list scrolls on
/// its own instead of growing the About screen without bound as partners are
/// added.
class PartnersScreen extends StatelessWidget {
  const PartnersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.partnersSection)),
      body: ListView.separated(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
        itemCount: _partners.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, i) => _PartnerCard(partner: _partners[i]),
      ),
    );
  }
}

class _PartnerCard extends StatelessWidget {
  const _PartnerCard({required this.partner});
  final Partner partner;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(partner.name,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            _PartnerRow(label: l.partnerPanVat, value: partner.panVat),
            _PartnerRow(label: l.partnerAddress, value: partner.address),
            _PartnerRow(label: l.partnerContact, value: partner.contact),
          ],
        ),
      ),
    );
  }
}

class _PartnerRow extends StatelessWidget {
  const _PartnerRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(label,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.outline)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
