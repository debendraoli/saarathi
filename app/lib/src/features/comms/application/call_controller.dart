import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../auth/application/auth_controller.dart';
import '../../ride/application/ride_controller.dart' show tripStreamProvider;
import '../../ride/application/trip_channel.dart';
import '../../ride/domain/models.dart' show TripStatus;
import '../data/rtc_repository.dart';

/// `connecting` is local setup (media + peer connection) before our offer has
/// even left the device; `ringing` is after it's sent, waiting on the other
/// side. There's no signaling ack for "their phone is actually ringing" (see
/// `_onSignal`'s `offer`/`answer` cases) — `ringing` is this side's own best
/// read of "offer is out, awaiting response", not a confirmed remote state.
enum CallStatus { idle, connecting, ringing, incoming, connected, ended }

/// Peer-to-peer voice call over WebRTC (audio-only — see `_setup`). Media
/// stays P2P (Coturn TURN when direct fails); only SDP/ICE signaling is
/// relayed through the trip channel. Masked — no real phone numbers involved.
class CallController extends ChangeNotifier {
  CallController(this._channel, this._myId, this._rtc) {
    _sub = _channel.ofType('signal').listen(_onSignal);
  }

  final TripChannel _channel;
  final String? _myId;
  final RtcRepository _rtc;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Map<String, dynamic>? _pendingOffer;

  // Trickle-ICE: remote candidates that arrive before the remote description
  // is applied are queued, then flushed once it's set.
  final List<RTCIceCandidate> _queuedCandidates = [];
  bool _remoteReady = false;

  CallStatus status = CallStatus.idle;
  bool muted = false;

  /// Set the instant the peer connection reaches `connected`; drives the
  /// call screen's duration stopwatch. `null` before/after that.
  DateTime? connectedAt;

  bool get inCall =>
      status == CallStatus.connecting ||
      status == CallStatus.ringing ||
      status == CallStatus.incoming ||
      status == CallStatus.connected;

  Future<void> _setup() async {
    final iceServers = await _rtc.iceServers();
    _pc = await createPeerConnection({'iceServers': iceServers});
    // Audio-only: this is a masked voice channel between rider and driver,
    // not a video call feature — no caller has ever passed `video: true`
    // (there's no UI for it), and requesting the camera here previously
    // triggered an unwanted camera-permission prompt on every call.
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });
    for (final track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }
    _pc!.onIceCandidate = (c) {
      if (c.candidate != null) {
        _channel.sendSignal('ice', {
          'candidate': c.candidate,
          'sdpMid': c.sdpMid,
          'sdpMLineIndex': c.sdpMLineIndex,
        });
      }
    };
    _pc!.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        status = CallStatus.connected;
        connectedAt = DateTime.now();
        notifyListeners();
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _end(local: false);
      }
    };
  }

  Future<void> start() async {
    if (inCall) return;
    status = CallStatus.connecting;
    notifyListeners();
    try {
      await _setup();
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      _channel.sendSignal('offer', {'sdp': offer.sdp, 'type': offer.type});
      status = CallStatus.ringing;
      notifyListeners();
    } catch (_) {
      // Mic permission denied (first prompt or revoked since), no device
      // found, etc. — `_setup` can throw partway through, leaving a
      // half-created `_pc`/`_localStream`. Without this, `status` was left
      // stuck on `connecting` forever with no error and nothing cleaned up.
      await _end(local: true);
    }
  }

  Future<void> accept() async {
    final offer = _pendingOffer;
    if (offer == null) return;
    try {
      await _setup();
      await _pc!.setRemoteDescription(
        RTCSessionDescription(offer['sdp'] as String, offer['type'] as String),
      );
      await _flushCandidates();
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      _channel.sendSignal('answer', {'sdp': answer.sdp, 'type': answer.type});
      _pendingOffer = null;
    } catch (_) {
      await _end(local: true);
    }
  }

  Future<void> _flushCandidates() async {
    _remoteReady = true;
    for (final c in _queuedCandidates) {
      await _pc?.addCandidate(c);
    }
    _queuedCandidates.clear();
  }

  void toggleMute() {
    muted = !muted;
    for (final t
        in _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
    notifyListeners();
  }

  void hangup() => _end(local: true);

  Future<void> _onSignal(Map<String, dynamic> m) async {
    final senderId = m['sender_id'] as String?;
    if (senderId == _myId) return; // ignore our own echoed frames
    final kind = m['kind'] as String?;
    final data = m['data'];
    switch (kind) {
      case 'offer':
        if (status == CallStatus.idle) {
          _pendingOffer = (data as Map).cast<String, dynamic>();
          status = CallStatus.incoming;
          notifyListeners();
        } else if ((status == CallStatus.connecting ||
                status == CallStatus.ringing) &&
            senderId != null) {
          // Glare: both sides tapped "call" at essentially the same moment,
          // each already sent their own offer, and the `idle`-only guard
          // above silently dropped both incoming offers — the call hung in
          // "Connecting…"/"Ringing…" forever on both ends with no way out
          // but a manual hangup. Break the tie deterministically: the
          // lexicographically smaller id yields, tearing down its own
          // half-open attempt and accepting the other side's offer as an
          // ordinary incoming call; the other side (unaffected) just waits
          // for that accept's 'answer' to its still-standing offer.
          final myId = _myId ?? '';
          if (myId.compareTo(senderId) < 0) {
            await _localStream?.dispose();
            _localStream = null;
            await _pc?.close();
            _pc = null;
            _queuedCandidates.clear();
            _remoteReady = false;
            _pendingOffer = (data as Map).cast<String, dynamic>();
            status = CallStatus.incoming;
            notifyListeners();
          }
        }
      case 'answer':
        await _pc?.setRemoteDescription(
          RTCSessionDescription(data['sdp'] as String, data['type'] as String),
        );
        await _flushCandidates();
      case 'ice':
        final c = (data as Map).cast<String, dynamic>();
        final candidate = RTCIceCandidate(
          c['candidate'] as String?,
          c['sdpMid'] as String?,
          c['sdpMLineIndex'] as int?,
        );
        if (_pc != null && _remoteReady) {
          await _pc!.addCandidate(candidate);
        } else {
          _queuedCandidates.add(candidate); // apply after remote description
        }
      case 'bye':
        _end(local: false);
    }
  }

  Future<void> _end({required bool local}) async {
    if (local && status != CallStatus.idle) _channel.sendSignal('bye', {});
    await _localStream?.dispose();
    _localStream = null;
    await _pc?.close();
    _pc = null;
    _queuedCandidates.clear();
    _remoteReady = false;
    _pendingOffer = null;
    connectedAt = null;
    status = CallStatus.ended;
    notifyListeners();
  }

  Future<void> disposeAll() async {
    await _sub?.cancel();
    await _localStream?.dispose();
    await _pc?.close();
    super.dispose();
  }
}

final callControllerProvider =
    Provider.autoDispose.family<CallController, String>((
  ref,
  tripId,
) {
  final channel = ref.watch(tripChannelProvider(tripId));
  final myId = ref.read(authControllerProvider).user?.id;
  final controller =
      CallController(channel, myId, ref.read(rtcRepositoryProvider));
  // The call previously stayed fully live (media flowing, signaling
  // channel open) after the trip it belongs to was cancelled or completed
  // — neither side had anything watching trip status, so a rider/driver
  // could keep talking on a ride that no longer exists. Force a hangup the
  // moment the trip goes terminal.
  ref.listen(tripStreamProvider(tripId), (prev, next) {
    final status = next.value?.status;
    if ((status == TripStatus.cancelled || status == TripStatus.completed) &&
        controller.inCall) {
      controller.hangup();
    }
  });
  ref.onDispose(controller.disposeAll);
  return controller;
});
