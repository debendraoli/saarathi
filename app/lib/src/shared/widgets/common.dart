import 'package:flutter/material.dart';
import 'package:saarathi/l10n/app_localizations.dart';

/// Brand mark: the real Saarathi icon (same source render as the launcher
/// icon's foreground layer) + name. Used on the login screen.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.size = 72, this.showName = true});

  final double size;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          'assets/images/app_icon_foreground.png',
          height: size,
          width: size,
        ),
        if (showName) ...[
          const SizedBox(height: 12),
          Text(
            AppL10n.of(context).appName,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
        ],
      ],
    );
  }
}

/// Full-screen centered spinner.
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.label});
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (label != null) ...[
            const SizedBox(height: 16),
            Text(label!, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}

/// Inline error with a retry affordance.
class ErrorRetry extends StatelessWidget {
  const ErrorRetry({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.wifi_off_rounded,
              size: 40,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }
}

/// Slim inline banner for a screen whose live data is stale because the most
/// recent background refresh failed — used instead of [ErrorRetry] wherever
/// a `resilientPoll`-backed provider has a last-known value to keep showing.
/// The poll loop is already retrying on its own, so there's nothing to tap;
/// this just says "what you're looking at might be a few seconds behind"
/// without blanking the screen the way a full error state would.
class StaleBanner extends StatelessWidget {
  const StaleBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi_off_rounded,
              size: 16, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              AppL10n.of(context).connectionIssueRetrying,
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown whenever the device has no network at all, on screens where a
/// floating icon control already sits over the map (matching that same
/// small-circle style) — distinct from [StaleBanner]'s "a background poll
/// failed" case, this is for screens where connectivity itself (not just
/// one poll) affects what's on screen: the active-trip map's live position/
/// route can silently go stale with no network to refresh them. A pulsing
/// icon, not a full-width bar — the earlier full-width version sat overtop
/// the map and read as intrusive; this reads as one more status control
/// among the others already there. Tapping it surfaces the same explanatory
/// text home_shell shows elsewhere, so "offline" reads consistently
/// app-wide without needing to spell it out permanently on screen.
class OfflineBanner extends StatefulWidget {
  const OfflineBanner({super.key});

  @override
  State<OfflineBanner> createState() => _OfflineBannerState();
}

class _OfflineBannerState extends State<OfflineBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);
  late final Animation<double> _scale =
      Tween<double>(begin: 0.85, end: 1.15).animate(
    CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
  );

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.error,
      shape: const CircleBorder(),
      elevation: 2,
      child: IconButton(
        tooltip: AppL10n.of(context).offlineBanner,
        onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).offlineBanner)),
        ),
        icon: ScaleTransition(
          scale: _scale,
          child: Icon(Icons.wifi_off_rounded, color: scheme.onError),
        ),
      ),
    );
  }
}
