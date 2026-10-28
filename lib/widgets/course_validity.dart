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
    final DateTime? endDate = exp == null ? null : DateTime.fromMillisecondsSinceEpoch(exp);
    final String text = endDate == null
        ? 'صلاحية الكورس: مدى الحياة'
        : 'ينتهي ${endDate.year}/${endDate.month}/${endDate.day} — ${_remaining(endDate.difference(DateTime.now().add(Duration(milliseconds: _serverOffsetMs))))}';
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


/// طلب إلغاء الاشتراك واسترداد المبلغ خلال 24 ساعة من الشراء (المهلة تُحسب بوقت الخادم ويتحقق منها السيرفر).
class CourseRefundSection extends StatefulWidget {
  final String courseId;
  const CourseRefundSection({super.key, required this.courseId});

  @override
  State<CourseRefundSection> createState() => _CourseRefundSectionState();
}

class _CourseRefundSectionState extends State<CourseRefundSection> {
  int _boughtAt = 0;
  int _offsetMs = 0;
  String? _refundStatus;
  String _refundNote = '';
  bool _loaded = false;
  bool _busy = false;

  static const _labels = {
    'pending': 'طلب الاسترداد قيد المراجعة',
    'approved': 'تم قبول طلب الاسترداد',
    'rejected': 'تم رفض طلب الاسترداد',
    'refunding': 'جارٍ تنفيذ الاسترداد',
    'refunded': 'تم استرداد المبلغ',
    'refund_failed': 'فشل الاسترداد — تواصل مع الدعم',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final db = FirebaseFirestore.instance;
    try {
      final p = await db.collection('purchases').doc('${uid}_${widget.courseId}').get();
      final b = p.data()?['purchasedAtMs'];
      if (b is num) _boughtAt = b.toInt();
    } catch (_) {}
    try {
      final r = await db.collection('refundRequests').doc('${uid}_${widget.courseId}').get();
      if (r.exists) {
        _refundStatus = (r.data()?['status'] ?? 'pending').toString();
        _refundNote = (r.data()?['rejectionReason'] ?? '').toString();
      }
    } catch (_) {}
    try {
      final t = await FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable('getMyIp').call<Map<String, dynamic>>().timeout(const Duration(seconds: 6));
      final sn = t.data['serverNow'];
      if (sn is num) _offsetMs = sn.toInt() - DateTime.now().millisecondsSinceEpoch;
    } catch (_) {}
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _request() async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('طلب إلغاء الاشتراك واسترداد المبلغ'),
        content: TextField(controller: c, maxLines: 3, decoration: const InputDecoration(labelText: 'السبب (اختياري)')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('رجوع')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('إرسال الطلب')),
        ],
      ),
    );
    final reason = c.text.trim();
    c.dispose();
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable('requestCourseRefund').call<Map<String, dynamic>>({'courseId': widget.courseId, 'reason': reason});
      _refundStatus = 'pending';
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم إرسال طلب الاسترداد')));
    } on FirebaseFunctionsException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message ?? 'تعذر إرسال الطلب')));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر إرسال الطلب')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    if (_refundStatus != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text('${_labels[_refundStatus] ?? _refundStatus}${_refundNote.isEmpty ? '' : ': $_refundNote'}', style: const TextStyle(fontWeight: FontWeight.w800)),
      );
    }
    if (_boughtAt <= 0) return const SizedBox.shrink(); // مشتريات قديمة بلا وقت شراء مسجّل
    final nowMs = DateTime.now().millisecondsSinceEpoch + _offsetMs;
    final leftMs = _boughtAt + 24 * 3600 * 1000 - nowMs;
    if (leftMs <= 0) {
      return const Padding(padding: EdgeInsets.only(top: 10), child: Text('انتهت مهلة طلب الاسترداد (24 ساعة من الشراء)', style: TextStyle(color: AppColors.muted)));
    }
    final h = (leftMs / 3600000).ceil();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: OutlinedButton.icon(
        onPressed: _busy ? null : _request,
        icon: const Icon(Icons.undo),
        label: Text('طلب إلغاء الاشتراك واسترداد المبلغ (متبقي $h ساعة)'),
      ),
    );
  }
}
