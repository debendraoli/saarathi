import 'package:flutter/material.dart';

/// Shown while the session is being restored (auth status == unknown). The
/// router redirects away automatically once bootstrap resolves.
///
/// The logo fades + scales in once, then settles into a slow, gentle breathe
/// (not a spinner) — reads as "the app is alive and working" without the
/// harsher, more mechanical feel of a circular progress indicator.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..forward();
  late final _entranceCurve =
      CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic);

  late final _breathe = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void initState() {
    super.initState();
    // Start the idle breathing loop only once the entrance has settled, so
    // the two animations never visually fight each other.
    _entrance.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _breathe.repeat(reverse: true);
      }
    });
  }

  @override
  void dispose() {
    _entrance.dispose();
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: AnimatedBuilder(
          animation: Listenable.merge([_entrance, _breathe]),
          builder: (context, child) {
            final entranceScale = 0.85 + (0.15 * _entranceCurve.value);
            final breatheScale = 1.0 + (0.035 * _breathe.value);
            return Opacity(
              opacity: _entranceCurve.value,
              child: Transform.scale(
                scale: entranceScale * breatheScale,
                child: child,
              ),
            );
          },
          child: Image.asset(
            'assets/images/splash_logo.png',
            width: 240,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}
