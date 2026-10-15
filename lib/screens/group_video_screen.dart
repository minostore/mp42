import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../services/groups_service.dart';
import '../services/screen_protection_service.dart';
import '../theme/app_theme.dart';

/// مشغل فيديو/تسجيل جلسة داخل التطبيق: رابط مؤقت من الخادم + علامة مائية متحركة + منع التصوير.
class GroupVideoScreen extends StatefulWidget {
  final String groupId;
  final String kind; // videos | recordings
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
  Timer? _wmTimer;
  Alignment _wmAlign = Alignment.topLeft;
  final _rnd = Random();
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    _protection.enable();
    _load();
    _wmTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (mounted) setState(() => _wmAlign = Alignment(_rnd.nextDouble() * 1.6 - .8, _rnd.nextDouble() * 1.6 - .8));
    });
  }

  Future<void> _load() async {
    try {
      final svc = GroupsService();
      final m = widget.kind == 'admin'
          ? await svc.getAdminRecordingMedia(widget.itemId)
          : await svc.getMedia(groupId: widget.groupId, kind: widget.kind, id: widget.itemId);
      final c = VideoPlayerController.networkUrl(Uri.parse(m.url));
      await c.initialize();
      c.addListener(() { if (mounted) setState(() {}); }); // تحديث الوقت والشريط
      await c.play();
      if (!mounted) { await c.dispose(); return; }
      setState(() { _media = m; _c = c; });
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذر تشغيل المحتوى. تحقق من اتصال الإنترنت وعضويتك، ثم حاول مرة أخرى.\\n\\nالتفاصيل: $e');
    }
  }

  static String _fmt(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  void _skip(VideoPlayerController c, int seconds) {
    final total = c.value.duration;
    var target = c.value.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (target > total) target = total;
    c.seekTo(target);
  }

  @override
  void dispose() {
    _wmTimer?.cancel();
    _c?.dispose();
    _protection.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      backgroundColor: AppColors.ink,
      appBar: AppBar(title: Text(widget.title), backgroundColor: AppColors.ink, foregroundColor: Colors.white),
      body: Center(
        child: _error != null
            ? Padding(padding: const EdgeInsets.all(20), child: Text(_error!, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center))
            : (c == null || !c.value.isInitialized)
                ? const CircularProgressIndicator(color: AppColors.gold)
                : SingleChildScrollView(
                    child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AspectRatio(
                        aspectRatio: c.value.aspectRatio,
                        child: Stack(
                          children: [
                            GestureDetector(onTap: () => setState(() => c.value.isPlaying ? c.pause() : c.play()), child: VideoPlayer(c)),
                            IgnorePointer(
                              child: AnimatedAlign(
                                duration: const Duration(seconds: 2),
                                alignment: _wmAlign,
                                child: Text(_media?.watermarkText ?? '', style: const TextStyle(color: Colors.white38, fontSize: 14, fontWeight: FontWeight.bold)),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // شريط التقديم والتأخير: اسحب للوصول لأي نقطة في الفيديو + الوقت الحالي والمدة
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(children: [
                          Text(_fmt(c.value.position), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                          Expanded(
                            child: Slider(
                              value: c.value.position.inMilliseconds.clamp(0, c.value.duration.inMilliseconds).toDouble(),
                              max: c.value.duration.inMilliseconds.toDouble().clamp(1, double.infinity),
                              activeColor: AppColors.gold,
                              inactiveColor: Colors.white24,
                              onChanged: (v) => c.seekTo(Duration(milliseconds: v.round())),
                            ),
                          ),
                          Text(_fmt(c.value.duration), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                        ]),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(tooltip: 'رجوع 30 ثانية', onPressed: () => _skip(c, -30), icon: const Icon(Icons.fast_rewind, color: Colors.white)),
                          IconButton(tooltip: 'رجوع 10 ثوانٍ', onPressed: () => _skip(c, -10), icon: const Icon(Icons.replay_10, color: Colors.white)),
                          IconButton(onPressed: () => setState(() => c.value.isPlaying ? c.pause() : c.play()), icon: Icon(c.value.isPlaying ? Icons.pause_circle : Icons.play_circle, color: AppColors.gold, size: 42)),
                          IconButton(tooltip: 'تقديم 10 ثوانٍ', onPressed: () => _skip(c, 10), icon: const Icon(Icons.forward_10, color: Colors.white)),
                          IconButton(tooltip: 'تقديم 30 ثانية', onPressed: () => _skip(c, 30), icon: const Icon(Icons.fast_forward, color: Colors.white)),
                        ],
                      ),
                      TextButton(
                        onPressed: () {
                          const speeds = [0.75, 1.0, 1.25, 1.5, 2.0];
                          _speed = speeds[(speeds.indexOf(_speed) + 1) % speeds.length];
                          c.setPlaybackSpeed(_speed);
                          setState(() {});
                        },
                        child: Text('السرعة ${_speed}x', style: const TextStyle(color: Colors.white70)),
                      ),
                    ],
                  )),
      ),
    );
  }
}
