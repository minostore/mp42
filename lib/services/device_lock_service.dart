import 'dart:io' show Platform;
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_functions.dart';

/// الحساب يعمل على جهاز واحد فقط داخل التطبيق.
/// الخادم (claimDeviceSession) يحجز الحساب لأول جهاز، ويرفض أي جهاز آخر برمز device-locked.
class DeviceLockResult {
  final bool locked;
  final String message;
  const DeviceLockResult({this.locked = false, this.message = ''});
}

class DeviceLockService {
  static const _kId = 'fahmt_device_id';
  static const _msg = 'هذا الحساب مسجّل على جهاز آخر. لا يمكن استخدام نفس الحساب على أكثر من جهاز. تواصل مع الدعم لنقل الحساب لجهازك الجديد.';

  static Future<String> _deviceId() async {
    final sp = await SharedPreferences.getInstance();
    var id = sp.getString(_kId);
    if (id == null || id.isEmpty) {
      final r = Random.secure();
      id = List.generate(24, (_) => r.nextInt(16).toRadixString(16)).join();
      await sp.setString(_kId, id);
    }
    return id;
  }

  /// بصمة تسمح بالتعرف على نفس الهاتف بعد إعادة تثبيت التطبيق (يضيع المعرّف المحفوظ).
  static Future<({String fingerprint, String name})> _fingerprint() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        final fp = [a.brand, a.manufacturer, a.model, a.device, a.hardware, a.board, a.product].join('|');
        return (fingerprint: fp, name: '${a.brand} ${a.model}');
      }
      if (Platform.isIOS) {
        final i = await info.iosInfo;
        return (fingerprint: 'ios|${i.identifierForVendor ?? ''}', name: i.utsname.machine);
      }
    } catch (_) {}
    return (fingerprint: '', name: 'جهاز');
  }

  /// يحجز الحساب لهذا الجهاز أو يرفض. أي خطأ آخر (شبكة/خادم قديم) لا يمنع الدخول.
  static Future<DeviceLockResult> claim() async {
    if (FirebaseAuth.instance.currentUser == null) return const DeviceLockResult();
    try {
      final id = await _deviceId();
      final fp = await _fingerprint();
      await FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable('claimDeviceSession').call<Map<String, dynamic>>({
        'deviceId': id,
        'fingerprint': fp.fingerprint,
        'deviceName': fp.name,
      });
      return const DeviceLockResult();
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'device-locked') return DeviceLockResult(locked: true, message: (e.message ?? '').isEmpty ? _msg : e.message!);
      return const DeviceLockResult();
    } catch (_) {
      return const DeviceLockResult();
    }
  }
}
