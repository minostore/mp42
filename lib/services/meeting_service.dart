import 'dart:async';
import 'dart:io' show InternetAddress;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jitsi_meet_flutter_sdk/jitsi_meet_flutter_sdk.dart';
import 'api_functions.dart';
import 'firestore_service.dart';
import 'jaas_token_inspector.dart';
import '../models/meeting.dart';
import 'error_center.dart';

class MeetingService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final JitsiMeet _jitsi = JitsiMeet();

  /// يُستخدم فقط لو السيرفر لم يرجع appId/room في رده.
  static const String _fallbackAppId = 'vpaas-magic-cookie-4ddd1f4050174a1b89a6ce9a82ade034';

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
        meeting,
        status,
        // أخطاء تحدث متأخرًا (بعد فتح شاشة Jitsi): تظهر عند رجوع المستخدم للتطبيق
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
  Future<AppError?> _run(Meeting listed, ValueNotifier<String> status, void Function(AppError) onLateError) async {
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

    // 5) الاتصال بخوادم الاجتماعات
    status.value = 'جارٍ فحص الاتصال بخوادم الاجتماعات...';
    try {
      final r = await InternetAddress.lookup('8x8.vc').timeout(const Duration(seconds: 8));
      if (r.isEmpty) throw StateError('DNS returned no address for 8x8.vc');
    } on TimeoutException {
      return _err('خوادم الاجتماعات لا تستجيب', 'الجهاز لم يستطع الوصول إلى 8x8.vc خلال 8 ثوانٍ (إنترنت ضعيف جدًا).',
          'جرّب شبكة أخرى (واي فاي/بيانات) ثم أعد المحاولة.', tech: 'DNS lookup 8x8.vc timeout');
    } catch (e) {
      return _err('لا يوجد اتصال بخوادم الاجتماعات', 'الجهاز لا يستطيع الوصول إلى 8x8.vc: الإنترنت مقطوع، أو الشبكة/VPN/DNS تحجب هذا الدومين.',
          'تأكد من الإنترنت، وأوقف أي VPN أو DNS خاص وجرّب شبكة أخرى.', tech: e.toString());
    }

    // 6) التوكن
    status.value = 'جارٍ الحصول على تصريح الدخول...';
    final roomName = 'Fahimni_${meeting.id}';
    dynamic resp;
    try {
      final result = await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('getJaasMeetingToken')
          .call<dynamic>({'room': roomName, 'requestId': meeting.id});
      resp = result.data;
    } catch (e, st) {
      return ErrorCenter.explain(e, where: 'توكن الاجتماع (JaaS)', stack: st);
    }
    final map = resp is Map ? resp : const {};
    final token = (map['token'] ?? '').toString();
    if (token.isEmpty) {
      return _err('السيرفر لم يرجع توكن الدخول',
          'الدالة getJaasMeetingToken ردّت بدون token (غالبًا متغيرات JAAS_* ناقصة أو الدالة على Vercel قديمة).',
          'راجع JAAS_APP_ID و JAAS_KEY_ID و JAAS_PRIVATE_KEY في بيئة الدوال ثم أعد النشر.',
          tech: 'response=${resp is Map ? 'keys=${resp.keys.toList()}' : resp.runtimeType}', where: 'توكن الاجتماع (JaaS)');
    }

    // نستخدم appId/room كما أرجعهما السيرفر؛ هذا يمنع اختلاف الـ App ID بين التطبيق والسيرفر.
    final serverRoom = (map['room'] ?? '').toString();
    final serverAppId = (map['appId'] ?? '').toString();
    final String fullRoom;
    if (serverRoom.contains('/')) {
      fullRoom = serverRoom;
    } else {
      fullRoom = '${serverAppId.isNotEmpty ? serverAppId : _fallbackAppId}/$roomName';
    }
    final slash = fullRoom.indexOf('/');
    final appIdInRoom = fullRoom.substring(0, slash);
    final bareRoom = fullRoom.substring(slash + 1);

    // 7) فحص التوكن محليًا قبل فتح Jitsi
    final report = JaasTokenInspector.inspect(token, expectedAppId: appIdInRoom, roomName: bareRoom);
    if (report.isBlocking) {
      return _err('التوكن غير صالح لدخول هذا الاجتماع',
          report.blocking.join('\n'),
          'المشكلة في إعدادات السيرفر (JAAS_APP_ID / JAAS_KEY_ID / JAAS_PRIVATE_KEY). صحّحها ثم Redeploy وجرّب.',
          tech: report.summary, where: 'توكن الاجتماع (JaaS)');
    }

    // 8) تشغيل Jitsi
    status.value = 'جارٍ فتح غرفة الاجتماع...';
    return _launch(
      room: fullRoom,
      token: token,
      displayName: name.isEmpty ? 'مستخدم' : name,
      email: email,
      avatar: avatar,
      moderator: moderator,
      report: report,
      onLateError: onLateError,
    );
  }

  Future<AppError?> _launch({
    required String room,
    required String token,
    required String displayName,
    String? email,
    String? avatar,
    required bool moderator,
    required JaasTokenReport report,
    required void Function(AppError) onLateError,
  }) async {
    var willJoin = false;
    var joined = false;
    final launchedAt = DateTime.now();

    final options = JitsiMeetConferenceOptions(
      room: room,
      token: token,
      serverURL: 'https://8x8.vc',
      configOverrides: {
        'prejoinPageEnabled': false,
        'disableInviteFunctions': true,
        'startWithAudioMuted': false,
        'startWithVideoMuted': false,
      },
      featureFlags: {
        FeatureFlags.recordingEnabled: moderator,
        FeatureFlags.androidScreenSharingEnabled: false,
        FeatureFlags.iosScreenSharingEnabled: false,
      },
      userInfo: JitsiMeetUserInfo(displayName: displayName, email: email, avatar: avatar),
    );

    // لو لم يكتمل الدخول خلال 30 ثانية نعرض السبب المحتمل بدل الصمت
    final Timer watchdog = Timer(const Duration(seconds: 30), () {
      if (joined) return;
      onLateError(AppError(
        title: willJoin ? 'بدأ الاتصال بالغرفة ولم يكتمل' : 'لم تبدأ المحاضرة خلال 30 ثانية',
        cause: willJoin
            ? 'Jitsi بدأ الدخول لكن الاتصال لم يكتمل: إنترنت ضعيف، أو JaaS لم يقبل التوكن/الغرفة، أو الغرفة معلّقة لحين دخول المُفهّم.${_hints(report)}'
            : 'لم تصل من Jitsi أي إشارة دخول: إنترنت ضعيف، أو صلاحيتا الكاميرا/المايك مرفوضتان، أو الـ SDK لم يُبنَ بشكل صحيح في هذه النسخة.${_hints(report)}',
        fix: 'تأكد من الإنترنت، وافتح إعدادات الهاتف ← التطبيقات ← مسار ← الأذونات وفعّل الكاميرا والميكروفون، ثم ثبّت نسخة جديدة من الـ APK وجرّب.',
        technical: 'willJoin=$willJoin joined=$joined room=$room | ${report.summary}',
        where: _where,
      ));
    });

    try {
      final dynamic res = await Future<dynamic>.sync(() => _jitsi.join(
            options,
            JitsiMeetEventListener(
              conferenceWillJoin: (url) {
                willJoin = true;
              },
              conferenceJoined: (url) {
                joined = true;
                watchdog.cancel();
              },
              conferenceTerminated: (url, error) {
                watchdog.cancel();
                final text = (error ?? '').toString().trim();
                if (text.isNotEmpty) {
                  onLateError(ErrorCenter.explainMeetingError(error, where: 'المحاضرة', hints: report.warnings));
                } else if (!joined) {
                  final secs = DateTime.now().difference(launchedAt).inSeconds;
                  onLateError(AppError(
                    title: 'أُغلقت شاشة الاجتماع قبل الدخول',
                    cause: 'Jitsi أنهى الاتصال بعد $secs ثانية بدون أي رسالة خطأ. أشهر الأسباب: JaaS رفض التوكن أو الغرفة، أو انقطع الإنترنت لحظة الدخول.${_hints(report)}',
                    fix: 'أعد المحاولة مرة. لو تكرر انسخ التفاصيل وأرسلها للمطوّر، وراجع JaaS Console ← Usage/Logs.',
                    technical: 'terminated before conferenceJoined (willJoin=$willJoin) url=$url room=$room | ${report.summary}',
                    where: _where,
                  ));
                }
                // لو دخل ثم خرج بدون خطأ فهذا خروج عادي، لا نعرض شيئًا.
              },
            ),
          )).timeout(const Duration(seconds: 25));

      // بعض إصدارات الـ SDK ترجع JitsiMeetingResponse فيها isSuccess/message
      try {
        if (res != null && res.isSuccess == false) {
          watchdog.cancel();
          return AppError(
            title: 'تعذّر فتح شاشة الاجتماع',
            cause: 'مكتبة Jitsi رفضت تشغيل الاتصال.',
            fix: 'أعد المحاولة، ولو تكرر ثبّت نسخة APK جديدة.',
            technical: 'message=${res.message} error=${res.error}',
            where: _where,
          );
        }
      } catch (_) {}
      return null;
    } on TimeoutException {
      watchdog.cancel();
      return _err('مكتبة Jitsi لم ترد على أمر التشغيل',
          'أمر join لم يرجع خلال 25 ثانية. غالبًا الـ plugin لم يُبنَ داخل الـ APK بشكل سليم أو الـ Activity لم تُفتح.',
          'نفّذ flutter clean ثم ابنِ APK جديد وثبّته، وتأكد أن الأذونات (كاميرا/مايك) مفعّلة.',
          tech: 'JitsiMeet.join timeout room=$room');
    } catch (e, st) {
      watchdog.cancel();
      return ErrorCenter.explain(e, where: '$_where — تشغيل Jitsi', stack: st);
    }
  }

  static String _hints(JaasTokenReport r) =>
      r.warnings.isEmpty ? '' : '\nملاحظات فحص التوكن: ${r.warnings.join(' | ')}';
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
