import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/api_functions.dart';
import '../theme/app_theme.dart';

/// نص صلاحية الكورس قبل الشراء، من حقول الكورس: lifetime / validityValue / validityUnit.
String courseValidityLabel(Map<String, dynamic> raw) {
  final v = raw['validityValue'];
  final unit = (raw['validityUnit'] ?? '').toString();
  final n = v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
  if (raw['lifetime'] == true || n < 1) return 'مدى الحياة';
  const names = {'day': 'يوم', 'month': 'شهر', 'year': 'سنة'};
  final u = names[unit];
  return u == null ? 'مدى الحياة' : '$n $u';
}

/// بعد الشراء: عدّ تنازلي بالمدة المتبقية من صلاحية الكورس (أو «مدى الحياة»).
class CourseValidityCountdown extends StatefulWidget {
  final String courseId;
  const CourseValidityCountdown({super.key, required this.courseId});

  @override
  State<CourseValidityCountdown> createState() => _CourseValidityCountdownState();
}

class _CourseValidityCountdownState extends State<CourseValidityCountdown> {
  Timer? _t;
  int? _expiresMs; // null = مدى الحياة / غير معروف
  int _serverOffsetMs = 0; // فرق وقت الخادم عن ساعة الجهاز (العد التنازلي بوقت الخادم)
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
    _t = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final d = await FirebaseFirestore.instance.collection('purchases').doc('${uid}_${widget.courseId}').get();
      try {
        final t = await FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable('getMyIp').call<Map<String, dynamic>>().timeout(const Duration(seconds: 6));
        final sn = t.data['serverNow'];
        if (sn is num) _serverOffsetMs = sn.toInt() - DateTime.now().millisecondsSinceEpoch;
      } catch (_) {}
      final e = d.data()?['expiresAt'];
      if (e is num && e > 0) _expiresMs = e.toInt();
    } catch (_) {}
    if (mounted) setState(() => _loaded = true);
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  String _remaining(Duration d) {
    if (d.isNegative) return 'انتهت الصلاحية';
    final days = d.inDays;
    final hours = d.inHours % 24;
    final mins = d.inMinutes % 60;
    if (days >= 1) return 'متبقي $days يوم و$hours ساعة';
    return 'متبقي $hours ساعة و$mins دقيقة';
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final exp = _expiresMs;
    final text = exp == null ? 'صلاحية الكورس: مدى الحياة' : 'صلاحية الكورس — ${_remaining(DateTime.fromMillisecondsSinceEpoch(exp).difference(DateTime.now().add(Duration(milliseconds: _serverOffsetMs))))}';
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        const Icon(Icons.timer_outlined, color: AppColors.accent, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(fontWeight: FontWeight.w800))),
      ]),
    );
  }
}
