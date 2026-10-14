import 'dart:async';
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

/// شاشة التحديث: لوجو التطبيق + عنوان + وصف + تنزيل وتثبيت.
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
    return PopScope(
      canPop: !mandatory,
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          backgroundColor: _C.bg,
          body: SafeArea(
            child: Column(children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
                  child: Column(children: [
                    // اللوجو
                    Container(
                      width: 104, height: 104,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(colors: [_C.primary, _C.primaryDark], begin: Alignment.topRight, end: Alignment.bottomLeft),
                        borderRadius: BorderRadius.circular(32),
                        boxShadow: [BoxShadow(color: _C.primary.withOpacity(.35), blurRadius: 28, offset: const Offset(0, 12))],
                      ),
                      padding: const EdgeInsets.all(22),
                      // ضع لوجو التطبيق في assets/images/logo.png وسجّله في pubspec.yaml
                      child: Image.asset('assets/images/logo.png', fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const Icon(Icons.school_rounded, color: Colors.white, size: 52)),
                    ),
                    const SizedBox(height: 22),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: (mandatory ? _C.accent : _C.primary).withOpacity(.12),
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        mandatory ? 'تحديث إجباري' : 'تحديث جديد متاح',
                        style: TextStyle(color: mandatory ? _C.accent : _C.primaryDark, fontWeight: FontWeight.w900, fontSize: 12.5),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(u.title, textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: _C.ink, height: 1.35)),
                    const SizedBox(height: 6),
                    Text('الإصدار ${u.versionName}${_size(u.apkSize).isEmpty ? '' : ' • ${_size(u.apkSize)}'}',
                        style: const TextStyle(color: _C.muted, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 22),
                    if (u.description.trim().isNotEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(color: _C.soft, width: 1.5),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: const [
                            Icon(Icons.auto_awesome_rounded, color: _C.accent, size: 20),
                            SizedBox(width: 8),
                            Text('ما الجديد؟', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15.5, color: _C.ink)),
                          ]),
                          const SizedBox(height: 10),
                          Text(u.description.trim(), style: const TextStyle(height: 1.8, color: _C.ink, fontSize: 14.5)),
                        ]),
                      ),
                    if (mandatory) ...[
                      const SizedBox(height: 14),
                      const Text('يجب تحديث التطبيق للمتابعة.',
                          style: TextStyle(color: _C.accent, fontWeight: FontWeight.w800)),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFDC2626), fontWeight: FontWeight.w700)),
                    ],
                  ]),
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
                decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: _C.soft))),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  if (_busy) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: _progress > 0 ? _progress / 100 : null,
                        minHeight: 10, backgroundColor: _C.soft,
                        valueColor: const AlwaysStoppedAnimation(_C.primary),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(_progress > 0 ? 'جارٍ التنزيل $_progress%' : 'جارٍ التحضير...',
                        style: const TextStyle(color: _C.muted, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 10),
                  ],
                  SizedBox(
                    width: double.infinity, height: 56,
                    child: ElevatedButton.icon(
                      onPressed: _busy ? null : _start,
                      icon: const Icon(Icons.system_update_rounded),
                      label: Text(_error != null ? 'إعادة المحاولة' : 'تحديث الآن',
                          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _C.primary, foregroundColor: Colors.white,
                        disabledBackgroundColor: _C.primary.withOpacity(.5),
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                      ),
                    ),
                  ),
                  if (!mandatory) ...[
                    const SizedBox(height: 6),
                    TextButton(
                      onPressed: _busy ? null : widget.onSkip,
                      child: const Text('تخطي الآن', style: TextStyle(color: _C.muted, fontWeight: FontWeight.w800, fontSize: 15)),
                    ),
                  ],
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
