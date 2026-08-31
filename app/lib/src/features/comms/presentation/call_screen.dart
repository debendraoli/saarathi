import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../application/call_controller.dart';

class CallArgs {
  const CallArgs({required this.tripId, this.asCaller = true});
  final String tripId;
  final bool asCaller;
}

class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({super.key, required this.args});
  final CallArgs args;

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  late final CallController _c;
  Timer? _durationTicker;

  @override
  void initState() {
    super.initState();
    _c = ref.read(callControllerProvider(widget.args.tripId));
    _c.addListener(_onChange);
    if (widget.args.asCaller) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _c.start());
    }
  }

  void _onChange() {
    if (_c.status == CallStatus.ended) {
      // `_onChange` can fire synchronously from an async signal handler
      // (e.g. the remote side hanging up mid-transition), so `mounted`
      // alone isn't enough — it stays true through `deactivate()`, only
      // becoming meaningful once Flutter has resolved deactivation to
      // either disposed or reactivated on the next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
    // The stopwatch needs its own per-second tick (nothing else calls
    // notifyListeners() once a second) — started the moment we go
    // connected, stopped as soon as we leave it either way.
    if (_c.status == CallStatus.connected) {
      _durationTicker ??= Timer.periodic(
        const Duration(seconds: 1),
        (_) => mounted ? setState(() {}) : null,
      );
    } else {
      _durationTicker?.cancel();
      _durationTicker = null;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _durationTicker?.cancel();
    _c.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final incoming = _c.status == CallStatus.incoming;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 48,
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(
                    Icons.call_rounded,
                    size: 44,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 20),
                Text(_statusLabel(),
                    style: const TextStyle(color: Colors.white, fontSize: 18)),
              ],
            ),
          ),
          if (_c.status != CallStatus.idle && _c.status != CallStatus.ended)
            Positioned(
              top: 16 + MediaQuery.of(context).padding.top,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    AppL10n.of(context).callEncryptedBadge,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ),
            ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              // 48 is the intentional visual gap above the controls; the
              // system nav bar inset is added on top of that, not instead of
              // it, since it varies by device (3-button vs. gesture nav).
              padding: EdgeInsets.only(
                bottom: 48 + MediaQuery.of(context).padding.bottom,
              ),
              child: incoming
                  ? _incomingControls(scheme)
                  : _activeControls(scheme),
            ),
          ),
        ],
      ),
    );
  }

  String _statusLabel() {
    final l = AppL10n.of(context);
    switch (_c.status) {
      case CallStatus.connecting:
        return l.callStatusConnecting;
      case CallStatus.ringing:
        return l.callStatusRinging;
      case CallStatus.incoming:
        return l.callStatusIncoming;
      case CallStatus.connected:
        final d = _c.connectedAt == null
            ? Duration.zero
            : DateTime.now().difference(_c.connectedAt!);
        final mins = d.inMinutes.remainder(60).toString().padLeft(2, '0');
        final secs = d.inSeconds.remainder(60).toString().padLeft(2, '0');
        return '${l.callStatusConnected} · $mins:$secs';
      default:
        return l.callStatusEnded;
    }
  }

  Widget _incomingControls(ColorScheme scheme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _RoundBtn(
          color: scheme.error,
          icon: Icons.call_end_rounded,
          onTap: () => _c.hangup(),
        ),
        _RoundBtn(
          color: Colors.green,
          icon: Icons.call_rounded,
          onTap: () => _c.accept(),
        ),
      ],
    );
  }

  Widget _activeControls(ColorScheme scheme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _RoundBtn(
          color: _c.muted ? Colors.white24 : Colors.white30,
          icon: _c.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
          onTap: _c.toggleMute,
        ),
        const SizedBox(width: 20),
        _RoundBtn(
          color: scheme.error,
          icon: Icons.call_end_rounded,
          onTap: () => _c.hangup(),
        ),
      ],
    );
  }
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn(
      {required this.color, required this.icon, required this.onTap});
  final Color color;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        height: 64,
        width: 64,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: 28),
      ),
    );
  }
}
