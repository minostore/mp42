import 'package:cloud_firestore/cloud_firestore.dart';

/// قاعدة الجنس في الاستفهامات: الذكر لا يقدّم عرضًا لمستفهمة، والأنثى لا تقدّم عرضًا لمستفهم.
/// (القاعدة نفسها مفروضة في firestore.rules من جهة الخادم، وهذا فحص مبكر لرسالة واضحة.)
class GenderRules {
  static Future<String> genderOf(String uid) async {
    final d = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    return normalize((d.data()?['gender'] ?? '').toString());
  }

  /// يوحّد صيغ الجنس المختلفة (male/female/ذكر/أنثى) إلى male أو female أو ''.
  static String normalize(String g) {
    final v = g.trim().toLowerCase();
    if (v.isEmpty) return '';
    if (v.startsWith('f') || v.contains('أنث') || v.contains('انث')) return 'female';
    if (v.startsWith('m') || v.contains('ذكر')) return 'male';
    return '';
  }

  static const String blockedText = 'لا يمكنك تقديم عرض لهذا المستخدم';

  /// يرجّع null لو مسموح، وإلا رسالة السبب.
  static Future<String?> offerBlockReason({required String mufhemUid, required String mustafhemUid}) async {
    final a = await genderOf(mufhemUid);
    final b = await genderOf(mustafhemUid);
    if (a.isEmpty || b.isEmpty) return null; // حسابات قديمة بدون جنس: لا نمنع
    if (a != b) {
      return blockedText;
    }
    return null;
  }
}
