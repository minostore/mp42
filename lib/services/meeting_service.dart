import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:jitsi_meet_flutter_sdk/jitsi_meet_flutter_sdk.dart';
import 'api_functions.dart';
import 'firestore_service.dart';
import '../models/meeting.dart';
import 'error_center.dart';

class MeetingService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final JitsiMeet _jitsi = JitsiMeet();
  static const String _jaasRoomPrefix = 'vpaas-magic-cookie-4ddd1f4050174a1b89a6ce9a82ade034/Fahimni_';

  Stream<List<Meeting>> watchUserMeetings(String uid) {
    final a = _db.collection('istifhams').where('mustafhemId', isEqualTo: uid).where('status', whereIn: ['paid','completed']).snapshots();
    final b = _db.collection('istifhams').where('mufhemId', isEqualTo: uid).where('status', whereIn: ['paid','completed']).snapshots();
    // Merge is handled in the UI from the two streams; this method is kept for future aggregation.
    return a.map((s) => s.docs.map((d) => Meeting.fromMap(d.id, d.data())).toList());
  }

  Stream<QuerySnapshot<Map<String,dynamic>>> watchStudent(String uid) => _db.collection('istifhams').where('mustafhemId', isEqualTo: uid).where('status', whereIn: ['paid','completed']).snapshots();
  Stream<QuerySnapshot<Map<String,dynamic>>> watchTeacher(String uid) => _db.collection('istifhams').where('mufhemId', isEqualTo: uid).where('status', whereIn: ['paid','completed']).snapshots();

  static bool _busy = false;
  static const String _where = 'دخول المحاضرة';

  /// نقطة الدخول الوحيدة من الأزرار: تتحقق خطوة بخطوة وتعرض سبب أي فشل بدل الصمت.
  Future<void> joinFlow(BuildContext context, Meeting meeting) async {
    if (_busy) return;
    _busy = true;

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

    void fail(String title, String cause, String fix, {String tech = ''}) {
      close();
      ErrorCenter.instance.push(AppError(title: title, cause: cause, fix: fix, technical: tech, where: _where));
    }

    try {
      // 1) تسجيل الدخول
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        fail('لم تسجّل الدخول', 'لا يوجد مستخدم مسجّل حاليًا (انتهت الجلسة).', 'سجّل الخروج ثم الدخول من جديد.');
        return;
      }

      // 2) بيانات الحساب (لو غير موجودة نكمل ببيانات Firebase Auth بدل التوقف بصمت)
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
        close();
        ErrorCenter.instance.report(e, where: '$_where — قراءة بيانات الحساب', stack: st);
        return;
      }

      // 3) نافذة الدخول
      status.value = 'جارٍ التحقق من موعد المحاضرة...';
      final t = meeting.meetingTime;
      if (t == null) {
        fail('موعد المحاضرة غير محدد', 'الحقل meetingTime غير موجود أو بصيغة لا يفهمها التطبيق في مستند istifhams/${meeting.id}.',
            'حدّد موعد المحاضرة من لوحة الأدمن/المُفهّم ثم أعد المحاولة.', tech: 'meetingTime = null');
        return;
      }
      final now = DateTime.now();
      final opensAt = t.subtract(const Duration(minutes: 5));
      final closesAt = t.add(const Duration(hours: 6));
      if (!isAdmin && now.isBefore(opensAt)) {
        fail('لم يحن موعد المحاضرة بعد', 'الدخول يفتح قبل الموعد بـ 5 دقائق فقط.', 'ادخل بعد ${opensAt.toLocal()}.',
            tech: 'now=${now.toIso8601String()} opensAt=${opensAt.toIso8601String()}');
        return;
      }
      if (!isAdmin && now.isAfter(closesAt)) {
        fail('انتهت مدة الدخول للمحاضرة', 'مرّت أكثر من 6 ساعات على موعدها.', 'اطلب تحديد موعد جديد.',
            tech: 'now=${now.toIso8601String()} closesAt=${closesAt.toIso8601String()}');
        return;
      }

      // 4) التوكن + 5) تشغيل Jitsi
      status.value = 'جارٍ الحصول على تصريح الدخول...';
      final ok = await join(
        meeting,
        displayName: name.isEmpty ? 'مستخدم' : name,
        email: email,
        avatar: avatar,
        moderator: moderator,
        onStage: (s) => status.value = s,
      );
      close();
      if (!ok) return; // الخطأ ظهر بالفعل من داخل join
    } catch (e, st) {
      close();
      ErrorCenter.instance.report(e, where: _where, stack: st);
    } finally {
      close();
      _busy = false;
    }
  }

  /// يرجع true لو بدأ الاتصال فعلًا، و false بعد عرض سبب الفشل.
  Future<bool> join(Meeting meeting, {required String displayName, String? email, String? avatar, bool moderator = false, void Function(String)? onStage}) async {
    final room = 'Fahimni_${meeting.id}';
    String? token;
    try {
      final result = await FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable('getJaasMeetingToken').call({'room': room, 'requestId': meeting.id});
      token = result.data['token']?.toString();
    } catch (e, st) {
      ErrorCenter.instance.report(e, where: 'توكن الاجتماع (JaaS)', stack: st);
      return false;
    }
    if (token == null || token.isEmpty) {
      ErrorCenter.instance.push(AppError(
        title: 'السيرفر لم يرجع توكن الدخول',
        cause: 'الدالة getJaasMeetingToken ردّت بدون token (غالبًا متغيرات JAAS_* ناقصة أو الدالة على Vercel قديمة).',
        fix: 'راجع JAAS_APP_ID و JAAS_KEY_ID و JAAS_PRIVATE_KEY في بيئة الدوال ثم أعد النشر.',
        technical: 'token empty for room $room',
        where: _where,
      ));
      return false;
    }

    onStage?.call('جارٍ فتح غرفة الاجتماع...');
    final joined = Completer<void>();
    Timer? watchdog;
    void markStarted() {
      watchdog?.cancel();
      if (!joined.isCompleted) joined.complete();
    }

    final options = JitsiMeetConferenceOptions(
      room: '$_jaasRoomPrefix${meeting.id}',
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

    // لو لم يبدأ الاتصال خلال 30 ثانية نعرض السبب المحتمل بدل الصمت
    watchdog = Timer(const Duration(seconds: 30), () {
      if (joined.isCompleted) return;
      ErrorCenter.instance.push(AppError(
        title: 'لم تبدأ المحاضرة خلال 30 ثانية',
        cause: 'لم يصل من مكتبة Jitsi أي إشارة دخول: إنترنت ضعيف، أو صلاحيتا الكاميرا/المايك مرفوضتان، أو الـ SDK لم يُبنَ بشكل صحيح في هذه النسخة.',
        fix: 'تأكد من الإنترنت، وافتح إعدادات الهاتف ← التطبيقات ← مسار ← الأذونات وفعّل الكاميرا والميكروفون، ثم ثبّت نسخة جديدة من الـ APK وجرّب.',
        technical: 'no conferenceWillJoin/conferenceJoined within 30s, room=${options.room}',
        where: _where,
      ));
    });

    try {
      final dynamic res = await Future<dynamic>.sync(() => _jitsi.join(
            options,
            JitsiMeetEventListener(
              conferenceWillJoin: (url) => markStarted(),
              conferenceJoined: (url) => markStarted(),
              conferenceTerminated: (url, error) {
                markStarted();
                ErrorCenter.instance.reportMeetingError(error, where: 'المحاضرة');
              },
            ),
          ));
      // بعض إصدارات الـ SDK ترجع JitsiMeetingResponse فيها isSuccess/message
      try {
        if (res != null && res.isSuccess == false) {
          watchdog.cancel();
          ErrorCenter.instance.push(AppError(
            title: 'تعذّر فتح شاشة الاجتماع',
            cause: 'مكتبة Jitsi رفضت تشغيل الاتصال.',
            fix: 'أعد المحاولة، ولو تكرر ثبّت نسخة APK جديدة.',
            technical: 'message=${res.message} error=${res.error}',
            where: _where,
          ));
          return false;
        }
      } catch (_) {}
      return true;
    } catch (e, st) {
      watchdog.cancel();
      ErrorCenter.instance.report(e, where: '$_where — تشغيل Jitsi', stack: st);
      return false;
    }
  }
}
