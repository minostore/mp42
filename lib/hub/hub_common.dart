import '../services/api_functions.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_theme.dart';

/// نفس دومين منصة الويب. الصفحات التي تحتاج دفع (الدفع/المحفظة) تُفتح هناك فقط.
const String kWebBase = 'https://fahemt.online';

Future<void> openWebPage(BuildContext context, String path, {bool inApp = true}) async {
  final uri = Uri.parse('$kWebBase$path');
  final ok = await launchUrl(uri, mode: inApp ? LaunchMode.inAppBrowserView : LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر فتح الصفحة')));
  }
}

/// تاريخ الإنشاء في المنصة نص ISO، وقد يكون Timestamp في بعض السجلات.
DateTime? parseDate(dynamic v) {
  if (v == null) return null;
  if (v is Timestamp) return v.toDate();
  return DateTime.tryParse(v.toString());
}

String timeAgo(dynamic v) {
  final d = parseDate(v);
  if (d == null) return 'لحظات';
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 60) return '${diff.inMinutes < 1 ? 1 : diff.inMinutes} دقيقة';
  if (diff.inHours < 24) return '${diff.inHours} ساعة';
  return '${diff.inDays} يوم';
}

/// نفس تنسيق datetime-local المستخدم في الويب.
String webDateTime(DateTime d) => DateFormat("yyyy-MM-dd'T'HH:mm").format(d);

String prettyDateTime(dynamic v) {
  final d = parseDate(v);
  if (d == null) return v?.toString() ?? '-';
  return DateFormat('d/M/yyyy  h:mm a').format(d.toLocal());
}

String statusLabel(String s) {
  switch (s) {
    case 'pending_approval':
      return 'قيد المراجعة';
    case 'active':
      return 'مفتوح للعروض';
    case 'accepted':
      return 'بانتظار الدفع';
    case 'paid':
      return 'مدفوع وجاهز';
    case 'completed':
      return 'مكتمل';
    case 'canceled':
      return 'ملغي';
    default:
      return s;
  }
}

Color statusColor(String s) {
  switch (s) {
    case 'active':
      return AppColors.accent;
    case 'accepted':
      return const Color(0xFF2563EB);
    case 'paid':
    case 'completed':
      return const Color(0xFF16A34A);
    case 'canceled':
      return const Color(0xFFDC2626);
    default:
      return AppColors.muted;
  }
}

class StatusChip extends StatelessWidget {
  final String status;
  const StatusChip(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: c.withOpacity(.12), borderRadius: BorderRadius.circular(20)),
      child: Text(statusLabel(status), style: TextStyle(color: c, fontWeight: FontWeight.w700, fontSize: 12)),
    );
  }
}

class EmptyHint extends StatelessWidget {
  final IconData icon;
  final String text;
  const EmptyHint({super.key, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 56, color: AppColors.line),
            const SizedBox(height: 12),
            Text(text, style: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w700), textAlign: TextAlign.center),
          ]),
        ),
      );
}

/// دور الحساب في المنصة: users/{uid}.role  ->  mufhem | mustafhem
Stream<String> watchWebRole(String uid) => FirebaseFirestore.instance
    .collection('users')
    .doc(uid)
    .snapshots()
    .map((d) {
      final m = d.data() ?? const <String, dynamic>{};
      // role هو المرجع (التحويل بين الوضعين يكتبه)، وللحسابات القديمة بلا role نقرأ mode/accountType
      final r = (m['role'] ?? '').toString();
      if (r == 'mufhem' || r == 'mustafhem' || r == 'admin') return r;
      if (m['mode'] == 'mofahhem' || m['accountType'] == 'mofahhem') return 'mufhem';
      return 'mustafhem';
    });

/// تحويل الحساب بين مُفهم ومُستفهم: عبر السيرفر ليُحدَّث role وmode وaccountType معًا (متزامنة).
Future<void> setWebRole(String uid, String role) async {
  await FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable('switchAccountMode').call<Map<String, dynamic>>({'role': role});
}

/// اختيار تاريخ ووقت.
Future<DateTime?> pickDateTime(BuildContext context) async {
  final now = DateTime.now();
  final date = await showDatePicker(context: context, initialDate: now, firstDate: now, lastDate: now.add(const Duration(days: 365)));
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))));
  if (time == null) return null;
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}


/// رسالة خطأ مفهومة لأخطاء Firestore الشائعة (بدل عرض الخطأ الخام).
String friendlyError(Object? e) {
  final t = e.toString();
  if (t.contains('permission-denied')) {
    return 'لا توجد صلاحية قراءة لهذه البيانات.\nتأكد من نشر ملف firestore.rules المحدّث على Firebase.';
  }
  if (t.contains('failed-precondition') || t.contains('index')) {
    return 'هذا الاستعلام يحتاج فهرسًا (Index) في Firestore.\nافتح رابط إنشاء الفهرس الظاهر في سجل الخطأ.';
  }
  if (t.contains('unavailable') || t.contains('network')) return 'تعذر الاتصال بالإنترنت، حاول مرة أخرى.';
  return 'حدث خطأ غير متوقع.\n$t';
}
