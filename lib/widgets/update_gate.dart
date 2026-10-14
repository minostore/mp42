import 'package:flutter/material.dart';

import '../screens/app_update_screen.dart';
import '../services/app_update_service.dart';

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
    if (state == AppLifecycleState.resumed && (_update?.mandatory ?? true)) _check();
  }

  Future<void> _check() async {
    final u = await AppUpdateService.instance.check();
    if (mounted) setState(() => _update = u);
  }

  @override
  Widget build(BuildContext context) {
    final u = _update;
    if (u != null && (u.mandatory || !_skipped)) {
      return AppUpdateScreen(update: u, onSkip: () => setState(() => _skipped = true));
    }
    return widget.child;
  }
}
