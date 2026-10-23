import '../services/api_functions.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../models/meeting.dart';
import '../services/meeting_service.dart';

class MeetingScreen extends StatelessWidget {
  final String requestId;
  const MeetingScreen({super.key, required this.requestId});

  bool _isParticipant(Map<String, dynamic> d) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return uid != null && (d['mustafhemId'] == uid || d['mufhemId'] == uid);
  }

  /// المستفهم يشاهد التسجيل المحفوظ لو اتفق الطرفان على نفس مدة الحفظ.
  bool _savedForMe(Map<String, dynamic> d) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final r = d['retention'];
    if (uid == null || d['mustafhemId'] != uid || r is! Map) return false;
    final a = r['mustafhem'], b = r['mufhem'];
    return a is num && b is num && a > 0 && a == b;
  }

  Future<void> _complain(BuildContext context) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تقديم شكوى على الجلسة'),
        content: TextField(controller: c, maxLines: 4, maxLength: 800, decoration: const InputDecoration(labelText: 'اكتب تفاصيل الشكوى')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('إرسال للإدارة')),
        ],
      ),
    );
    if (ok != true || c.text.trim().isEmpty || !context.mounted) return;
    try {
      await FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable('fileSessionComplaint').call<Map<String, dynamic>>({'requestId': requestId, 'text': c.text.trim()});
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم إرسال الشكوى، ستراجع الإدارة تسجيل الجلسة')));
    } on FirebaseFunctionsException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message ?? 'تعذر إرسال الشكوى')));
    } catch (_) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر إرسال الشكوى')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('istifhams').doc(requestId).snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        final data = snap.data!.data();
        if (data == null) return const Scaffold(body: Center(child: Text('المحاضرة غير موجودة')));
        final meeting = Meeting.fromMap(requestId, data);
        final time = meeting.meetingTime;
        final now = DateTime.now();
        final canJoin = time != null && now.isAfter(time.subtract(const Duration(minutes: 5))) && now.isBefore(time.add(const Duration(hours: 6)));
        return Scaffold(
          appBar: AppBar(title: const Text('المحاضرة المباشرة')),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.video_call, size: 80),
                  const SizedBox(height: 16),
                  Text(meeting.title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(time == null ? 'لم يتم تحديد الموعد' : time.toLocal().toString(), textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    // الزر يبقى مفعّلًا دائمًا: لو الدخول غير متاح يظهر السبب بدل الصمت
                    onPressed: () => MeetingService().joinFlow(context, meeting),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(canJoin ? 'دخول المحاضرة' : 'دخول المحاضرة (خارج الموعد)'),
                  ),
                  if (_isParticipant(data)) ...[
                    const SizedBox(height: 12),
                    if (_savedForMe(data))
                      OutlinedButton.icon(
                        onPressed: () => GoRouter.of(context).push('/group-video-session/$requestId'),
                        icon: const Icon(Icons.play_circle_outline),
                        label: const Text('مشاهدة التسجيل المحفوظ'),
                      ),
                    TextButton.icon(
                      onPressed: () => _complain(context),
                      icon: const Icon(Icons.report_gmailerrorred_outlined),
                      label: const Text('تقديم شكوى على الجلسة'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
