import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../services/groups_service.dart';
import '../services/screen_protection_service.dart';
import '../theme/app_theme.dart';
import '../widgets/moving_watermark.dart';

/// مشغل فيديو/تسجيل جلسة داخل التطبيق: رابط مؤقت من الخادم + علامة مائية متحركة (IP + الهاتف + البريد)
/// + منع التصوير + نفس إضافات مشغل الكورسات (الصوت، سرعة التشغيل، الشاشة بالعرض).
class GroupVideoScreen extends StatefulWidget {
  final String groupId;
  final String kind; // videos | recordings | admin
  final String itemId;
  final String title;
  const GroupVideoScreen({super.key, required this.groupId, required this.kind, required this.itemId, required this.title});

  @override
  State<GroupVideoScreen> createState() => _GroupVideoScreenState();
}

class _GroupVideoScreenState extends State<GroupVideoScreen> {
  final _protection = ScreenProtectionService();
  VideoPlayerController? _c;
  GroupMedia? _media;
  String? _error;
  double _speed = 1.0;
  double _volume = 1.0;
  bool _fullscreen = false;
  bool _showControls = true;
  Timer? _hideTimer;
  List<Map<String, dynamic>> _chatLog = const [];

  @override
  void initState() {
    super.initState();
    _protection.enable();
    try { const MethodChannel('masar_app/audio_protection').invokeMethod('blockAudioCapture'); } catch (_) {}
    _load();
  }

  Future<void> _load() async {
    try {
      final svc = GroupsService();
      final m = widget.kind == 'admin'
          ? await svc.getAdminRecordingMedia(widget.itemId)
          : await svc.getMedia(groupId: widget.groupId, kind: widget.kind, id: widget.itemId);
      final c = VideoPlayerController.networkUrl(Uri.parse(m.url));
      await c.initialize();
      c.addListener(() { if (mounted) setState(() {}); });
      await c.play();
      if (!mounted) { await c.dispose(); return; }
      setState(() { _media = m; _c = c; });
      _pokeControls();
      _loadChatLog();
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذر تشغيل المحتوى. تحقق من اتصال الإنترنت وعضويتك، ثم حاول مرة أخرى.\n\nالتفاصيل: $e');
    }
  }

  /// شات الجلسة المسجلة (إن وُجد) يظهر مع التسجيل.
  Future<void> _loadChatLog() async {
    if (widget.kind != 'recordings') return;
    try {
      final snap = await FirebaseFirestore.instance.collection('groups').doc(widget.groupId).collection('recordings').doc(widget.itemId).get();
      final raw = snap.data()?['chatLog'];
      if (raw is List && mounted) {
        setState(() => _chatLog = raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList());
      }
    } catch (_) {}
  }

  void _showChatLog() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.ink,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(16),
          children: [
            const Text('شات الجلسة', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            for (final m in _chatLog)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: '${m['n'] ?? ''}: ', style: const TextStyle(color: AppColors.gold, fontWeight: FontWeight.w700)),
                  TextSpan(text: '${m['x'] ?? ''}', style: const TextStyle(color: Colors.white)),
                ])),
              ),
          ],
        ),
      ),
    );
  }

  static String _fmt(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  void _skip(int seconds) {
    final c = _c;
    if (c == null) return;
    final total = c.value.duration;
    var target = c.value.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (target > total) target = total;
    c.seekTo(target);
    _pokeControls();
  }

  void _togglePlay() {
    final c = _c;
    if (c == null) return;
    c.value.isPlaying ? c.pause() : c.play();
    setState(() {});
    _pokeControls();
  }

  void _pokeControls() {
    _hideTimer?.cancel();
    if (!_showControls && mounted) setState(() => _showControls = true);
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_c?.value.isPlaying ?? false)) setState(() => _showControls = false);
    });
  }

  void _onVideoTap() {
    if (_showControls) {
      _hideTimer?.cancel();
      setState(() => _showControls = false);
    } else {
      _pokeControls();
    }
  }

  Future<void> _toggleFullscreen() async {
    _fullscreen = !_fullscreen;
    if (_fullscreen) {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    if (mounted) setState(() {});
    _pokeControls();
  }

  Future<void> _setSpeed(double s) async {
    _speed = s;
    await _c?.setPlaybackSpeed(s);
    if (mounted) setState(() {});
  }

  void _showVolumeSheet() {
    final c = _c;
    if (c == null) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.ink,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(18),
        child: StatefulBuilder(
          builder: (ctx, setLocal) => Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('الصوت', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            Slider(
              value: _volume,
              min: 0,
              max: 1,
              divisions: 10,
              onChanged: (v) async {
                setLocal(() => _volume = v);
                await c.setVolume(v);
                if (mounted) setState(() {});
              },
            ),
          ]),
        ),
      ),
    );
  }

  void _showSpeedSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.ink,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(18),
        children: [
          const Text('سرعة التشغيل', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          for (final s in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
            ListTile(
              title: Text('${s}x', style: const TextStyle(color: Colors.white)),
              trailing: _speed == s ? const Icon(Icons.check, color: AppColors.gold) : null,
              onTap: () async {
                await _setSpeed(s);
                if (ctx.mounted) Navigator.pop(ctx);
              },
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _c?.dispose();
    _protection.disable();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Widget _icon(IconData icon, VoidCallback onTap, {double size = 26, String? tooltip}) => IconButton(
        tooltip: tooltip,
        onPressed: () {
          onTap();
          _pokeControls();
        },
        iconSize: size,
        color: Colors.white,
        icon: Icon(icon),
      );

  Widget _controls(VideoPlayerController c) {
    return AnimatedOpacity(
      opacity: _showControls ? 1 : 0,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(
        ignoring: !_showControls,
        child: Container(
          decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black54, Colors.transparent, Colors.black54])),
          child: Column(children: [
            Row(children: [
              _icon(Icons.arrow_forward, () async {
                if (_fullscreen) await _toggleFullscreen();
                if (mounted) Navigator.of(context).maybePop();
              }, size: 24),
              Expanded(child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
              if (_chatLog.isNotEmpty) _icon(Icons.chat_bubble_outline, _showChatLog, size: 22, tooltip: 'شات الجلسة'),
              _icon(_volume == 0 ? Icons.volume_off : Icons.volume_up, _showVolumeSheet, size: 22, tooltip: 'الصوت'),
              TextButton(
                onPressed: () {
                  _showSpeedSheet();
                  _pokeControls();
                },
                child: Text('${_speed}x', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              ),
              // مساحة لأيقونة فهمت أعلى اليمين
              const SizedBox(width: 44),
            ]),
            Expanded(
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _icon(Icons.replay_10, () => _skip(-10), size: 38, tooltip: 'تأخير 10 ثوانٍ'),
                const SizedBox(width: 18),
                IconButton(onPressed: _togglePlay, iconSize: 56, color: Colors.white, icon: Icon(c.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled)),
                const SizedBox(width: 18),
                _icon(Icons.forward_10, () => _skip(10), size: 38, tooltip: 'تقديم 10 ثوانٍ'),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(textDirection: TextDirection.ltr, children: [
                Text('${_fmt(c.value.position)} / ${_fmt(c.value.duration)}', style: const TextStyle(color: Colors.white, fontSize: 12)),
                const SizedBox(width: 10),
                Expanded(
                  child: VideoProgressIndicator(
                    c,
                    allowScrubbing: true,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    colors: const VideoProgressColors(playedColor: AppColors.accent, bufferedColor: Colors.white24, backgroundColor: Colors.white12),
                  ),
                ),
                _icon(_fullscreen ? Icons.fullscreen_exit : Icons.fullscreen, _toggleFullscreen, size: 26, tooltip: 'الشاشة بالعرض'),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _videoArea(VideoPlayerController c) {
    return Stack(alignment: Alignment.center, children: [
      Container(color: Colors.black),
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onVideoTap,
        child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)),
      ),
      // علامة مائية متحركة: IP + الهاتف + البريد (+ الاسم/المعرّف من الخادم)
      Positioned.fill(child: MovingWatermark(extra: _media?.watermarkText ?? '')),
      _controls(c),
      // أيقونة فهمت أعلى الفيديو على اليمين
      const Positioned(top: 8, right: 10, child: FahmtLogoBadge(size: 30)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final ready = c != null && c.value.isInitialized;
    return Scaffold(
      backgroundColor: AppColors.ink,
      appBar: (_fullscreen || ready) ? null : AppBar(title: Text(widget.title), backgroundColor: AppColors.ink, foregroundColor: Colors.white),
      body: SafeArea(
        child: _error != null
            ? Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(_error!, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center)))
            : !ready
                ? const Center(child: CircularProgressIndicator(color: AppColors.gold))
                : (_fullscreen
                    ? _videoArea(c)
                    : Column(children: [
                        AspectRatio(aspectRatio: 16 / 9, child: _videoArea(c)),
                        const SizedBox(height: 14),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Align(alignment: Alignment.centerRight, child: Text(widget.title, style: const TextStyle(color: AppColors.paper, fontSize: 17, fontWeight: FontWeight.w700))),
                        ),
                      ])),
      ),
    );
  }
}
