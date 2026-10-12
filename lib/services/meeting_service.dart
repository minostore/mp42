import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'api_functions.dart';
import 'firestore_service.dart';
import '../models/meeting.dart';
import 'error_center.dart';
import '../screens/agora_meeting_room.dart';

class MeetingService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Stream<List<Meeting>> watchUserMeetings(String uid) {
    final a = _db.collection('istifhams').where('mustafhemId', isEqualTo: uid).where('status', whereIn: ['paid','completed']).snapshots();
    // Merge is handled in the UI from the two streams; this method is kept for future aggregation.
    return a.map((s) => s.docs.map((d) => Meeting.fromMap(d.id, d.data())).toList());
  }

  Stream<QuerySnapshot<Map<String,dynamic>>> watchStudent(String uid) => _db.collection('istifhams').where('mustafhemId', isEqualTo: uid).where('status', whereIn: ['paid','completed']).snapshots();
  Stream<QuerySnapshot<Map<String,dynamic>>> watchTeacher(String uid) => _db.collection('istifhams').where('mufhemId', isEqualTo: uid).where('status', whereIn: ['paid','completed']).snapshots();

  static bool _busy = false;
  static DateTime _busySince = DateTime.fromMillisecondsSinceEpoch(0);
  static const String _where = 'دخول المحاضرة';

  // ───────────────────────── أدوات مساعدة ─────────────────────────

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _fmt(DateTime d) {
    final l = d.toLocal();
    return '${l.year}/${_two(l.month)}/${_two(l.day)}  ${_two(l.hour)}:${_two(l.minute)}';
  }

  static String _dur(Duration d) {
    final days = d.inDays;
    final hours = d.inHours % 24;
    final mins = d.inMinutes % 60;
    final parts = <String>[
      if (days > 0) '$days يوم',
      if (hours > 0) '$hours ساعة',
      if (mins > 0 || (days == 0 && hours == 0)) '$mins دقيقة',
    ];
    return parts.join(' و ');
  }

  /// يشيل بطاقات ErrorCenter التي ظهرت أثناء هذه العملية، لأن نافذة الخطأ تعرض نفس السبب.
  static void _dropCardsSince(Set<String> before) {
    final c = ErrorCenter.instance;
    c.errors.value = c.errors.value.where((e) => before.contains(e.id)).toList();
  }

  Future<void> _present(BuildContext context, AppError err, {Set<String> cardsBefore = const {}}) async {
    debugPrint('[دخول المحاضرة] ${err.toReport()}');
    _dropCardsSince(cardsBefore);
    if (!context.mounted) {
      // الشاشة اتقفلت: نعرضه في البطاقة الحمراء العامة بدل ما يضيع.
      ErrorCenter.instance.push(err);
      return;
    }
    try {
      await showDialog<void>(
        context: context,
        useRootNavigator: true,
        builder: (_) => _MeetingErrorDialog(error: err),
      );
    } catch (_) {
      ErrorCenter.instance.push(err);
    }
  }

  // ───────────────────────── نقطة الدخول الوحيدة ─────────────────────────

  /// تتحقق خطوة بخطوة، ولو فشل أي شيء تعرض نافذة فيها السبب الحقيقي والمطلوب للحل.
  Future<void> joinFlow(BuildContext context, Meeting meeting) async {
    if (_busy && DateTime.now().difference(_busySince) < const Duration(seconds: 90)) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('جارٍ تجهيز الدخول... انتظر لحظة')));
      return;
    }
    _busy = true;
    _busySince = DateTime.now();

    final cardsBefore = ErrorCenter.instance.errors.value.map((e) => e.id).toSet();
    final status = ValueNotifier<String>('جارٍ التحقق من الحساب...');
    final nav = Navigator.of(context, rootNavigator: true);
    var open = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(children: [
            const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(width: 16),
            Expanded(child: ValueListenableBuilder<String>(valueListenable: status, builder: (_, v, __) => Text(v))),
          ]),
        ),
      ),
    );
    void close() {
      if (open) {
        open = false;
        if (nav.canPop()) nav.pop();
      }
    }

    AppError? err;
    try {
      err = await _run(
        context,
        meeting,
        status,
        // أخطاء تحدث متأخرًا (بعد فتح شاشة Agora): تظهر عند رجوع المستخدم للتطبيق
        (late) => _present(context, late, cardsBefore: cardsBefore),
      );
    } catch (e, st) {
      err = ErrorCenter.explain(e, where: _where, stack: st);
    } finally {
      close();
      _busy = false;
    }
    if (err != null) await _present(context, err, cardsBefore: cardsBefore);
  }

  // ───────────────────────── خطوات التحقق ─────────────────────────

  AppError _err(String title, String cause, String fix, {String tech = '', String? where}) =>
      AppError(title: title, cause: cause, fix: fix, technical: tech, where: where ?? _where);

  /// يرجع null لو بدأ الاتصال فعلًا، أو AppError فيه السبب الحقيقي.
  Future<AppError?> _run(BuildContext context, Meeting listed, ValueNotifier<String> status, void Function(AppError) onLateError) async {
    // 1) تسجيل الدخول
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return _err('لم تسجّل الدخول', 'لا يوجد مستخدم مسجّل حاليًا (انتهت الجلسة).', 'سجّل الخروج ثم الدخول من جديد.');
    }

    // 2) بيانات الحساب
    var name = (user.displayName ?? '').trim();
    String? email = user.email;
    String? avatar = user.photoURL;
    var moderator = false;
    var isAdmin = false;
    try {
      final p = await FirestoreService().getUserProfile(user.uid).timeout(const Duration(seconds: 10));
      if (p != null) {
        if (p.name.isNotEmpty) name = p.name;
        if (p.email.isNotEmpty) email = p.email;
        if (p.photoUrl.isNotEmpty) avatar = p.photoUrl;
        isAdmin = p.isAdmin;
        moderator = p.isAdmin || p.isMofahhem;
      }
    } catch (e, st) {
      return ErrorCenter.explain(e, where: '$_where — قراءة بيانات الحساب', stack: st);
    }

    // 3) المحاضرة نفسها: نقرأ أحدث نسخة من السيرفر (القائمة ممكن تكون قديمة)
    status.value = 'جارٍ التأكد من وجود المحاضرة...';
    DocumentSnapshot<Map<String, dynamic>> snap;
    try {
      snap = await _db.collection('istifhams').doc(listed.id).get().timeout(const Duration(seconds: 12));
    } catch (e, st) {
      return ErrorCenter.explain(e, where: '$_where — قراءة المحاضرة', stack: st);
    }
    final data = snap.data();
    if (!snap.exists || data == null) {
      return _err('المحاضرة غير موجودة', 'المستند istifhams/${listed.id} غير موجود (اتحذف أو الرقم غلط).',
          'حدّث قائمة المحاضرات. لو ظهرت لك رغم ذلك بلّغ الإدارة.', tech: 'istifhams/${listed.id} exists=false');
    }
    final Meeting meeting;
    try {
      meeting = Meeting.fromMap(listed.id, data);
    } catch (e, st) {
      return ErrorCenter.explain(e, where: '$_where — بيانات المحاضرة تالفة', stack: st);
    }

    final isParticipant = user.uid == meeting.mustafhemId || user.uid == meeting.mufhemId;
    if (!isParticipant && !isAdmin) {
      return _err('لست من أطراف هذه المحاضرة', 'حسابك ليس هو الطالب ولا المُفهّم المسجّل في هذه المحاضرة.',
          'تأكد أنك مسجّل بالحساب الصحيح (الذي دفع/الذي قبل الطلب).',
          tech: 'uid=${user.uid} mustafhemId=${meeting.mustafhemId} mufhemId=${meeting.mufhemId}');
    }
    if (!isAdmin && meeting.status == 'completed') {
      return _err('المحاضرة منتهية', 'حالة الطلب completed، أي أنها أُغلقت بعد انتهائها.',
          'اطلب محاضرة جديدة أو موعدًا جديدًا.', tech: 'status=completed');
    }
    if (!isAdmin && meeting.status != 'paid') {
      return _err('المحاضرة غير مفعّلة', 'حالة الطلب "${meeting.status}" وليست paid، يعني الدفع لم يكتمل أو لم يُؤكَّد.',
          'أكمل الدفع أو انتظر تأكيده، ثم أعد المحاولة.', tech: 'status=${meeting.status}');
    }

    // 4) الموعد
    status.value = 'جارٍ التحقق من موعد المحاضرة...';
    final t = meeting.meetingTime;
    if (t == null) {
      return _err('موعد المحاضرة غير محدد',
          'الحقل meetingTime غير موجود أو بصيغة لا يفهمها التطبيق في istifhams/${meeting.id}.',
          'حدّد موعد المحاضرة من لوحة الأدمن/المُفهّم ثم أعد المحاولة.', tech: 'meetingTime=${data['meetingTime']} (${data['meetingTime'].runtimeType})');
    }
    final now = DateTime.now();
    final opensAt = t.subtract(const Duration(minutes: 5));
    final closesAt = t.add(const Duration(hours: 6));
    if (!isAdmin && now.isBefore(opensAt)) {
      return _err('لم يحن موعد المحاضرة بعد',
          'موعدها ${_fmt(t)} والدخول يفتح قبله بـ 5 دقائق فقط. المتبقي على فتح الدخول: ${_dur(opensAt.difference(now))}.',
          'ادخل بعد ${_fmt(opensAt)}. لو الوقت عندك غلط اضبط التاريخ والوقت على تلقائي.',
          tech: 'now=${now.toIso8601String()} opensAt=${opensAt.toIso8601String()}');
    }
    if (!isAdmin && now.isAfter(closesAt)) {
      return _err('انتهت مدة الدخول للمحاضرة',
          'موعدها كان ${_fmt(t)} وقد مرّ أكثر من 6 ساعات (مرّ ${_dur(now.difference(t))}).',
          'اطلب تحديد موعد جديد. لو الوقت عندك غلط اضبط التاريخ والوقت على تلقائي.',
          tech: 'now=${now.toIso8601String()} closesAt=${closesAt.toIso8601String()}');
    }

    // 5) طلب Agora RTC Token من الخادم (لا يُرسل App Certificate إلى التطبيق).
    status.value = 'جارٍ تجهيز اتصال Agora...';
    dynamic resp;
    try {
      final result = await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('getAgoraMeetingToken')
          .call<dynamic>({'requestId': meeting.id});
      resp = result.data;
    } catch (e, st) {
      return ErrorCenter.explain(e, where: 'توكن الاجتماع (Agora)', stack: st);
    }

    final map = resp is Map ? resp : const {};
    final appId = (map['appId'] ?? '').toString().trim();
    final channel = (map['channel'] ?? '').toString().trim();
    final token = (map['token'] ?? '').toString().trim();
    final uidValue = map['uid'];
    final int agoraUid = uidValue is num ? uidValue.toInt() : int.tryParse('$uidValue') ?? 0;

    if (appId.isEmpty || channel.isEmpty || token.isEmpty || agoraUid <= 0) {
      return _err(
        'بيانات Agora غير مكتملة',
        'الخادم لم يُرجع appId أو channel أو token أو uid صالحًا.',
        'أضف AGORA_APP_ID وAGORA_APP_CERTIFICATE إلى بيئة Firebase Functions ثم أعد نشر الدوال.',
        tech: 'responseKeys=${map is Map ? map.keys.toList() : resp.runtimeType}',
        where: 'توكن الاجتماع (Agora)',
      );
    }

    // 6) فتح غرفة Agora داخل التطبيق.
    status.value = 'جارٍ فتح غرفة المحاضرة...';
    try {
      await Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute(
          builder: (_) => AgoraMeetingRoom(
            appId: appId,
            channel: channel,
            token: token,
            uid: agoraUid,
            displayName: name.isEmpty ? 'مستخدم' : name,
            moderator: moderator,
          ),
        ),
      );
      return null;
    } catch (e, st) {
      return ErrorCenter.explain(e, where: 'تشغيل Agora RTC', stack: st);
    }
  }

}

/// نافذة تعرض السبب الحقيقي والمطلوب للحل، مع نسخ التفاصيل.
class _MeetingErrorDialog extends StatefulWidget {
  final AppError error;
  const _MeetingErrorDialog({required this.error});
  @override
  State<_MeetingErrorDialog> createState() => _MeetingErrorDialogState();
}

class _MeetingErrorDialogState extends State<_MeetingErrorDialog> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.error;
    return AlertDialog(
      icon: const Icon(Icons.error_outline, color: Color(0xFFB91C1C), size: 36),
      title: Text(e.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFFB91C1C))),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if ((e.cause ?? '').isNotEmpty)
              Text.rich(TextSpan(children: [
                const TextSpan(text: 'السبب: ', style: TextStyle(fontWeight: FontWeight.w800)),
                TextSpan(text: e.cause),
              ])),
            if ((e.fix ?? '').isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: const Color(0xFFECFDF5), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFA7F3D0))),
                child: Text.rich(TextSpan(children: [
                  const TextSpan(text: 'المطلوب: ', style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF065F46))),
                  TextSpan(text: e.fix, style: const TextStyle(color: Color(0xFF064E3B))),
                ])),
              ),
            ],
            if (e.technical.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(8)),
                child: SelectableText(e.technical, textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 10.5, fontFamily: 'monospace')),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: e.toReport()));
            if (mounted) setState(() => _copied = true);
          },
          icon: Icon(_copied ? Icons.check : Icons.copy, size: 16),
          label: Text(_copied ? 'تم النسخ' : 'نسخ التفاصيل'),
        ),
        FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('حسنًا')),
      ],
    );
  }
}
