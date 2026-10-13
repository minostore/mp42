import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../screens/agora_meeting_room.dart';
import 'api_functions.dart';
import 'agora_token_service.dart';
import 'error_center.dart';
import 'r2_worker_service.dart';

/// رابط مشاهدة مؤقت + بيانات العلامة المائية (من الخادم بعد التحقق من العضوية).
class GroupMedia {
  final String url;
  final String name;
  final String publicId;
  GroupMedia({required this.url, required this.name, required this.publicId});

  String get watermarkText => [name, publicId].where((e) => e.isNotEmpty).join(' • ');
}

/// المجموعات: القراءة من Firestore (قواعد الأمان تسمح للأعضاء فقط)، وكل رابط محتوى/اجتماع يمرّ عبر الخادم.
class GroupsService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  String? get uid => FirebaseAuth.instance.currentUser?.uid;

  Stream<QuerySnapshot<Map<String, dynamic>>> watchOwned(String uid) =>
      _db.collection('groups').where('ownerUid', isEqualTo: uid).snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> watchMemberships(String uid) =>
      _db.collection('users').doc(uid).collection('groupMemberships').snapshots();

  Future<DocumentSnapshot<Map<String, dynamic>>> getGroup(String id) => _db.collection('groups').doc(id).get();

  Stream<DocumentSnapshot<Map<String, dynamic>>> watchGroup(String id) => _db.collection('groups').doc(id).snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> watchContent(String groupId, String kind) =>
      _db.collection('groups').doc(groupId).collection(kind).orderBy('order', descending: true).snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> watchLiveSessions(String groupId) =>
      _db.collection('groups').doc(groupId).collection('sessions').where('status', isEqualTo: 'live').snapshots();

  Future<GroupMedia> _mediaFromDoc(DocumentReference<Map<String, dynamic>> ref) async {
    final snap = await ref.get();
    final key = (snap.data()?['r2Key'] ?? '').toString();
    if (key.isEmpty) throw Exception('المحتوى غير موجود');
    final uid = FirebaseAuth.instance.currentUser?.uid;
    var name = '', publicId = '';
    if (uid != null) {
      try {
        final me = (await _db.collection('users').doc(uid).get()).data() ?? {};
        name = (me['name'] ?? me['fullName'] ?? '').toString();
        publicId = (me['publicId'] ?? '').toString();
      } catch (_) {}
    }
    return GroupMedia(url: R2WorkerService.keyToUrl(key), name: name, publicId: publicId);
  }

  Future<GroupMedia> getMedia({required String groupId, required String kind, required String id}) async {
    try {
      final res = await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('getGroupMediaUrl')
          .call<Map<String, dynamic>>({'groupId': groupId, 'kind': kind, 'id': id}).timeout(const Duration(seconds: 8));
      final d = res.data;
      final wm = (d['watermark'] is Map) ? Map<String, dynamic>.from(d['watermark'] as Map) : <String, dynamic>{};
      return GroupMedia(url: (d['url'] ?? '').toString(), name: (wm['name'] ?? '').toString(), publicId: (wm['publicId'] ?? '').toString());
    } catch (_) {
      // دوال Firebase غير متاحة: القواعد تسمح بقراءة وثيقة المحتوى للأعضاء فقط، ثم نبني رابط Cloudflare.
      return _mediaFromDoc(_db.collection('groups').doc(groupId).collection(kind).doc(id));
    }
  }

  /// مشاهدة تسجيل من لوحة الأدمن.
  Future<GroupMedia> getAdminRecordingMedia(String id) async {
    try {
      final res = await FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable('getLectureRecordingUrl').call<Map<String, dynamic>>({'id': id}).timeout(const Duration(seconds: 8));
      final d = res.data;
      final wm = (d['watermark'] is Map) ? Map<String, dynamic>.from(d['watermark'] as Map) : <String, dynamic>{};
      return GroupMedia(url: (d['url'] ?? '').toString(), name: (wm['name'] ?? '').toString(), publicId: (wm['publicId'] ?? '').toString());
    } catch (_) {
      return _mediaFromDoc(_db.collection('lectureRecordings').doc(id));
    }
  }

  Future<Map<String, dynamic>> submitQuiz({required String groupId, required String quizId, required List<dynamic> answers}) async {
    final res = await FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('submitGroupQuiz')
        .call<Map<String, dynamic>>({'groupId': groupId, 'quizId': quizId, 'answers': answers});
    return res.data;
  }

  /// دخول جلسة مباشرة داخل التطبيق (Agora RTC). المُفهم صاحب المجموعة moderator.
  /// يرجع true لو كان المستخدم moderator والجلسة مسجلة (تنبيه فقط — تسجيل Agora يحتاج إعدادًا منفصلًا).
  Future<bool> joinSession({
    required BuildContext context,
    required String groupId,
    required String sessionId,
    required String displayName,
    String? email,
    String? avatar,
  }) async {
    final d = await AgoraTokenService.groupToken(groupId, sessionId);
    final appId = (d['appId'] ?? '').toString().trim();
    final channel = (d['channel'] ?? '').toString().trim();
    final token = (d['token'] ?? '').toString().trim();
    final uidValue = d['uid'];
    final agoraUid = uidValue is num ? uidValue.toInt() : int.tryParse('$uidValue') ?? 0;
    final moderator = d['moderator'] == true;
    final record = d['record'] == true;
    if (appId.isEmpty || channel.isEmpty || token.isEmpty || agoraUid <= 0) {
      throw Exception('[worker-v1] بيانات Agora غير مكتملة من Worker (${AgoraTokenService.workerUrl}). appId=${appId.length} channel=${channel.length} token=${token.length} uid=$agoraUid keys=${d.keys.toList()}');
    }
    if (!context.mounted) return false;
    await Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute(
        builder: (_) => AgoraMeetingRoom(
          appId: appId,
          channel: channel,
          token: token,
          uid: agoraUid,
          displayName: displayName,
          moderator: moderator,
        ),
      ),
    );
    return moderator && record;
  }
}
