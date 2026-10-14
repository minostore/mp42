import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'api_functions.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// تحديث متاح للتطبيق (من مجموعة appUpdates في Firestore).
class AppUpdateInfo {
  final String id;
  final String versionName;
  final int versionCode;
  final String title;
  final String description;
  final bool mandatory;
  final int apkSize;

  const AppUpdateInfo({
    required this.id,
    required this.versionName,
    required this.versionCode,
    required this.title,
    required this.description,
    required this.mandatory,
    required this.apkSize,
  });
}

class AppUpdateService {
  AppUpdateService._();
  static final AppUpdateService instance = AppUpdateService._();

  /// يرجّع التحديث المتاح (أو null). إذا فاتك تحديث إجباري وسيط يُعامل التحديث كإجباري.
  Future<AppUpdateInfo?> check() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final current = int.tryParse(info.buildNumber) ?? 0;
      // بدون where+orderBy معًا حتى لا نحتاج فهرسًا مركبًا
      final snap = await FirebaseFirestore.instance
          .collection('appUpdates')
          .orderBy('versionCode', descending: true)
          .limit(15)
          .get();
      final newer = snap.docs
          .where((d) => (d.data()['active'] ?? true) == true)
          .where((d) => ((d.data()['versionCode'] ?? 0) as num).toInt() > current)
          .toList();
      if (newer.isEmpty) return null;
      final top = newer.first.data();
      // حجم النسخة المناسبة لمعمارية هذا الجهاز (لو الأدمن رفع نسخة لكل معمارية)
      var size = ((top['apkSize'] ?? 0) as num).toInt();
      final apks = top['apks'];
      if (apks is Map) {
        for (final abi in [...await _abis(), 'universal']) {
          final a = apks[abi];
          if (a is Map && a['size'] is num) { size = (a['size'] as num).toInt(); break; }
        }
      }
      final anyMandatory = newer.any((d) => d.data()['mandatory'] == true);
      return AppUpdateInfo(
        id: newer.first.id,
        versionName: (top['versionName'] ?? '').toString(),
        versionCode: ((top['versionCode'] ?? 0) as num).toInt(),
        title: (top['title'] ?? 'تحديث جديد').toString(),
        description: (top['description'] ?? '').toString(),
        mandatory: anyMandatory,
        apkSize: size,
      );
    } catch (_) {
      // فشل الفحص (لا إنترنت…): لا نمنع المستخدم من فتح التطبيق
      return null;
    }
  }

  /// معماريات الجهاز بترتيب الأفضلية (مثل arm64-v8a ثم armeabi-v7a).
  Future<List<String>> _abis() async {
    try {
      final a = await DeviceInfoPlugin().androidInfo;
      return a.supportedAbis.map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }

  /// رابط تنزيل مؤقت للـ APK من السيرفر.
  /// ملاحظة: لو تطبيقك يستدعي الدوال عبر مسار Vercel /api/fn/<name> (كباقي الدوال)
  /// استبدل هذا السطر بنفس دالة الاستدعاء المستخدمة في services/api_functions.dart.
  Future<String> downloadUrl(String updateId) async {
    final res = await FirebaseFunctions.instance
        .httpsCallable('getAppUpdateDownloadUrl')
        .call({'id': updateId, 'abis': await _abis()});
    return (res.data as Map)['url'].toString();
  }
}
