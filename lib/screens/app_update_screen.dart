import '../widgets/smart_image.dart';
import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:ota_update/ota_update.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_update_service.dart';

/// ألوان المنصة (نفس ألوان الموقع: أزرق سماوي + برتقالي).
class _C {
  static const primary = Color(0xFF28B5F6);
  static const primaryDark = Color(0xFF0E8FCB);
  static const accent = Color(0xFFFF6E42);
  static const ink = Color(0xFF14191F);
  static const muted = Color(0xFF6B7A86);
  static const bg = Color(0xFFF9FAFB);
  static const soft = Color(0xFFEEF4F6);
}

/// شاشة التحديث بملء الصفحة: صورة + عنوان + وصف + تنزيل وتثبيت.
/// - إجباري: لا يوجد زر تخطي ولا رجوع.
/// - اختياري: زر «تخطي الآن».
class AppUpdateScreen extends StatefulWidget {
  final AppUpdateInfo update;
  final VoidCallback? onSkip;
  const AppUpdateScreen({super.key, required this.update, this.onSkip});

  @override
  State<AppUpdateScreen> createState() => _AppUpdateScreenState();
}

class _AppUpdateScreenState extends State<AppUpdateScreen> {
  bool _busy = false;
  int _progress = 0;
  String? _error;
  StreamSubscription<OtaEvent>? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() { _busy = true; _progress = 0; _error = null; });
    try {
      final url = await AppUpdateService.instance.downloadUrl(widget.update.id);
      _sub?.cancel();
      _sub = OtaUpdate()
          .execute(url, destinationFilename: 'fahmt_${widget.update.versionName}.apk')
          .listen((e) {
        if (!mounted) return;
        switch (e.status) {
          case OtaStatus.DOWNLOADING:
            setState(() => _progress = int.tryParse(e.value ?? '0') ?? 0);
            break;
          case OtaStatus.INSTALLING:
            setState(() { _progress = 100; _busy = false; });
            break;
          case OtaStatus.ALREADY_RUNNING_ERROR:
            break;
          case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
            setState(() { _busy = false; _error = 'اسمح للتطبيق بتثبيت التطبيقات من الإعدادات ثم أعد المحاولة.'; });
            break;
          default:
            if (e.status.toString().contains('ERROR')) {
              setState(() { _busy = false; _error = 'تعذر تنزيل التحديث، حاول مرة أخرى.'; });
            }
        }
      }, onError: (_) {
        if (mounted) setState(() { _busy = false; _error = 'تعذر تنزيل التحديث، حاول مرة أخرى.'; });
      });
    } catch (_) {
      // بديل: فتح رابط التنزيل في المتصفح
      try {
        final url = await AppUpdateService.instance.downloadUrl(widget.update.id);
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        if (mounted) setState(() => _busy = false);
      } catch (_) {
        if (mounted) setState(() { _busy = false; _error = 'تعذر الحصول على رابط التحديث. تأكد من الإنترنت.'; });
      }
    }
  }

  String _size(int b) {
    if (b <= 0) return '';
    final mb = b / (1024 * 1024);
    return '${mb.toStringAsFixed(mb >= 100 ? 0 : 1)} ميجا';
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.update;
    final mandatory = u.mandatory;
    final hasImage = u.imageUrl.isNotEmpty;
    final height = MediaQuery.of(context).size.height;
    return PopScope(
      canPop: !mandatory,
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          backgroundColor: _C.ink,
          body: SizedBox.expand(
            child: Stack(fit: StackFit.expand, children: [
              // الخلفية: صورة التحديث تملأ الصفحة كاملة (أو تدرّج بألوان المنصة لو لا توجد صورة)
              if (hasImage)
                SmartImage(u.imageUrl, fit: BoxFit.cover, placeholder: const ColoredBox(color: _C.ink), error: const _GradientBg())
              else
                const _GradientBg(),
              // تدرّج داكن أسفل الصفحة ليظهر النص بوضوح فوق أي صورة
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x66000000), Color(0x00000000), Color(0xCC000000), Color(0xF2000000)],
                    stops: [0, .3, .62, 1],
                  ),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    // الأعلى: زر «تخطي» للاختياري فقط
                    SizedBox(
                      height: 48,
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: mandatory
                            ? Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                decoration: BoxDecoration(color: _C.accent, borderRadius: BorderRadius.circular(99)),
                                child: const Text('تحديث إجباري',
                                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12.5)),
                              )
                            : TextButton(
                                onPressed: _busy ? null : widget.onSkip,
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  backgroundColor: Colors.black38,
                                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
                                ),
                                child: const Text('تخطي', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
                              ),
                      ),
                    ),
                    const Spacer(),
                    const Text('يتوفر الآن تحديث جديد من التطبيق', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w800, fontSize: 13.5)),
                    const SizedBox(height: 6),
                    Text(u.title,
                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Colors.white, height: 1.3)),
                    const SizedBox(height: 6),
                    Text('الإصدار ${u.versionName}${_size(u.apkSize).isEmpty ? '' : ' • ${_size(u.apkSize)}'}',
                        style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                    if (u.description.trim().isNotEmpty) ...[
                      const SizedBox(height: 14),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: height * .26),
                        child: SingleChildScrollView(
                          child: Text(u.description.trim(),
                              style: const TextStyle(height: 1.8, color: Colors.white, fontSize: 15)),
                        ),
                      ),
                    ],
                    if (mandatory) ...[
                      const SizedBox(height: 12),
                      const Text('يجب تحديث التطبيق للمتابعة.',
                          style: TextStyle(color: Color(0xFFFFB199), fontWeight: FontWeight.w800)),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: Color(0xFFFF8A8A), fontWeight: FontWeight.w700)),
                    ],
                    const SizedBox(height: 18),
                    if (_busy) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: LinearProgressIndicator(
                          value: _progress > 0 ? _progress / 100 : null,
                          minHeight: 10,
                          backgroundColor: Colors.white24,
                          valueColor: const AlwaysStoppedAnimation(_C.primary),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(_progress > 0 ? 'جارٍ التنزيل $_progress%' : 'جارٍ التحضير...',
                          style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 12),
                    ],
                    SizedBox(
                      height: 56,
                      child: ElevatedButton.icon(
                        onPressed: _busy ? null : _start,
                        icon: const Icon(Icons.system_update_rounded),
                        label: Text(_error != null ? 'إعادة المحاولة' : 'تحديث الآن',
                            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _C.primary,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: _C.primary.withOpacity(.5),
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// خلفية بألوان المنصة عند عدم وجود صورة (لا حاجة لأي صورة داخل المشروع).
class _GradientBg extends StatelessWidget {
  const _GradientBg();
  @override
  Widget build(BuildContext context) => const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [_C.primary, _C.primaryDark],
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
          ),
        ),
      );
}
