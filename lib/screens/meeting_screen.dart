import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../models/meeting.dart';
import '../services/meeting_service.dart';
import '../services/firestore_service.dart';
import '../services/error_center.dart';

class MeetingScreen extends StatefulWidget {
  final String requestId;
  const MeetingScreen({super.key, required this.requestId});

  @override
  State<MeetingScreen> createState() => _MeetingScreenState();
}

class _MeetingScreenState extends State<MeetingScreen> {
  bool _joining = false;
  String? _joinError;

  Future<void> _join(Meeting meeting) async {
    if (_joining) return;
    setState(() { _joining = true; _joinError = null; });
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('أنت غير مسجّل الدخول. سجّل الدخول ثم حاول مرة أخرى.');
      final profile = await FirestoreService().getUserProfile(user.uid);
      if (profile == null) throw Exception('تعذّر تحميل ملف حسابك من Firestore. تأكد من اتصال الإنترنت وصلاحية قراءة ملف المستخدم ثم أعد المحاولة.');
      await MeetingService().join(
        meeting,
        displayName: profile.name.isEmpty ? 'مستخدم' : profile.name,
        email: profile.email,
        avatar: profile.photoUrl,
        moderator: profile.isAdmin || profile.isMofahhem,
      );
    } catch (e, st) {
      final err = ErrorCenter.instance.report(e, where: 'دخول المحاضرة', stack: st);
      if (mounted) setState(() => _joinError = err.toReport());
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('istifhams').doc(widget.requestId).snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          final err = ErrorCenter.explain(snap.error!, where: 'تحميل بيانات المحاضرة');
          return Scaffold(appBar: AppBar(title: const Text('المحاضرة المباشرة')), body: _errorView(err.toReport()));
        }
        if (!snap.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        final data = snap.data!.data();
        if (data == null) return const Scaffold(body: Center(child: Text('المحاضرة غير موجودة أو تم حذفها')));
        final meeting = Meeting.fromMap(widget.requestId, data);
        final time = meeting.meetingTime;
        final now = DateTime.now();
        final canJoin = time != null && now.isAfter(time.subtract(const Duration(minutes: 5))) && now.isBefore(time.add(const Duration(hours: 6)));
        return Scaffold(
          appBar: AppBar(title: const Text('المحاضرة المباشرة')),
          body: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.video_call, size: 80),
                const SizedBox(height: 16),
                Text(meeting.title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(time == null ? 'لم يتم تحديد الموعد' : time.toLocal().toString(), textAlign: TextAlign.center),
                const SizedBox(height: 24),
                if (_joining) const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()),
                if (_joinError != null) _errorView(_joinError!),
                FilledButton.icon(
                  onPressed: canJoin && !_joining ? () => _join(meeting) : null,
                  icon: const Icon(Icons.play_arrow),
                  label: Text(_joining ? 'جارٍ الاتصال...' : canJoin ? 'دخول المحاضرة' : 'لم يبدأ الموعد بعد'),
                ),
                if (_joinError != null) TextButton.icon(onPressed: _joining ? null : () => _join(meeting), icon: const Icon(Icons.refresh), label: const Text('إعادة المحاولة')),
              ]),
            ),
          ),
        );
      },
    );
  }

  Widget _errorView(String details) => Container(
    width: double.infinity,
    margin: const EdgeInsets.symmetric(vertical: 12),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: Colors.red.withOpacity(.08), border: Border.all(color: Colors.red.shade300), borderRadius: BorderRadius.circular(12)),
    child: SelectableText(details, textDirection: TextDirection.rtl, style: const TextStyle(color: Colors.red, height: 1.5)),
  );
}
