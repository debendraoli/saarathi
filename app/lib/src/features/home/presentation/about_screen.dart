import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:saarathi/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

/// Update this alongside the version bump in pubspec.yaml — there's no build
/// pipeline here that stamps a real build date automatically, so it's a
/// plain manually-maintained string like the version itself.
const _releaseDate = '2026-08-26';

const _privacyPolicyUrl = 'https://saarathi.apexinfratech.com.np/legal/privacy';
const _licenseAgreementUrl = 'https://saarathi.apexinfratech.com.np/legal/terms';

class _Partner {
  const _Partner({
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
// not filler text.
const _partners = [
  _Partner(
    name: 'PLACEHOLDER — Partner Pvt. Ltd.',
    panVat: 'PLACEHOLDER — 000000000',
    address: 'PLACEHOLDER — Ghorahi, Dang, Lumbini Province',
    contact: 'PLACEHOLDER — +977-00-000000',
  ),
];

/// Version/build/release-date + the legal links Play Store review expects
/// to find surfaced somewhere in the app (Privacy Policy is a hard
/// requirement; License Agreement/Terms alongside it). Split out of
/// Settings' old inline `_AboutCard` into its own screen once it grew this
/// much content.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  PackageInfo? _info;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _info = info);
    });
  }

  Future<void> _open(String url) async {
    final l = AppL10n.of(context);
    final uri = Uri.parse(url);
    final ok = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.openInBrowserFailed)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final info = _info;
    return Scaffold(
      appBar: AppBar(title: Text(l.aboutSection)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
        children: [
          Card(
            child: Column(
              children: [
                if (info != null) ...[
                  ListTile(
                    leading: const Icon(Icons.info_outline_rounded),
                    title: Text(l.appVersion),
                    trailing:
                        Text(info.version, style: TextStyle(color: scheme.outline)),
                  ),
                  ListTile(
                    leading: const Icon(Icons.tag_rounded),
                    title: Text(l.buildNumber),
                    trailing: Text(info.buildNumber,
                        style: TextStyle(color: scheme.outline)),
                  ),
                ],
                ListTile(
                  leading: const Icon(Icons.event_rounded),
                  title: Text(l.releaseDate),
                  trailing:
                      Text(_releaseDate, style: TextStyle(color: scheme.outline)),
                ),
                ListTile(
                  leading: const Icon(Icons.apartment_rounded),
                  title: Text(l.developedBy('Apex Infratech Pvt. Ltd.')),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: Text(l.privacyPolicy),
                  trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                  onTap: () => _open(_privacyPolicyUrl),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.gavel_rounded),
                  title: Text(l.licenseAgreement),
                  trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                  onTap: () => _open(_licenseAgreementUrl),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(l.partnersSection,
                style: Theme.of(context).textTheme.titleSmall),
          ),
          for (final p in _partners) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.name,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 10),
                    _PartnerRow(label: l.partnerPanVat, value: p.panVat),
                    _PartnerRow(label: l.partnerAddress, value: p.address),
                    _PartnerRow(label: l.partnerContact, value: p.contact),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ],
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
