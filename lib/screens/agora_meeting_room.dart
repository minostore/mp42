import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import '../services/media_upload.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pdfx/pdfx.dart';
import 'package:permission_handler/permission_handler.dart';

/// غرفة اجتماع Agora RTC بشكل مكالمة عادية.
/// - المايك والكاميرا مقفولين عند الدخول، والمستخدم يفتحهم بنفسه.
/// - المدرّس (moderator) يقدر: يشارك الشاشة، يفتح السبورة التفاعلية، ويشارك ملف (PDF/صورة) للطلبة.
/// - السبورة والملفات بتتبعت للطلبة عن طريق Agora data stream (بدون أي خادم إضافي).
class AgoraMeetingRoom extends StatefulWidget {
  final String appId;
  final String channel;
  final String token;
  final int uid;
  final String displayName;
  final bool moderator;
  // اجتماع مجموعة: نراقب وجود الجلسة (إن حُذفت عند إنهائها يُخرَج الجميع)، والمدير ينهيها للجميع
  final String? groupId;
  final String? sessionId;
  final Future<void> Function()? onEndForAll;

  const AgoraMeetingRoom({
    super.key,
    required this.appId,
    required this.channel,
    required this.token,
    required this.uid,
    required this.displayName,
    required this.moderator,
    this.groupId,
    this.sessionId,
    this.onEndForAll,
  });

  @override
  State<AgoraMeetingRoom> createState() => _AgoraMeetingRoomState();
}

class _Stroke {
  final Color color;
  final double width;
  final List<Offset> points; // مُطبَّعة 0..1
  _Stroke(this.color, this.width, [List<Offset>? pts]) : points = pts ?? [];
}

class _AgoraMeetingRoomState extends State<AgoraMeetingRoom> {
  static const _boardColors = <Color>[Colors.black, Color(0xFFEF4444), Color(0xFF29B6F6), Color(0xFF22C55E), Color(0xFFFF7043)];

  RtcEngine? _engine;
  final Set<int> _remoteUsers = <int>{};
  bool _joined = false;
  bool _muted = true; // مقفول افتراضيًا
  bool _cameraOff = true; // مقفولة افتراضيًا
  bool _speakerOn = true;
  bool _sharingScreen = false;
  bool _busy = true;
  String? _error;

  // data stream
  int? _streamId;

  // أسماء المتصلين (كل مشارك يرسل اسمه عبر data stream) + مراقبة وجود الجلسة
  final Map<int, String> _names = {};
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sessionSub;
  bool _closing = false;

  // السبورة
  bool _boardOpen = false;
  final List<_Stroke> _strokes = [];
  _Stroke? _current;
  int _colorIndex = 0;
  final List<Offset> _pendingPoints = [];
  Timer? _flushTimer;

  // الملف المشارَك
  String? _fileName;
  String? _fileKind; // pdf | img
  String? _fileUrl;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _initialize();
    _watchSession();
  }

  void _watchSession() {
    final g = widget.groupId, s = widget.sessionId;
    if (g == null || s == null) return;
    _sessionSub = FirebaseFirestore.instance.collection('groups').doc(g).collection('sessions').doc(s).snapshots().listen((snap) {
      if (!snap.exists && snap.metadata.isFromCache) return; // لا نعتبرها انتهت بسبب نسخة محلية قديمة
      final live = snap.exists && (snap.data()?['status'] ?? 'live') == 'live';
      if (!live && mounted && !_closing) {
        if (!widget.moderator) _toast('أنهى مدير الاجتماع هذه الجلسة');
        _leave();
      }
    }, onError: (_) {});
  }

  void _sendHello() => _send({'t': 'n', 'n': widget.displayName});

  Future<void> _initialize() async {
    try {
      // الصلاحيات تُطلب فقط عند فتح المايك/الكاميرا أول مرة، لكن نطلب المايك الآن
      // عشان الاستماع/التحدث يشتغل بدون مفاجآت بعد ما المستخدم يفتحه.
      final engine = createAgoraRtcEngine();
      _engine = engine;
      await engine.initialize(RtcEngineContext(
        appId: widget.appId,
        channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
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
        onJoinChannelSuccess: (connection, elapsed) async {
          if (mounted) setState(() { _joined = true; _busy = false; });
          try {
            _streamId = await engine.createDataStream(const DataStreamConfig(syncWithAudio: false, ordered: true));
            _sendHello();
          } catch (_) {}
        },
        onUserJoined: (connection, remoteUid, elapsed) {
          if (mounted) setState(() => _remoteUsers.add(remoteUid));
          _sendHello(); // يعرّف المنضم الجديد باسمي
          // المدرّس يعيد إرسال حالة السبورة/الملف للمنضم الجديد
          if (widget.moderator) {
            if (_boardOpen) _send({'t': 'b', 'o': 1});
            if (_fileUrl != null) _send({'t': 'f', 'u': _fileUrl, 'n': _fileName, 'k': _fileKind});
          }
        },
        onUserOffline: (connection, remoteUid, reason) {
          if (mounted) setState(() { _remoteUsers.remove(remoteUid); _names.remove(remoteUid); });
        },
        onStreamMessage: (connection, remoteUid, streamId, data, length, sentTs) {
          _onData(data, remoteUid);
        },
        onError: (err, msg) {
          String text = 'خطأ Agora: $err ${msg ?? ''}';
          if (err == ErrorCodeType.errInvalidToken) {
            text = 'ERR_INVALID_TOKEN: التوكن غير صالح. غالبًا AGORA_APP_ID أو AGORA_APP_CERTIFICATE في Firebase Functions من مشروع Agora مختلف، أو الشهادة اتغيّرت. راجعهم وأعد نشر الدوال.';
          } else if (err == ErrorCodeType.errTokenExpired) {
            text = 'انتهت صلاحية التوكن. اخرج وادخل المحاضرة من جديد.';
          }
          if (mounted) setState(() { _error = text; _busy = false; });
        },
        onConnectionStateChanged: (connection, state, reason) {
          if (reason == ConnectionChangedReasonType.connectionChangedInvalidToken && mounted) {
            setState(() {
              _error = 'التوكن مرفوض من Agora (Invalid Token). تأكد إن App ID والـ Certificate لنفس المشروع.';
              _busy = false;
            });
          }
        },
        onLeaveChannel: (connection, stats) {
          if (mounted) setState(() { _joined = false; _remoteUsers.clear(); });
        },
      ));
      // الدخول بدون نشر مايك أو كاميرا
      await engine.joinChannel(
        token: widget.token,
        channelId: widget.channel,
        uid: widget.uid,
        options: const ChannelMediaOptions(
          channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
          publishCameraTrack: false,
          publishMicrophoneTrack: false,
          autoSubscribeAudio: true,
          autoSubscribeVideo: true,
        ),
      );
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _busy = false; });
    }
  }

  // ===== المايك والكاميرا (المستخدم يفتحهم بنفسه) =====
  Future<void> _toggleMic() async {
    final engine = _engine;
    if (engine == null) return;
    if (_muted) {
      final st = await Permission.microphone.request();
      if (!st.isGranted) { _toast('اسمح للتطبيق باستخدام الميكروفون من إعدادات الهاتف'); return; }
      await engine.enableLocalAudio(true);
      await engine.updateChannelMediaOptions(const ChannelMediaOptions(publishMicrophoneTrack: true));
    } else {
      await engine.updateChannelMediaOptions(const ChannelMediaOptions(publishMicrophoneTrack: false));
    }
    if (mounted) setState(() => _muted = !_muted);
  }

  Future<void> _toggleCamera() async {
    final engine = _engine;
    if (engine == null) return;
    if (_sharingScreen) { _toast('أوقف مشاركة الشاشة أولًا'); return; }
    if (_cameraOff) {
      final st = await Permission.camera.request();
      if (!st.isGranted) { _toast('اسمح للتطبيق باستخدام الكاميرا من إعدادات الهاتف'); return; }
      await engine.enableLocalVideo(true);
      await engine.startPreview();
      await engine.updateChannelMediaOptions(const ChannelMediaOptions(publishCameraTrack: true));
    } else {
      await engine.updateChannelMediaOptions(const ChannelMediaOptions(publishCameraTrack: false));
      await engine.stopPreview();
    }
    if (mounted) setState(() => _cameraOff = !_cameraOff);
  }

  // ===== مشاركة الشاشة =====
  Future<void> _toggleScreenShare() async {
    final engine = _engine;
    if (engine == null) return;
    try {
      if (!_sharingScreen) {
        await engine.startScreenCapture(const ScreenCaptureParameters2(
          captureAudio: true,
          captureVideo: true,
          videoParams: ScreenVideoParameters(
            dimensions: VideoDimensions(width: 1280, height: 720),
            frameRate: 15,
            bitrate: 0,
          ),
        ));
        await engine.updateChannelMediaOptions(const ChannelMediaOptions(
          publishScreenCaptureVideo: true,
          publishScreenCaptureAudio: true,
          publishCameraTrack: false,
        ));
        if (mounted) setState(() => _sharingScreen = true);
      } else {
        await engine.stopScreenCapture();
        await engine.updateChannelMediaOptions(ChannelMediaOptions(
          publishScreenCaptureVideo: false,
          publishScreenCaptureAudio: false,
          publishCameraTrack: !_cameraOff,
        ));
        if (mounted) setState(() => _sharingScreen = false);
      }
    } catch (e) {
      _toast('تعذرت مشاركة الشاشة: $e');
    }
  }

  // ===== data stream =====
  void _send(Map<String, dynamic> msg) {
    final engine = _engine;
    final id = _streamId;
    if (engine == null || id == null) return;
    try {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(msg)));
      if (bytes.length > 1000) return; // حد Agora 1KB للرسالة
      engine.sendStreamMessage(streamId: id, data: bytes, length: bytes.length);
    } catch (_) {}
  }

  void _onData(Uint8List data, int fromUid) {
    try {
      final m = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      switch (m['t']) {
        case 'n': // اسم مشارك
          if (!mounted) return;
          setState(() => _names[fromUid] = (m['n'] ?? '').toString());
          break;
        case 'b': // فتح/غلق السبورة
          if (!mounted) return;
          setState(() {
            _boardOpen = m['o'] == 1;
            if (!_boardOpen) { _strokes.clear(); }
          });
          break;
        case 's': // جزء من خط
          final pts = (m['p'] as List).cast<num>();
          final id = m['i'] as int;
          if (!mounted) return;
          setState(() {
            _Stroke? st = _remoteStrokes[id];
            if (st == null) {
              st = _Stroke(_boardColors[(m['c'] as int).clamp(0, _boardColors.length - 1)], (m['w'] as num).toDouble());
              _remoteStrokes[id] = st;
              _strokes.add(st);
            }
            for (var i = 0; i + 1 < pts.length; i += 2) {
              st.points.add(Offset(pts[i].toDouble(), pts[i + 1].toDouble()));
            }
          });
          break;
        case 'x': // مسح السبورة
          if (!mounted) return;
          setState(() { _strokes.clear(); _remoteStrokes.clear(); });
          break;
        case 'f': // ملف مشارَك
          if (!mounted) return;
          setState(() { _fileUrl = m['u'] as String; _fileName = (m['n'] ?? '') as String; _fileKind = (m['k'] ?? 'pdf') as String; });
          break;
        case 'fc': // إغلاق الملف
          if (!mounted) return;
          setState(() { _fileUrl = null; _fileName = null; _fileKind = null; });
          break;
      }
    } catch (_) {}
  }

  final Map<int, _Stroke> _remoteStrokes = {};
  int _strokeSeq = 0;

  // ===== السبورة (رسم المدرّس) =====
  void _openBoard() {
    setState(() => _boardOpen = true);
    _send({'t': 'b', 'o': 1});
  }

  void _closeBoard() {
    setState(() { _boardOpen = false; _strokes.clear(); _remoteStrokes.clear(); });
    _send({'t': 'b', 'o': 0});
  }

  void _clearBoard() {
    setState(() { _strokes.clear(); _remoteStrokes.clear(); });
    _send({'t': 'x'});
  }

  void _flushPending() {
    if (_pendingPoints.isEmpty) return;
    final pts = <double>[];
    for (final p in _pendingPoints) {
      pts..add(double.parse(p.dx.toStringAsFixed(3)))..add(double.parse(p.dy.toStringAsFixed(3)));
    }
    _pendingPoints.clear();
    _send({'t': 's', 'i': _strokeSeq, 'c': _colorIndex, 'w': 3, 'p': pts});
  }

  void _panStart(Offset local, Size size) {
    if (!widget.moderator) return;
    _strokeSeq++;
    final pt = Offset(local.dx / size.width, local.dy / size.height);
    _current = _Stroke(_boardColors[_colorIndex], 3, [pt]);
    _pendingPoints.add(pt);
    setState(() => _strokes.add(_current!));
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      // لا نتجاوز ~40 نقطة في الرسالة الواحدة
      while (_pendingPoints.length > 40) {
        final chunk = _pendingPoints.sublist(0, 40);
        _pendingPoints.removeRange(0, 40);
        final keep = List<Offset>.from(_pendingPoints);
        _pendingPoints..clear()..addAll(chunk);
        _flushPending();
        _pendingPoints.addAll(keep);
      }
      _flushPending();
    });
  }

  void _panUpdate(Offset local, Size size) {
    final c = _current;
    if (!widget.moderator || c == null) return;
    final pt = Offset((local.dx / size.width).clamp(0.0, 1.0), (local.dy / size.height).clamp(0.0, 1.0));
    c.points.add(pt);
    _pendingPoints.add(pt);
    setState(() {});
  }

  void _panEnd() {
    _flushTimer?.cancel();
    _flushPending();
    _current = null;
  }

  // ===== مشاركة ملف =====
  Future<void> _shareFile() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf', 'png', 'jpg', 'jpeg'],
        withData: true,
      );
      if (res == null || res.files.isEmpty) return;
      final f = res.files.first;
      final bytes = f.bytes;
      if (bytes == null) { _toast('تعذرت قراءة الملف'); return; }
      setState(() => _uploading = true);
      final ext = (f.extension ?? '').toLowerCase();
      final kind = ext == 'pdf' ? 'pdf' : 'img';
      final safeName = f.name.replaceAll(RegExp(r'[^\w\.\-\u0600-\u06FF]'), '_');
      final ctype = kind == 'pdf' ? 'application/pdf' : (ext == 'png' ? 'image/png' : 'image/jpeg');
      final url = await MediaUpload.uploadBytes(kind: 'meeting', bytes: bytes, fileName: safeName, contentType: ctype, channel: widget.channel);
      final shortName = f.name.length > 40 ? f.name.substring(0, 40) : f.name;
      setState(() { _fileUrl = url; _fileName = shortName; _fileKind = kind; _uploading = false; });
      _send({'t': 'f', 'u': url, 'n': shortName, 'k': kind});
    } catch (e) {
      if (mounted) setState(() => _uploading = false);
      _toast('تعذرت مشاركة الملف: $e');
    }
  }

  void _closeFile() {
    setState(() { _fileUrl = null; _fileName = null; _fileKind = null; });
    _send({'t': 'fc'});
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _leave() async {
    if (_closing) return;
    _closing = true;
    try { await _engine?.leaveChannel(); } catch (_) {}
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  /// زر الإنهاء: المدير يختار بين المغادرة فقط وإنهاء الاجتماع للجميع (يُحذف من المجموعة ويُخرَج الكل).
  Future<void> _endPressed() async {
    if (!widget.moderator || widget.onEndForAll == null) return _leave();
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إنهاء الاجتماع'),
        content: const Text('إنهاء الاجتماع للجميع سيخرج كل المتصلين ويحذف الجلسة من المجموعة عند الكل.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('إلغاء')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'leave'), child: const Text('مغادرة فقط')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)), onPressed: () => Navigator.pop(ctx, 'end'), child: const Text('إنهاء للجميع')),
        ],
      ),
    );
    if (choice == 'leave') return _leave();
    if (choice == 'end') {
      try {
        await widget.onEndForAll!();
      } catch (e) {
        _toast('تعذر إنهاء الاجتماع: $e');
        return;
      }
      await _leave();
    }
  }

  /// قائمة المتصلين (لمدير الاجتماع).
  void _showParticipants() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF171B22),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(12),
          children: [
            Text('المتصلون الآن (${_remoteUsers.length + 1})', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 8),
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text('${widget.displayName} (أنت)', style: const TextStyle(color: Colors.white)),
            ),
            for (final u in _remoteUsers)
              ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                title: Text((_names[u] ?? '').isEmpty ? 'مشارك' : _names[u]!, style: const TextStyle(color: Colors.white)),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _sessionSub?.cancel();
    _flushTimer?.cancel();
    final engine = _engine;
    if (engine != null) {
      if (_sharingScreen) { engine.stopScreenCapture(); }
      engine.leaveChannel();
      engine.stopPreview();
      engine.release();
    }
    super.dispose();
  }

  // ===================== الواجهة =====================
  @override
  Widget build(BuildContext context) {
    final engine = _engine;
    return Scaffold(
      backgroundColor: const Color(0xFF101318),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: _remoteGrid(engine)),
            // الشريط العلوي
            Positioned(
              top: 0, left: 0, right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black54, Colors.transparent])),
                child: Row(
                  children: [
                    const Icon(Icons.lock, size: 14, color: Colors.white70),
                    const SizedBox(width: 6),
                    Text(_joined ? 'متصل • ${_remoteUsers.length + 1} مشارك' : 'جارٍ الاتصال...', style: const TextStyle(color: Colors.white, fontSize: 13)),
                  ],
                ),
              ),
            ),
            // معاينة الكاميرا الشخصية
            if (engine != null && !_cameraOff && !_sharingScreen)
              Positioned(
                right: 16, top: 56, width: 110, height: 150,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: AgoraVideoView(controller: VideoViewController(rtcEngine: engine, canvas: const VideoCanvas(uid: 0))),
                ),
              ),
            if (_sharingScreen)
              Positioned(
                left: 16, right: 16, top: 56,
                child: Material(
                  color: const Color(0xFF1D4ED8),
                  borderRadius: BorderRadius.circular(12),
                  child: const Padding(padding: EdgeInsets.all(10), child: Text('أنت تشارك شاشتك الآن', style: TextStyle(color: Colors.white), textAlign: TextAlign.center)),
                ),
              ),
            if (_busy) const Positioned.fill(child: Center(child: CircularProgressIndicator())),
            if (_uploading)
              const Positioned.fill(child: ColoredBox(color: Colors.black54, child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 10), Text('جارٍ رفع الملف...', style: TextStyle(color: Colors.white))])))),
            if (_error != null)
              Positioned(
                left: 16, right: 16, bottom: 130,
                child: Material(
                  color: const Color(0xFF7F1D1D),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: const TextStyle(color: Colors.white))),
                ),
              ),
            // الملف المشارَك (فوق الفيديو)
            if (_fileUrl != null) Positioned.fill(child: _sharedFileViewer()),
            // السبورة (فوق الفيديو)
            if (_boardOpen) Positioned.fill(child: _boardView()),
            // شريط التحكم السفلي
            Positioned(left: 0, right: 0, bottom: 0, child: _controlBar()),
          ],
        ),
      ),
    );
  }

  Widget _controlBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 18),
      decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black87, Colors.transparent])),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _control(icon: _muted ? Icons.mic_off : Icons.mic, label: _muted ? 'فتح المايك' : 'كتم المايك', active: !_muted, onTap: _toggleMic),
          _control(icon: _cameraOff ? Icons.videocam_off : Icons.videocam, label: _cameraOff ? 'فتح الكاميرا' : 'إيقاف الكاميرا', active: !_cameraOff, onTap: _toggleCamera),
          _control(icon: _speakerOn ? Icons.volume_up : Icons.hearing, label: _speakerOn ? 'السماعة' : 'الأذن', onTap: () async {
            setState(() => _speakerOn = !_speakerOn);
            await _engine?.setEnableSpeakerphone(_speakerOn);
          }),
          if (widget.moderator) _control(icon: _sharingScreen ? Icons.stop_screen_share : Icons.screen_share, label: _sharingScreen ? 'إيقاف المشاركة' : 'مشاركة الشاشة', active: _sharingScreen, onTap: _toggleScreenShare),
          if (widget.moderator) _control(icon: Icons.people, label: 'المتصلون', onTap: () async => _showParticipants()),
          if (widget.moderator) _control(icon: Icons.add_circle_outline, label: 'المزيد', onTap: () async => _showTools()),
          _control(icon: Icons.call_end, label: 'إنهاء', color: const Color(0xFFDC2626), onTap: _endPressed),
        ],
      ),
    );
  }

  void _showTools() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF171B22),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(_sharingScreen ? Icons.stop_screen_share : Icons.screen_share, color: Colors.white),
              title: Text(_sharingScreen ? 'إيقاف مشاركة الشاشة' : 'مشاركة الشاشة', style: const TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(ctx); _toggleScreenShare(); },
            ),
            ListTile(
              leading: const Icon(Icons.draw, color: Colors.white),
              title: Text(_boardOpen ? 'إغلاق السبورة' : 'السبورة التفاعلية', style: const TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(ctx); _boardOpen ? _closeBoard() : _openBoard(); },
            ),
            ListTile(
              leading: const Icon(Icons.attach_file, color: Colors.white),
              title: Text(_fileUrl == null ? 'مشاركة ملف للطلبة' : 'إيقاف عرض الملف', style: const TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(ctx); _fileUrl == null ? _shareFile() : _closeFile(); },
            ),
          ],
        ),
      ),
    );
  }

  Widget _boardView() {
    return Container(
      color: Colors.white,
      child: Column(
        children: [
          Container(
            color: const Color(0xFF171B22),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                const Text('السبورة', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                const Spacer(),
                if (widget.moderator) ...[
                  for (var i = 0; i < _boardColors.length; i++)
                    GestureDetector(
                      onTap: () => setState(() => _colorIndex = i),
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: 22, height: 22,
                        decoration: BoxDecoration(color: _boardColors[i], shape: BoxShape.circle, border: Border.all(color: _colorIndex == i ? Colors.white : Colors.white24, width: 2)),
                      ),
                    ),
                  IconButton(onPressed: _clearBoard, icon: const Icon(Icons.delete_outline, color: Colors.white), tooltip: 'مسح'),
                  IconButton(onPressed: _closeBoard, icon: const Icon(Icons.close, color: Colors.white), tooltip: 'إغلاق'),
                ],
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                final size = Size(c.maxWidth, c.maxHeight);
                return GestureDetector(
                  onPanStart: (d) => _panStart(d.localPosition, size),
                  onPanUpdate: (d) => _panUpdate(d.localPosition, size),
                  onPanEnd: (_) => _panEnd(),
                  child: CustomPaint(size: size, painter: _BoardPainter(_strokes), child: const SizedBox.expand()),
                );
              },
            ),
          ),
          const SizedBox(height: 90), // مساحة شريط التحكم
        ],
      ),
    );
  }

  Widget _sharedFileViewer() {
    final url = _fileUrl!;
    return Container(
      color: const Color(0xFF0B0E13),
      child: Column(
        children: [
          Container(
            color: const Color(0xFF171B22),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                const Icon(Icons.insert_drive_file, color: Colors.white70, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(_fileName ?? 'ملف مشارَك', style: const TextStyle(color: Colors.white), overflow: TextOverflow.ellipsis)),
                if (widget.moderator) IconButton(onPressed: _closeFile, icon: const Icon(Icons.close, color: Colors.white)),
              ],
            ),
          ),
          Expanded(
            child: _fileKind == 'img'
                ? InteractiveViewer(child: Center(child: Image.network(url, fit: BoxFit.contain)))
                : _SharedPdfView(key: ValueKey(url), url: url),
          ),
          const SizedBox(height: 90),
        ],
      ),
    );
  }

  Widget _remoteGrid(RtcEngine? engine) {
    if (engine == null || _remoteUsers.isEmpty) {
      return Container(
        alignment: Alignment.center,
        color: const Color(0xFF202631),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircleAvatar(radius: 44, backgroundColor: Color(0xFF303744), child: Icon(Icons.person, size: 48, color: Colors.white54)),
            const SizedBox(height: 14),
            Text(
              _joined ? 'في انتظار باقي المشاركين' : 'جارٍ الاتصال بغرفة المحاضرة',
              style: const TextStyle(color: Colors.white, fontSize: 16),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    final users = _remoteUsers.toList();
    Widget tile(int uid) => ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: AgoraVideoView(
            controller: VideoViewController.remote(
              rtcEngine: engine,
              canvas: VideoCanvas(uid: uid),
              connection: RtcConnection(channelId: widget.channel),
            ),
          ),
        );
    if (users.length == 1) return tile(users.first);
    final cols = users.length <= 4 ? 2 : 3;
    return GridView.count(
      crossAxisCount: cols,
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 110),
      children: users.map(tile).toList(),
    );
  }

  Widget _control({
    required IconData icon,
    required String label,
    required Future<void> Function() onTap,
    Color color = const Color(0xFF303744),
    bool active = false,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filled(
          onPressed: () => onTap(),
          style: IconButton.styleFrom(
            backgroundColor: active ? Colors.white : color,
            foregroundColor: active ? Colors.black : Colors.white,
            fixedSize: const Size(46, 46),
          ),
          icon: Icon(icon),
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 10)),
      ],
    );
  }
}

class _BoardPainter extends CustomPainter {
  final List<_Stroke> strokes;
  _BoardPainter(this.strokes);

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      final paint = Paint()
        ..color = s.color
        ..strokeWidth = s.width
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      if (s.points.length == 1) {
        canvas.drawCircle(Offset(s.points.first.dx * size.width, s.points.first.dy * size.height), s.width / 2, paint..style = PaintingStyle.fill);
        continue;
      }
      final path = Path()..moveTo(s.points.first.dx * size.width, s.points.first.dy * size.height);
      for (final p in s.points.skip(1)) {
        path.lineTo(p.dx * size.width, p.dy * size.height);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BoardPainter old) => true;
}

class _SharedPdfView extends StatefulWidget {
  final String url;
  const _SharedPdfView({super.key, required this.url});

  @override
  State<_SharedPdfView> createState() => _SharedPdfViewState();
}

class _SharedPdfViewState extends State<_SharedPdfView> {
  PdfControllerPinch? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await http.get(Uri.parse(widget.url));
      if (r.statusCode != 200) throw StateError('HTTP ${r.statusCode}');
      final controller = PdfControllerPinch(document: PdfDocument.openData(r.bodyBytes));
      if (!mounted) { controller.dispose(); return; }
      setState(() => _controller = controller);
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذر عرض الملف: $e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!, style: const TextStyle(color: Colors.white)));
    final c = _controller;
    if (c == null) return const Center(child: CircularProgressIndicator());
    return PdfViewPinch(controller: c);
  }
}
