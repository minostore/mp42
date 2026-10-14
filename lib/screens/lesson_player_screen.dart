import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';
import '../services/firestore_service.dart';
import '../services/video_service.dart';
import '../services/api_functions.dart' show FirebaseFunctionsException;
import '../services/r2_worker_service.dart';
import '../models/lesson.dart';
import '../theme/app_theme.dart';
import '../services/learning_service.dart';

class LessonPlayerScreen extends StatefulWidget {
  final String courseId;
  final String lessonId;

  const LessonPlayerScreen({super.key, required this.courseId, required this.lessonId});

  @override
  State<LessonPlayerScreen> createState() => _LessonPlayerScreenState();
}

class _LessonPlayerScreenState extends State<LessonPlayerScreen> {
  final _firestore = FirestoreService();
  final _videoService = VideoService();
  VideoPlayerController? _controller;
  Timer? _progressTimer;
  Timer? _urlRefreshTimer;
  bool _loading = true;
  bool _fullscreen = false;
  String? _error;
  double _speed = 1.0;
  double _volume = 1.0;
  final _learning = LearningService();
  static const int _previewLimitSeconds = 120;
  bool _previewEnded = false;
  bool _showControls = true;
  Timer? _hideTimer;

  String get _uid => FirebaseAuth.instance.currentUser!.uid;

  @override
  void initState() {
    super.initState();
    try { const MethodChannel('masar_app/audio_protection').invokeMethod('blockAudioCapture'); } catch (_) {}
    _load();
  }

  Future<void> _load() async {
    _progressTimer?.cancel();
    _urlRefreshTimer?.cancel();
    final old = _controller;
    _controller = null;
    await old?.dispose();

    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      String videoUrl;
      DateTime? expiresAt;
      try {
        final signed = await _videoService.getSignedVideoUrl(
          courseId: widget.courseId,
          lessonId: widget.lessonId,
        );
        videoUrl = signed.url;
        expiresAt = signed.expiresAt;
      } catch (e) {
        // الخادم رفض أو غير متاح: نقرأ من Cloudflare R2 مباشرة، فقط إذا كان الحساب مشتريًا
        // للكورس (من Firestore) أو الدرس معاينة مجانية.
        final fallback = await _r2FallbackUrl();
        if (fallback == null) rethrow;
        videoUrl = fallback;
      }
      // قراءة التقدّم اختيارية: فشلها لا يجب أن يمنع التشغيل ولا يظهر كأن الكورس غير مشترى.
      int savedSeconds = 0;
      try {
        savedSeconds = await _firestore.getLessonProgressSeconds(_uid, widget.courseId, widget.lessonId);
      } catch (_) {}
      final controller = VideoPlayerController.networkUrl(Uri.parse(videoUrl));
      await controller.initialize();

      if (savedSeconds > 0 && savedSeconds < controller.value.duration.inSeconds) {
        await controller.seekTo(Duration(seconds: savedSeconds));
      }

      await controller.setPlaybackSpeed(_speed);
      if (await _isPreviewLesson()) {
        controller.addListener(_enforcePreviewLimit);
      }
      await controller.play();

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _controller = controller;
        _loading = false;
      });

      if (expiresAt != null) {
        final refreshIn = expiresAt.difference(DateTime.now()) - const Duration(seconds: 30);
        _urlRefreshTimer = Timer(
          refreshIn.isNegative ? const Duration(seconds: 5) : refreshIn,
          _load,
        );
      }
      _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) { _saveProgress().catchError((_) {}); });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = (e is FirebaseFunctionsException && e.code == 'permission-denied')
              ? 'هذا الكورس غير مشترى على هذا الحساب.'
              : 'تعذر تحميل الفيديو. حاول مرة أخرى.\n(${e.toString().split('\n').first})';
          _loading = false;
        });
      }
    }
  }

  Future<String?> _r2FallbackUrl() async {
    final lessons = await _firestore.getLessons(widget.courseId);
    Lesson? lesson;
    for (final l in lessons) {
      if (l.id == widget.lessonId) lesson = l;
    }
    if (lesson == null || lesson.r2Key.isEmpty) return null;
    final allowed = lesson.isPreview || await _firestore.hasPurchased(_uid, widget.courseId);
    return allowed ? R2WorkerService.keyToUrl(lesson.r2Key) : null;
  }

  Future<bool> _isPreviewLesson() async {
    final lessons = await _firestore.getLessons(widget.courseId);
    for (final lesson in lessons) {
      if (lesson.id == widget.lessonId) return lesson.isPreview;
    }
    return false;
  }

  void _enforcePreviewLimit() {
    final c = _controller;
    if (c == null || !c.value.isInitialized || _previewEnded) return;
    if (c.value.position.inSeconds >= _previewLimitSeconds) {
      _previewEnded = true;
      c.pause();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('انتهت المعاينة المجانية. اشترِ الكورس لمتابعة الدرس.')));
      }
    }
  }

  Future<void> _saveBookmark() async {
    final c = _controller; if (c == null) return;
    await _learning.saveBookmark(uid: _uid, courseId: widget.courseId, lessonId: widget.lessonId, seconds: c.value.position.inSeconds);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ العلامة المرجعية')));
  }

  Future<void> _addNote() async {
    final c = _controller; if (c == null) return;
    final controller = TextEditingController();
    final text = await showDialog<String>(context: context, builder: (_) => AlertDialog(title: const Text('ملاحظة جديدة'), content: TextField(controller: controller, maxLines: 4, decoration: const InputDecoration(hintText: 'اكتب ملاحظتك...')), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('حفظ'))]));
    if (text != null && text.trim().isNotEmpty) await _learning.saveNote(uid: _uid, courseId: widget.courseId, lessonId: widget.lessonId, seconds: c.value.position.inSeconds, text: text);
  }

  Future<void> _saveProgress({bool completed = false}) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    await _firestore.saveLessonProgress(
      uid: _uid,
      courseId: widget.courseId,
      lessonId: widget.lessonId,
      positionSeconds: c.value.position.inSeconds,
      durationSeconds: c.value.duration.inSeconds,
      completed: completed,
    );
  }

  Future<void> _seek(int seconds) async {
    final c = _controller;
    if (c == null) return;
    final target = c.value.position + Duration(seconds: seconds);
    final max = c.value.duration;
    await c.seekTo(target < Duration.zero ? Duration.zero : (target > max ? max : target));
  }

  Future<void> _setSpeed(double speed) async {
    _speed = speed;
    await _controller?.setPlaybackSpeed(speed);
    if (mounted) setState(() {});
  }

  Future<void> _toggleFullscreen() async {
    _fullscreen = !_fullscreen;
    if (_fullscreen) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    if (mounted) setState(() {});
  }

  // ===== أزرار المشغل فوق الفيديو (مألوفة مثل أي مشغل فيديو) =====
  void _pokeControls() {
    _hideTimer?.cancel();
    if (!_showControls) setState(() => _showControls = true);
    _hideTimer = Timer(const Duration(seconds: 3), () {
      final playing = _controller?.value.isPlaying ?? false;
      if (mounted && playing) setState(() => _showControls = false);
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

  void _togglePlay() {
    final c = _controller;
    if (c == null) return;
    c.value.isPlaying ? c.pause() : c.play();
    setState(() {});
    _pokeControls();
  }

  String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final sec = d.inSeconds.remainder(60);
    return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
  }

  void _showVolumeSheet() {
    final c = _controller;
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
      builder: (_) => _SpeedSheet(current: _speed, onPick: _setSpeed),
    );
  }

  Widget _overlayIcon(IconData icon, VoidCallback onTap, {double size = 28, String? tooltip}) {
    return IconButton(
      tooltip: tooltip,
      onPressed: () {
        onTap();
        _pokeControls();
      },
      iconSize: size,
      color: Colors.white,
      icon: Icon(icon),
    );
  }

  Widget _buildControlsOverlay(VideoPlayerController c) {
    return AnimatedOpacity(
      opacity: _showControls ? 1 : 0,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(
        ignoring: !_showControls,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black54, Colors.transparent, Colors.black54],
            ),
          ),
          child: Column(
            children: [
              // الصف العلوي: رجوع + الصوت + السرعة
              Row(
                children: [
                  _overlayIcon(Icons.arrow_forward, () => context.pop(), size: 24),
                  const Spacer(),
                  _overlayIcon(_volume == 0 ? Icons.volume_off : Icons.volume_up, _showVolumeSheet, size: 22, tooltip: 'الصوت'),
                  TextButton(
                    onPressed: () {
                      _showSpeedSheet();
                      _pokeControls();
                    },
                    child: Text('${_speed}x', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
              // المنتصف: تأخير / تشغيل / تقديم
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _overlayIcon(Icons.replay_10, () => _seek(-10), size: 38, tooltip: 'تأخير 10 ثوانٍ'),
                    const SizedBox(width: 18),
                    IconButton(
                      onPressed: _togglePlay,
                      iconSize: 56,
                      color: Colors.white,
                      icon: Icon(c.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled),
                    ),
                    const SizedBox(width: 18),
                    _overlayIcon(Icons.forward_10, () => _seek(10), size: 38, tooltip: 'تقديم 10 ثوانٍ'),
                  ],
                ),
              ),
              // الصف السفلي: الوقت + شريط التقدم + ملء الشاشة
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  textDirection: TextDirection.ltr,
                  children: [
                    ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: c,
                      builder: (_, v, __) => Text(
                        '${_fmt(v.position)} / ${_fmt(v.duration)}',
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: VideoProgressIndicator(
                        c,
                        allowScrubbing: true,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        colors: const VideoProgressColors(
                          playedColor: AppColors.accent,
                          bufferedColor: Colors.white24,
                          backgroundColor: Colors.white12,
                        ),
                      ),
                    ),
                    _overlayIcon(
                      _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                      _toggleFullscreen,
                      size: 26,
                      tooltip: 'تكبير الشاشة',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoArea(VideoPlayerController? c) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(color: Colors.black),
        if (_loading) const CircularProgressIndicator(color: AppColors.accent),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(_error!, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
          ),
        if (c != null && c.value.isInitialized)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _onVideoTap,
            child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)),
          ),
        if (c != null && c.value.isInitialized) _buildControlsOverlay(c),
        // زر الرجوع عند الخطأ أو التحميل (لا توجد أزرار فوق الفيديو بعد)
        if (c == null || !c.value.isInitialized)
          Positioned(
            top: 6,
            right: 6,
            child: IconButton(icon: const Icon(Icons.arrow_forward, color: Colors.white), onPressed: () => context.pop()),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _saveProgress();
    _progressTimer?.cancel();
    _urlRefreshTimer?.cancel();
    _controller?.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;

    return Scaffold(
      backgroundColor: AppColors.ink,
      body: SafeArea(
        child: Column(
          children: [
            if (_fullscreen)
              Expanded(child: _buildVideoArea(c))
            else
              AspectRatio(aspectRatio: 16 / 9, child: _buildVideoArea(c)),
            if (!_fullscreen)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    IconButton(onPressed: _saveBookmark, icon: const Icon(Icons.bookmark_add_outlined, color: Colors.white), tooltip: 'حفظ علامة'),
                    IconButton(onPressed: _addNote, icon: const Icon(Icons.note_add_outlined, color: Colors.white), tooltip: 'إضافة ملاحظة'),
                  ],
                ),
              ),
            if (!_fullscreen)
              Expanded(
                child: StreamBuilder<List<Lesson>>(
                  stream: _firestore.watchLessons(widget.courseId),
                  builder: (context, snap) {
                    final lessons = snap.data ?? <Lesson>[];
                    Lesson? current;
                    for (final lesson in lessons) {
                      if (lesson.id == widget.lessonId) current = lesson;
                    }

                    return ListView(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
                      children: [
                        if (current != null) ...[
                          Text(
                            current.title,
                            style: const TextStyle(
                              color: AppColors.paper,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'الدرس ${current.order} من ${lessons.length}',
                            style: const TextStyle(color: Color(0xFF8FA0A8), fontSize: 12),
                          ),
                          const SizedBox(height: 18),
                        ],
                        const Text(
                          'حلقات الكورس',
                          style: TextStyle(color: AppColors.paper, fontWeight: FontWeight.w700),
                        ),
                        ...lessons.map(
                          (lesson) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: CircleAvatar(
                              radius: 14,
                              backgroundColor: lesson.id == widget.lessonId
                                  ? AppColors.gold
                                  : Colors.white12,
                              child: Text(
                                '${lesson.order}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: lesson.id == widget.lessonId
                                      ? AppColors.ink
                                      : Colors.white70,
                                ),
                              ),
                            ),
                            title: Text(
                              lesson.title,
                              style: const TextStyle(color: AppColors.paper, fontSize: 13),
                            ),
                            subtitle: Text(
                              lesson.durationLabel,
                              style: const TextStyle(color: Color(0xFF8FA0A8), fontSize: 11),
                            ),
                            onTap: () => context.pushReplacement(
                              '/course/${widget.courseId}/lesson/${lesson.id}',
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SpeedSheet extends StatelessWidget {
  final double current;
  final Future<void> Function(double) onPick;

  const _SpeedSheet({required this.current, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.all(18),
      children: [
        const Text(
          'سرعة التشغيل',
          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
        ),
        ...[0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map(
          (speed) => ListTile(
            title: Text('${speed}x', style: const TextStyle(color: Colors.white)),
            trailing: current == speed ? const Icon(Icons.check, color: AppColors.gold) : null,
            onTap: () async {
              await onPick(speed);
              if (context.mounted) Navigator.pop(context);
            },
          ),
        ),
      ],
    );
  }
}
