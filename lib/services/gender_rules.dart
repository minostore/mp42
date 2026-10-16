import 'package:cloud_firestore/cloud_firestore.dart';

/// قاعدة الجنس في الاستفهامات: الذكر لا يقدّم عرضًا لمستفهمة، والأنثى لا تقدّم عرضًا لمستفهم.
/// (القاعدة نفسها مفروضة في firestore.rules من جهة الخادم، وهذا فحص مبكر لرسالة واضحة.)
class GenderRules {
  static Future<String> genderOf(String uid) async {
    final d = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    return (d.data()?['gender'] ?? '').toString();
  }

  /// يرجّع null لو مسموح، وإلا رسالة السبب.
  static Future<String?> offerBlockReason({required String mufhemUid, required String mustafhemUid}) async {
    final a = await genderOf(mufhemUid);
    final b = await genderOf(mustafhemUid);
    if (a.isEmpty || b.isEmpty) return null; // حسابات قديمة بدون جنس: لا نمنع
    if (a != b) {
      return b == 'female'
          ? 'لا يمكنك تقديم عرض على هذا الاستفهام: صاحبته مستفهمة، ويقتصر التفهيم على نفس الجنس.'
          : 'لا يمكنك تقديم عرض على هذا الاستفهام: صاحبه مستفهم، ويقتصر التفهيم على نفس الجنس.';
    }
    return null;
  }
}
