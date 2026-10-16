import 'package:flutter/material.dart';

import '../screens/app_update_screen.dart';
import '../services/app_update_service.dart';
import '../services/firebase_bootstrap.dart';

/// يلفّ التطبيق كله: عند الفتح يفحص التحديثات.
/// - إجباري → يعرض شاشة التحديث فقط ولا يفتح التطبيق.
/// - اختياري → يعرض الشاشة مع «تخطي الآن» (مرة واحدة لكل تشغيل).
/// يعمل قبل تسجيل الدخول لأن قراءة appUpdates مفتوحة في firestore.rules.
class UpdateGate extends StatefulWidget {
  final Widget child;
  const UpdateGate({super.key, required this.child});

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> with WidgetsBindingObserver {
  AppUpdateInfo? _update;
  bool _skipped = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // لو رجع المستخدم للتطبيق من الخلفية (مثلًا بعد إلغاء التثبيت) نفحص مرة أخرى للإجباري
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    // انتظر جاهزية Firebase (يبدأ في الخلفية) حتى لا يفشل الفحص الأول بصمت
    for (var i = 0; i < 40 && !FirebaseBootstrap.instance.ready.value; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted) return;
    }
    final u = await AppUpdateService.instance.check();
    if (mounted) setState(() => _update = u);
  }

  @override
  Widget build(BuildContext context) {
    final u = _update;
    final show = u != null && (u.mandatory || !_skipped);
    // التطبيق يبقى حيًا خلف الشاشة (لا تضيع حالة التنقل عند «تخطي»)، وشاشة التحديث تغطي الشاشة بالكامل
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(offstage: show, child: TickerMode(enabled: !show, child: widget.child)),
        if (show) Positioned.fill(child: AppUpdateScreen(update: u, onSkip: () => setState(() => _skipped = true))),
      ],
    );
  }
}
