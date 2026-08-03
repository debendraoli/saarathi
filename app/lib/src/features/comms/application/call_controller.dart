import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../auth/application/auth_controller.dart';
import '../../ride/application/trip_channel.dart';
import '../data/rtc_repository.dart';

enum CallStatus { idle, calling, incoming, connected, ended }

/// Peer-to-peer voice/video call over WebRTC. Media stays P2P (Coturn TURN when
/// direct fails); only SDP/ICE signaling is relayed through the trip channel.
/// Masked — no real phone numbers involved.
class CallController extends ChangeNotifier {
  CallController(this._channel, this._myId, this._rtc) {
    _sub = _channel.ofType('signal').listen(_onSignal);
  }

  final TripChannel _channel;
  final String? _myId;
  final RtcRepository _rtc;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Map<String, dynamic>? _pendingOffer;

  // Trickle-ICE: remote candidates that arrive before the remote description
  // is applied are queued, then flushed once it's set.
  final List<RTCIceCandidate> _queuedCandidates = [];
  bool _remoteReady = false;

  CallStatus status = CallStatus.idle;
  bool video = false;
  bool muted = false;

  bool get inCall =>
      status == CallStatus.calling ||
      status == CallStatus.incoming ||
      status == CallStatus.connected;

  Future<void> _ensureRenderers() async {
    if (localRenderer.textureId == null) await localRenderer.initialize();
    if (remoteRenderer.textureId == null) await remoteRenderer.initialize();
  }

  Future<void> _setup(bool withVideo) async {
    await _ensureRenderers();
    video = withVideo;
    final iceServers = await _rtc.iceServers();
    _pc = await createPeerConnection({'iceServers': iceServers});
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': withVideo ? {'facingMode': 'user'} : false,
    });
    localRenderer.srcObject = _localStream;
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
    _pc!.onTrack = (e) {
      if (e.streams.isNotEmpty) remoteRenderer.srcObject = e.streams.first;
    };
    _pc!.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        status = CallStatus.connected;
        notifyListeners();
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _end(local: false);
      }
    };
  }

  Future<void> start({required bool withVideo}) async {
    if (inCall) return;
    status = CallStatus.calling;
    notifyListeners();
    await _setup(withVideo);
    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    _channel.sendSignal('offer', {'sdp': offer.sdp, 'type': offer.type});
  }

  Future<void> accept() async {
    final offer = _pendingOffer;
    if (offer == null) return;
    await _setup(video);
    await _pc!.setRemoteDescription(
      RTCSessionDescription(offer['sdp'] as String, offer['type'] as String),
    );
    await _flushCandidates();
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    _channel.sendSignal('answer', {'sdp': answer.sdp, 'type': answer.type});
    _pendingOffer = null;
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

  Future<void> switchCamera() async {
    final tracks = _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[];
    if (tracks.isNotEmpty) await Helper.switchCamera(tracks.first);
  }

  void hangup() => _end(local: true);

  Future<void> _onSignal(Map<String, dynamic> m) async {
    if (m['sender_id'] == _myId) return; // ignore our own echoed frames
    final kind = m['kind'] as String?;
    final data = m['data'];
    switch (kind) {
      case 'offer':
        if (status == CallStatus.idle) {
          _pendingOffer = (data as Map).cast<String, dynamic>();
          video = true; // offer may carry video; accept with camera available
          status = CallStatus.incoming;
          notifyListeners();
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
    remoteRenderer.srcObject = null;
    localRenderer.srcObject = null;
    _pendingOffer = null;
    status = CallStatus.ended;
    notifyListeners();
  }

  Future<void> disposeAll() async {
    await _sub?.cancel();
    await _localStream?.dispose();
    await _pc?.close();
    await localRenderer.dispose();
    await remoteRenderer.dispose();
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
  ref.onDispose(controller.disposeAll);
  return controller;
});
