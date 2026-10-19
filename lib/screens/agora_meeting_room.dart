import '../widgets/moving_watermark.dart';
import 'dart:async';
import '../widgets/smart_image.dart';
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
  // الجلسة مسجّلة؟ لو نعم يُحفظ سجل الشات مع التسجيل عند إنهاء الاجتماع للجميع
  final bool record;
  final Future<void> Function(List<Map<String, dynamic>> messages)? onSaveChat;

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
    this.record = false,
    this.onSaveChat,
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

class _ChatMsg {
  final String name;
  final String text;
  final int atMs;
  final bool mine;
  _ChatMsg(this.name, this.text, this.atMs, this.mine);
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

  // المستند المشارَك: صفحة حالية متزامنة + أقلام/تحديد/ممحاة فوقه (نفس أدوات السبورة)
  int _docPage = 0;
  int _docPageCount = 1;
  final Map<int, List<_Stroke>> _pageStash = {};
  bool _highlight = false;

  // الممحاة (مسح جزء من السبورة)
  bool _eraser = false;
  DateTime _lastEraseSend = DateTime.fromMillisecondsSinceEpoch(0);
  static const double _eraseRadius = 0.035;

  // كتم المشاركين (يتحكم به من بدأ الاجتماع فقط)
  int? _modUid; // Agora uid الخاص بمدير الاجتماع (من رسالة التعريف)
  final Set<int> _modMuted = <int>{}; // عند المدير: من كتمهم
  bool _forceMuted = false; // عند الطالب: كتمه المدير

  // الشات الداخلي (يبقى في الذاكرة فقط ويختفي بانتهاء الاجتماع)
  final List<_ChatMsg> _chat = [];
  final _chatC = TextEditingController();
  final _chatScroll = ScrollController();
  bool _chatOpen = false;
  int _unread = 0;

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

  void _sendHello() => _send({'t': 'n', 'n': widget.displayName, 'mod': widget.moderator ? 1 : 0});

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
            for (final u in _modMuted) { _send({'t': 'm', 'to': u, 'v': 1}); }
            if (_boardOpen) _send({'t': 'b', 'o': 1});
            if (_fileUrl != null) { _send({'t': 'f', 'u': _fileUrl, 'n': _fileName, 'k': _fileKind}); _send({'t': 'g', 'p': _docPage}); }
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
    if (_muted && _forceMuted) { _toast('كتم مدير الاجتماع صوتك'); return; }
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
        case 'n': // اسم مشارك (+ هل هو مدير الاجتماع)
          if (!mounted) return;
          setState(() {
            _names[fromUid] = (m['n'] ?? '').toString();
            if (m['mod'] == 1) _modUid = fromUid;
          });
          break;
        case 'm': // أمر كتم/إلغاء كتم من مدير الاجتماع لمشارك محدد
          if (m['to'] != widget.uid || fromUid != _modUid) return;
          _applyForcedMute(m['v'] == 1);
          break;
        case 'e': // ممحاة على السبورة
          if (!mounted) return;
          setState(() => _eraseAt(Offset((m['x'] as num).toDouble(), (m['y'] as num).toDouble()), (m['r'] as num).toDouble()));
          break;
        case 'c': // رسالة شات
          if (!mounted) return;
          final txt = (m['x'] ?? '').toString();
          if (txt.trim().isEmpty) return;
          setState(() {
            _chat.add(_ChatMsg((m['n'] ?? _names[fromUid] ?? 'مشارك').toString(), txt, DateTime.now().millisecondsSinceEpoch, false));
            if (!_chatOpen) _unread++;
          });
          _scrollChatDown();
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
              final base = _boardColors[(m['c'] as int).clamp(0, _boardColors.length - 1)];
              st = _Stroke(m['h'] == 1 ? base.withOpacity(.38) : base, (m['w'] as num).toDouble());
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
          setState(() {
            final isNew = _fileUrl != m['u'];
            _fileUrl = m['u'] as String; _fileName = (m['n'] ?? '') as String; _fileKind = (m['k'] ?? 'pdf') as String;
            if (isNew) { _strokes.clear(); _remoteStrokes.clear(); _pageStash.clear(); _docPage = 0; }
          });
          break;
        case 'fc': // إغلاق الملف
          if (!mounted) return;
          setState(() { _fileUrl = null; _fileName = null; _fileKind = null; _strokes.clear(); _remoteStrokes.clear(); _pageStash.clear(); _docPage = 0; });
          break;
        case 'g': // تغيير صفحة المستند (من المدير)
          if (!mounted) return;
          setState(() => _switchPage((m['p'] as num).toInt()));
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
    setState(() { _boardOpen = false; _eraser = false; _strokes.clear(); _remoteStrokes.clear(); });
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
    _send({'t': 's', 'i': _strokeSeq, 'c': _colorIndex, 'w': _highlight ? 18 : 3, 'h': _highlight ? 1 : 0, 'p': pts});
  }

  void _panStart(Offset local, Size size) {
    if (!widget.moderator) return;
    _strokeSeq++;
    final pt = Offset(local.dx / size.width, local.dy / size.height);
    _current = _Stroke(_highlight ? _boardColors[_colorIndex].withOpacity(.38) : _boardColors[_colorIndex], _highlight ? 18 : 3, [pt]);
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

  // ===== الممحاة: تمسح الجزء الذي تمر عليه فقط (تقسّم الخط) =====
  static double _segDist(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 == 0) return (p - a).distance;
    var t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / len2;
    t = t.clamp(0.0, 1.0);
    final proj = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
    return (p - proj).distance;
  }

  /// يحذف أجزاء الخطوط القريبة من النقطة p (إحداثيات مُطبَّعة 0..1).
  void _eraseAt(Offset p, double r) {
    final out = <_Stroke>[];
    for (final s in _strokes) {
      final pts = s.points;
      if (pts.length == 1) {
        if ((pts.first - p).distance >= r) out.add(s);
        continue;
      }
      var cur = <Offset>[];
      void flush() {
        if (cur.length >= 2) out.add(_Stroke(s.color, s.width, cur));
        cur = <Offset>[];
      }
      for (var i = 0; i + 1 < pts.length; i++) {
        if (_segDist(p, pts[i], pts[i + 1]) >= r) {
          if (cur.isEmpty) cur.add(pts[i]);
          cur.add(pts[i + 1]);
        } else {
          flush();
        }
      }
      flush();
    }
    _strokes
      ..clear()
      ..addAll(out);
    _remoteStrokes.clear(); // الخطوط الجديدة لها كائنات جديدة
  }

  void _eraseLocal(Offset local, Size size) {
    final p = Offset((local.dx / size.width).clamp(0.0, 1.0), (local.dy / size.height).clamp(0.0, 1.0));
    setState(() => _eraseAt(p, _eraseRadius));
    final now = DateTime.now();
    if (now.difference(_lastEraseSend).inMilliseconds >= 35) {
      _lastEraseSend = now;
      _send({'t': 'e', 'x': double.parse(p.dx.toStringAsFixed(3)), 'y': double.parse(p.dy.toStringAsFixed(3)), 'r': _eraseRadius});
    }
  }

  // ===== كتم المشاركين =====
  void _toggleMuteStudent(int uid) {
    final nowMuted = !_modMuted.contains(uid);
    setState(() { nowMuted ? _modMuted.add(uid) : _modMuted.remove(uid); });
    _send({'t': 'm', 'to': uid, 'v': nowMuted ? 1 : 0});
  }

  Future<void> _applyForcedMute(bool mute) async {
    if (!mounted) return;
    if (mute) {
      _forceMuted = true;
      if (!_muted) {
        try { await _engine?.updateChannelMediaOptions(const ChannelMediaOptions(publishMicrophoneTrack: false)); } catch (_) {}
        if (mounted) setState(() => _muted = true);
      }
      _toast('كتم مدير الاجتماع صوتك');
    } else {
      _forceMuted = false;
      _toast('سمح لك مدير الاجتماع بفتح المايك');
    }
  }

  // ===== الشات الداخلي =====
  void _scrollChatDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) _chatScroll.jumpTo(_chatScroll.position.maxScrollExtent);
    });
  }

  void _sendChat() {
    var text = _chatC.text.trim();
    if (text.isEmpty) return;
    if (text.length > 240) text = text.substring(0, 240); // حد Agora 1KB للرسالة
    _chatC.clear();
    setState(() => _chat.add(_ChatMsg(widget.displayName, text, DateTime.now().millisecondsSinceEpoch, true)));
    _send({'t': 'c', 'n': widget.displayName, 'x': text});
    _scrollChatDown();
  }

  void _openChat() {
    setState(() { _chatOpen = true; _unread = 0; });
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF171B22),
      builder: (ctx) => _ChatSheet(
        messages: _chat,
        controller: _chatC,
        scroll: _chatScroll,
        onSend: _sendChat,
        recordedNote: widget.record,
      ),
    ).whenComplete(() { if (mounted) setState(() { _chatOpen = false; _unread = 0; }); });
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
      setState(() { _fileUrl = url; _fileName = shortName; _fileKind = kind; _uploading = false; _strokes.clear(); _remoteStrokes.clear(); _pageStash.clear(); _docPage = 0; _docPageCount = 1; });
      _send({'t': 'f', 'u': url, 'n': shortName, 'k': kind});
    } catch (e) {
      if (mounted) setState(() => _uploading = false);
      _toast('تعذرت مشاركة الملف: $e');
    }
  }

  /// تبديل صفحة المستند مع حفظ رسومات كل صفحة.
  void _switchPage(int p) {
    if (p < 0 || p == _docPage) return;
    _pageStash[_docPage] = List<_Stroke>.of(_strokes);
    _strokes..clear()..addAll(_pageStash[p] ?? const <_Stroke>[]);
    _remoteStrokes.clear();
    _docPage = p;
  }

  void _goPage(int p) {
    if (!widget.moderator) return;
    final max = _docPageCount - 1;
    final np = p.clamp(0, max < 0 ? 0 : max);
    if (np == _docPage) return;
    setState(() => _switchPage(np));
    _send({'t': 'g', 'p': np});
  }

  void _closeFile() {
    setState(() { _fileUrl = null; _fileName = null; _fileKind = null; _strokes.clear(); _remoteStrokes.clear(); _pageStash.clear(); _docPage = 0; _eraser = false; });
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
      // الجلسة المسجلة: يُحفظ الشات مع التسجيل ليظهر لمن يشاهد الجلسة المسجلة
      if (widget.record && widget.onSaveChat != null && _chat.isNotEmpty) {
        try {
          await widget.onSaveChat!([
            for (final c in _chat) {'n': c.name, 'x': c.text, 'at': c.atMs},
          ]);
        } catch (_) {}
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
              StatefulBuilder(
                builder: (ctx, setRow) => ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                  title: Text((_names[u] ?? '').isEmpty ? 'مشارك' : _names[u]!, style: const TextStyle(color: Colors.white)),
                  trailing: widget.moderator
                      ? TextButton.icon(
                          onPressed: () { _toggleMuteStudent(u); setRow(() {}); },
                          icon: Icon(_modMuted.contains(u) ? Icons.mic_off : Icons.mic, size: 18, color: _modMuted.contains(u) ? const Color(0xFFEF4444) : const Color(0xFF22C55E)),
                          label: Text(_modMuted.contains(u) ? 'إلغاء الكتم' : 'كتم', style: TextStyle(color: _modMuted.contains(u) ? const Color(0xFFEF4444) : const Color(0xFF22C55E))),
                        )
                      : null,
                ),
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
    _chatC.dispose();
    _chatScroll.dispose();
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
            // علامة مائية متحركة (IP + الهاتف + البريد) وأيقونة فهمت أعلى اليمين
            const Positioned.fill(child: MovingWatermark()),
            const Positioned(top: 8, right: 12, child: FahmtLogoBadge(size: 30)),
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
      child: Center(
        child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _control(icon: _muted ? Icons.mic_off : Icons.mic, label: _forceMuted ? 'مكتوم' : (_muted ? 'فتح المايك' : 'كتم المايك'), active: !_muted, onTap: _toggleMic),
          _control(icon: _cameraOff ? Icons.videocam_off : Icons.videocam, label: _cameraOff ? 'فتح الكاميرا' : 'إيقاف الكاميرا', active: !_cameraOff, onTap: _toggleCamera),
          _control(icon: _speakerOn ? Icons.volume_up : Icons.hearing, label: _speakerOn ? 'السماعة' : 'الأذن', onTap: () async {
            setState(() => _speakerOn = !_speakerOn);
            await _engine?.setEnableSpeakerphone(_speakerOn);
          }),
          if (widget.moderator) _control(icon: _sharingScreen ? Icons.stop_screen_share : Icons.screen_share, label: _sharingScreen ? 'إيقاف المشاركة' : 'مشاركة الشاشة', active: _sharingScreen, onTap: _toggleScreenShare),
          _control(icon: Icons.chat_bubble_outline, label: _unread > 0 ? 'الشات ($_unread)' : 'الشات', active: _unread > 0, onTap: () async => _openChat()),
          if (widget.moderator) _control(icon: Icons.people, label: 'المتصلون', onTap: () async => _showParticipants()),
          if (widget.moderator) _control(icon: Icons.add_circle_outline, label: 'المزيد', onTap: () async => _showTools()),
          _control(icon: Icons.call_end, label: 'إنهاء', color: const Color(0xFFDC2626), onTap: _endPressed),
        ].expand((w) => [w, const SizedBox(width: 14)]).toList()..removeLast(),
      ),
      ),
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

  /// أقلام/تحديد/ممحاة/مسح — تُستخدم في السبورة وفي المستند المشارَك (للمدير فقط).
  List<Widget> _toolButtons() => [
        for (var i = 0; i < _boardColors.length; i++)
          GestureDetector(
            onTap: () => setState(() { _colorIndex = i; _eraser = false; }),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: 20, height: 20,
              decoration: BoxDecoration(color: _boardColors[i], shape: BoxShape.circle, border: Border.all(color: (_colorIndex == i && !_eraser) ? Colors.white : Colors.white24, width: 2)),
            ),
          ),
        IconButton(
          onPressed: () => setState(() { _highlight = !_highlight; _eraser = false; }),
          icon: Icon(Icons.highlight, color: _highlight ? const Color(0xFFFBBF24) : Colors.white),
          tooltip: 'تحديد (هايلايتر)',
        ),
        IconButton(
          onPressed: () => setState(() => _eraser = !_eraser),
          icon: Icon(Icons.cleaning_services, color: _eraser ? const Color(0xFFFBBF24) : Colors.white),
          tooltip: _eraser ? 'إيقاف الممحاة' : 'ممحاة (تمسح جزءًا محددًا)',
        ),
        IconButton(onPressed: _clearBoard, icon: const Icon(Icons.delete_outline, color: Colors.white), tooltip: 'مسح كل الرسومات'),
      ];

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
                  ..._toolButtons(),
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
                  onPanStart: (d) => (_eraser && widget.moderator) ? _eraseLocal(d.localPosition, size) : _panStart(d.localPosition, size),
                  onPanUpdate: (d) => (_eraser && widget.moderator) ? _eraseLocal(d.localPosition, size) : _panUpdate(d.localPosition, size),
                  onPanEnd: (_) => (_eraser && widget.moderator) ? null : _panEnd(),
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
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Icon(Icons.insert_drive_file, color: Colors.white70, size: 18),
                  const SizedBox(width: 6),
                  ConstrainedBox(constraints: const BoxConstraints(maxWidth: 110), child: Text(_fileName ?? 'ملف', style: const TextStyle(color: Colors.white, fontSize: 12), overflow: TextOverflow.ellipsis)),
                  if (widget.moderator) ..._toolButtons(),
                  if (widget.moderator) IconButton(onPressed: _closeFile, icon: const Icon(Icons.close, color: Colors.white), tooltip: 'إيقاف عرض الملف'),
                ],
              ),
            ),
          ),
          Expanded(
            child: _SharedDocView(
              key: ValueKey(url),
              url: url,
              isPdf: _fileKind != 'img',
              page: _docPage,
              strokes: _strokes,
              canDraw: widget.moderator,
              eraser: _eraser,
              onPageCount: (n) { if (n != _docPageCount) setState(() => _docPageCount = n); },
              onPanStart: (p, size) => _eraser ? _eraseLocal(p, size) : _panStart(p, size),
              onPanUpdate: (p, size) => _eraser ? _eraseLocal(p, size) : _panUpdate(p, size),
              onPanEnd: () { if (!_eraser) _panEnd(); },
            ),
          ),
          if (_docPageCount > 1)
            Container(
              color: const Color(0xFF171B22),
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                IconButton(onPressed: widget.moderator ? () => _goPage(_docPage - 1) : null, icon: const Icon(Icons.chevron_right, color: Colors.white)),
                Text('${_docPage + 1} / $_docPageCount', style: const TextStyle(color: Colors.white)),
                IconButton(onPressed: widget.moderator ? () => _goPage(_docPage + 1) : null, icon: const Icon(Icons.chevron_left, color: Colors.white)),
              ]),
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

/// عارض مستند مشارَك (PDF: صفحة واحدة كصورة / صورة) + طبقة رسم فوقه تتزامن بين الجميع.
class _SharedDocView extends StatefulWidget {
  final String url;
  final bool isPdf;
  final int page;
  final List<_Stroke> strokes;
  final bool canDraw;
  final bool eraser;
  final void Function(int) onPageCount;
  final void Function(Offset, Size) onPanStart;
  final void Function(Offset, Size) onPanUpdate;
  final VoidCallback onPanEnd;
  const _SharedDocView({super.key, required this.url, required this.isPdf, required this.page, required this.strokes, required this.canDraw, required this.eraser, required this.onPageCount, required this.onPanStart, required this.onPanUpdate, required this.onPanEnd});

  @override
  State<_SharedDocView> createState() => _SharedDocViewState();
}

class _SharedDocViewState extends State<_SharedDocView> {
  PdfDocument? _doc;
  Uint8List? _image; // الصفحة الحالية كصورة
  int _renderedPage = -1;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await http.get(Uri.parse(widget.url));
      if (r.statusCode != 200) throw StateError('HTTP ${r.statusCode}');
      if (!widget.isPdf) {
        if (mounted) setState(() => _image = r.bodyBytes);
        widget.onPageCount(1);
        return;
      }
      final doc = await PdfDocument.openData(r.bodyBytes);
      if (!mounted) { await doc.close(); return; }
      _doc = doc;
      widget.onPageCount(doc.pagesCount);
      await _render(widget.page);
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذر عرض الملف: $e');
    }
  }

  Future<void> _render(int index) async {
    final doc = _doc;
    if (doc == null || _busy) return;
    _busy = true;
    try {
      final n = index.clamp(0, doc.pagesCount - 1);
      final page = await doc.getPage(n + 1);
      final img = await page.render(width: page.width * 2, height: page.height * 2, format: PdfPageImageFormat.jpeg, backgroundColor: '#FFFFFF');
      await page.close();
      if (mounted && img != null) setState(() { _image = img.bytes; _renderedPage = index; });
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذر عرض الصفحة: $e');
    } finally {
      _busy = false;
    }
  }

  @override
  void didUpdateWidget(covariant _SharedDocView old) {
    super.didUpdateWidget(old);
    if (widget.isPdf && widget.page != _renderedPage && _doc != null) _render(widget.page);
  }

  @override
  void dispose() {
    _doc?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!, style: const TextStyle(color: Colors.white)));
    final img = _image;
    if (img == null) return const Center(child: CircularProgressIndicator());
    return LayoutBuilder(
      builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        return GestureDetector(
          onPanStart: widget.canDraw ? (d) => widget.onPanStart(d.localPosition, size) : null,
          onPanUpdate: widget.canDraw ? (d) => widget.onPanUpdate(d.localPosition, size) : null,
          onPanEnd: widget.canDraw ? (_) => widget.onPanEnd() : null,
          child: Stack(fit: StackFit.expand, children: [
            ColoredBox(color: Colors.white, child: Image.memory(img, fit: BoxFit.contain, gaplessPlayback: true)),
            CustomPaint(painter: _BoardPainter(widget.strokes)),
          ]),
        );
      },
    );
  }
}

/// نافذة الشات الداخلي للاجتماع.
class _ChatSheet extends StatefulWidget {
  final List<_ChatMsg> messages;
  final TextEditingController controller;
  final ScrollController scroll;
  final VoidCallback onSend;
  final bool recordedNote;
  const _ChatSheet({required this.messages, required this.controller, required this.scroll, required this.onSend, required this.recordedNote});

  @override
  State<_ChatSheet> createState() => _ChatSheetState();
}

class _ChatSheetState extends State<_ChatSheet> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    // تحديث القائمة لما تصل رسائل جديدة والنافذة مفتوحة
    _t = Timer.periodic(const Duration(milliseconds: 600), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          children: [
            const Padding(padding: EdgeInsets.all(12), child: Text('شات الاجتماع', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16))),
            Text(widget.recordedNote ? 'الاجتماع مسجّل: يُحفظ الشات مع التسجيل' : 'يُحذف الشات عند انتهاء الاجتماع', style: const TextStyle(color: Colors.white54, fontSize: 11.5)),
            const Divider(color: Colors.white12),
            Expanded(
              child: widget.messages.isEmpty
                  ? const Center(child: Text('لا توجد رسائل بعد', style: TextStyle(color: Colors.white54)))
                  : ListView.builder(
                      controller: widget.scroll,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: widget.messages.length,
                      itemBuilder: (_, i) {
                        final m = widget.messages[i];
                        return Align(
                          alignment: m.mine ? Alignment.centerLeft : Alignment.centerRight,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                            decoration: BoxDecoration(color: m.mine ? const Color(0xFF1D4ED8) : const Color(0xFF303744), borderRadius: BorderRadius.circular(12)),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(m.mine ? 'أنت' : m.name, style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w700)),
                              const SizedBox(height: 2),
                              Text(m.text, style: const TextStyle(color: Colors.white, height: 1.4)),
                            ]),
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 12),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    style: const TextStyle(color: Colors.white),
                    maxLength: 240,
                    decoration: const InputDecoration(counterText: '', hintText: 'اكتب رسالة...', hintStyle: TextStyle(color: Colors.white38), filled: true, fillColor: Color(0xFF202631), border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.all(Radius.circular(24))), contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
                    onSubmitted: (_) => widget.onSend(),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filled(onPressed: () { widget.onSend(); setState(() {}); }, icon: const Icon(Icons.send)),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}
