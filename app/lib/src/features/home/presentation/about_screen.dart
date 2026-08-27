import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:saarathi/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/router/app_router.dart';

/// Update this alongside the version bump in pubspec.yaml — there's no build
/// pipeline here that stamps a real build date automatically, so it's a
/// plain manually-maintained string like the version itself.
const _releaseDate = '2026-08-26';

const _privacyPolicyUrl = 'https://saarathi.apexinfratech.com.np/legal/privacy';
const _licenseAgreementUrl = 'https://saarathi.apexinfratech.com.np/legal/terms';

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
          Card(
            child: ListTile(
              leading: const Icon(Icons.handshake_outlined),
              title: Text(l.partnersSection),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push(Routes.partners),
            ),
          ),
        ],
      ),
    );
  }
}
