import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../../core/config/app_config.dart';
import '../../auth/application/auth_controller.dart';
import '../../ride/application/trip_channel.dart';

enum CallStatus { idle, calling, incoming, connected, ended }

/// Peer-to-peer voice/video call over WebRTC. Media stays P2P (Coturn TURN when
/// direct fails); only SDP/ICE signaling is relayed through the trip channel.
/// Masked — no real phone numbers involved.
class CallController extends ChangeNotifier {
  CallController(this._channel, this._myId) {
    _sub = _channel.ofType('signal').listen(_onSignal);
  }

  final TripChannel _channel;
  final String? _myId;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Map<String, dynamic>? _pendingOffer;

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
    _pc = await createPeerConnection({'iceServers': AppConfig.iceServers});
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
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    _channel.sendSignal('answer', {'sdp': answer.sdp, 'type': answer.type});
    _pendingOffer = null;
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
      case 'ice':
        final c = (data as Map).cast<String, dynamic>();
        await _pc?.addCandidate(
          RTCIceCandidate(
            c['candidate'] as String?,
            c['sdpMid'] as String?,
            c['sdpMLineIndex'] as int?,
          ),
        );
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
    Provider.autoDispose.family<CallController, String>((ref, tripId) {
  final channel = ref.watch(tripChannelProvider(tripId));
  final myId = ref.read(authControllerProvider).user?.id;
  final controller = CallController(channel, myId);
  ref.onDispose(controller.disposeAll);
  return controller;
});
