import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// غرفة اجتماع Agora RTC. التوكن قصير الصلاحية ويُصدر من Firebase Functions.
class AgoraMeetingRoom extends StatefulWidget {
  final String appId;
  final String channel;
  final String token;
  final int uid;
  final String displayName;
  final bool moderator;

  const AgoraMeetingRoom({
    super.key,
    required this.appId,
    required this.channel,
    required this.token,
    required this.uid,
    required this.displayName,
    required this.moderator,
  });

  @override
  State<AgoraMeetingRoom> createState() => _AgoraMeetingRoomState();
}

class _AgoraMeetingRoomState extends State<AgoraMeetingRoom> {
  RtcEngine? _engine;
  final Set<int> _remoteUsers = <int>{};
  bool _joined = false;
  bool _muted = false;
  bool _cameraOff = false;
  bool _speakerOn = true;
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final permissions = await [Permission.microphone, Permission.camera].request();
      if (permissions.values.any((p) => !p.isGranted)) {
        throw StateError('اسمح للتطبيق باستخدام الكاميرا والميكروفون من إعدادات الهاتف ثم أعد المحاولة.');
      }

      final engine = createAgoraRtcEngine();
      _engine = engine;
      await engine.initialize(RtcEngineContext(
        appId: widget.appId,
        channelProfile: ChannelProfileType.channelProfileCommunication,
      ));
      await engine.enableVideo();
      await engine.enableAudio();
      await engine.setClientRole(role: ClientRoleType.clientRoleBroadcaster);
      await engine.setVideoEncoderConfiguration(const VideoEncoderConfiguration(
        dimensions: VideoDimensions(width: 640, height: 360),
        frameRate: 15,
        bitrate: 0,
      ));
      engine.registerEventHandler(RtcEngineEventHandler(
        onJoinChannelSuccess: (connection, elapsed) {
          if (mounted) setState(() { _joined = true; _busy = false; });
        },
        onUserJoined: (connection, remoteUid, elapsed) {
          if (mounted) setState(() => _remoteUsers.add(remoteUid));
        },
        onUserOffline: (connection, remoteUid, reason) {
          if (mounted) setState(() => _remoteUsers.remove(remoteUid));
        },
        onError: (err, msg) {
          if (mounted) setState(() { _error = 'خطأ Agora: $err ${msg ?? ''}'; _busy = false; });
        },
        onLeaveChannel: (connection, stats) {
          if (mounted) setState(() { _joined = false; _remoteUsers.clear(); });
        },
      ));
      await engine.startPreview();
      await engine.joinChannel(
        token: widget.token,
        channelId: widget.channel,
        uid: widget.uid,
        options: const ChannelMediaOptions(
          channelProfile: ChannelProfileType.channelProfileCommunication,
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
          publishCameraTrack: true,
          publishMicrophoneTrack: true,
          autoSubscribeAudio: true,
          autoSubscribeVideo: true,
        ),
      );
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _busy = false; });
    }
  }

  Future<void> _leave() async {
    try { await _engine?.leaveChannel(); } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    final engine = _engine;
    if (engine != null) {
      engine.leaveChannel();
      engine.stopPreview();
      engine.release();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engine = _engine;
    return Scaffold(
      backgroundColor: const Color(0xFF101318),
      appBar: AppBar(
        backgroundColor: const Color(0xFF171B22),
        foregroundColor: Colors.white,
        title: const Text('محاضرة مباشرة'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(child: Text(_joined ? 'متصل' : 'جارٍ الاتصال')),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: _remoteUsers.isNotEmpty && engine != null
                        ? AgoraVideoView(
                            controller: VideoViewController.remote(
                              rtcEngine: engine,
                              canvas: VideoCanvas(uid: _remoteUsers.first),
                              connection: RtcConnection(channelId: widget.channel),
                            ),
                          )
                        : Container(
                            alignment: Alignment.center,
                            color: const Color(0xFF202631),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.people_alt_outlined, size: 64, color: Colors.white54),
                                const SizedBox(height: 12),
                                Text(
                                  _joined ? 'أنت داخل الغرفة — في انتظار الطرف الآخر' : 'جارٍ الاتصال بغرفة المحاضرة',
                                  style: const TextStyle(color: Colors.white, fontSize: 16),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                  ),
                  if (engine != null)
                    Positioned(
                      right: 16,
                      top: 16,
                      width: 120,
                      height: 170,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: _cameraOff
                            ? Container(color: Colors.black87, child: const Icon(Icons.videocam_off, color: Colors.white))
                            : AgoraVideoView(
                                controller: VideoViewController(
                                  rtcEngine: engine,
                                  canvas: const VideoCanvas(uid: 0),
                                ),
                              ),
                      ),
                    ),
                  if (_busy)
                    const Positioned.fill(child: Center(child: CircularProgressIndicator())),
                  if (_error != null)
                    Positioned(
                      left: 16, right: 16, bottom: 16,
                      child: Material(
                        color: const Color(0xFF7F1D1D),
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(_error!, style: const TextStyle(color: Colors.white)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _control(
                    icon: _muted ? Icons.mic_off : Icons.mic,
                    label: _muted ? 'تشغيل المايك' : 'كتم المايك',
                    onTap: () async {
                      setState(() => _muted = !_muted);
                      await engine?.muteLocalAudioStream(_muted);
                    },
                  ),
                  _control(
                    icon: _cameraOff ? Icons.videocam_off : Icons.videocam,
                    label: _cameraOff ? 'فتح الكاميرا' : 'إيقاف الكاميرا',
                    onTap: () async {
                      setState(() => _cameraOff = !_cameraOff);
                      await engine?.muteLocalVideoStream(_cameraOff);
                    },
                  ),
                  _control(
                    icon: _speakerOn ? Icons.volume_up : Icons.hearing,
                    label: _speakerOn ? 'السماعة' : 'سماعة الهاتف',
                    onTap: () async {
                      setState(() => _speakerOn = !_speakerOn);
                      await engine?.setEnableSpeakerphone(_speakerOn);
                    },
                  ),
                  _control(
                    icon: Icons.call_end,
                    label: 'إنهاء',
                    color: const Color(0xFFDC2626),
                    onTap: _leave,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _control({
    required IconData icon,
    required String label,
    required Future<void> Function() onTap,
    Color color = const Color(0xFF303744),
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filled(
          onPressed: () => onTap(),
          style: IconButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white, fixedSize: const Size(54, 54)),
          icon: Icon(icon),
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
      ],
    );
  }
}
