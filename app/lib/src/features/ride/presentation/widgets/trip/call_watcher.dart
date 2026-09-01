import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../../core/router/app_router.dart';
import '../../../../comms/application/call_controller.dart';
import '../../../../comms/presentation/call_screen.dart';

/// Watches for an incoming WebRTC call and opens the call screen to answer.
class CallWatcher extends ConsumerStatefulWidget {
  const CallWatcher({super.key, required this.tripId});
  final String tripId;

  @override
  ConsumerState<CallWatcher> createState() => _CallWatcherState();
}

class _CallWatcherState extends ConsumerState<CallWatcher> {
  CallController? _controller;
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(callControllerProvider(widget.tripId));
    _controller!.addListener(_check);
  }

  Future<void> _check() async {
    if (_open) return;
    if (_controller!.status == CallStatus.incoming) {
      _open = true;
      await context.push(
        Routes.call,
        extra: CallArgs(tripId: widget.tripId, asCaller: false),
      );
      _open = false;
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_check);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watch to keep the call controller (and its signaling) alive.
    ref.watch(callControllerProvider(widget.tripId));
    return const SizedBox.shrink();
  }
}
