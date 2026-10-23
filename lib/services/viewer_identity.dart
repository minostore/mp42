import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import 'api_functions.dart';
import 'device_lock_service.dart';

/// هوية المشاهد الحالية (IP + رقم الهاتف + البريد) لعرضها كعلامة مائية متحركة
/// فوق الفيديوهات والجلسات المسجلة وملفات الـ PDF لردع التسريب.
class ViewerIdentity {
  final String ip;
  final String phone;
  final String email;
  final String device;
  final String name;
  final String publicId;
  const ViewerIdentity({this.ip = '', this.phone = '', this.email = '', this.device = '', this.name = '', this.publicId = ''});

  /// الأسطر التي تُعرض (تُتجاهل الفارغة).
  List<String> get lines => [
        if (name.isNotEmpty) name,
        if (publicId.isNotEmpty) 'الرقم التعريفي: $publicId',
        if (phone.isNotEmpty) phone,
        if (email.isNotEmpty) email,
        if (ip.isNotEmpty) 'IP: $ip',
      ];

  static ViewerIdentity? _cached;
  static Future<ViewerIdentity>? _loading;

  /// يحمّل الهوية مرة واحدة ويحتفظ بها (الـ IP يُحدَّث كل 10 دقائق).
  static DateTime _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<ViewerIdentity> load() {
    final c = _cached;
    if (c != null && DateTime.now().difference(_cachedAt) < const Duration(minutes: 10)) return Future.value(c);
    return _loading ??= _fetch().whenComplete(() => _loading = null);
  }

  static Future<ViewerIdentity> _fetch() async {
    final user = FirebaseAuth.instance.currentUser;
    var phone = '';
    var name = '';
    var publicId = '';
    var email = user?.email ?? '';
    if (user != null) {
      try {
        final snap = await FirebaseFirestore.instance.collection('users').doc(user.uid).get().timeout(const Duration(seconds: 6));
        final d = snap.data() ?? const <String, dynamic>{};
        phone = (d['phone'] ?? d['phoneNumber'] ?? user.phoneNumber ?? '').toString();
        final e = (d['email'] ?? '').toString();
        if (e.isNotEmpty) email = e;
        name = (d['name'] ?? d['fullName'] ?? user.displayName ?? '').toString();
        publicId = (d['publicId'] ?? '').toString();
      } catch (_) {
        phone = user.phoneNumber ?? '';
      }
    }
    if (user != null && publicId.isEmpty) {
      // الرقم التعريفي يُولَّد من السيرفر عند أول طلب
      try {
        final r = await FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable('ensurePublicId').call<Map<String, dynamic>>().timeout(const Duration(seconds: 6));
        publicId = (r.data['publicId'] ?? '').toString();
      } catch (_) {}
    }
    final ip = await _publicIp();
    var device = '';
    try { device = await DeviceLockService.shortCode(); } catch (_) {}
    final id = ViewerIdentity(ip: ip, phone: phone, email: email, device: device, name: name, publicId: publicId);
    _cached = id;
    _cachedAt = DateTime.now();
    return id;
  }

  static Future<String> _publicIp() async {
    // الأفضل: الـ IP كما يراه خادمنا (لا يمكن تزويره من العميل)
    try {
      final r = await FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable('getMyIp').call<Map<String, dynamic>>().timeout(const Duration(seconds: 5));
      final ip = (r.data['ip'] ?? '').toString().trim();
      if (ip.isNotEmpty) return ip;
    } catch (_) {}
    // نجرّب أكثر من خدمة؛ لو فشلت كلها نكمل بدون IP بدل ما نعطّل التشغيل.
    final sources = <String, String? Function(String)>{
      // api64 يرجّع عنوان IPv6 الخاص بالجهاز لو شبكته تدعمه (أقرب لعنوان الجهاز الفعلي من IPv4 المشترك)
      'https://api64.ipify.org?format=json': (b) => (jsonDecode(b) as Map)['ip']?.toString(),
      'https://api.ipify.org?format=json': (b) => (jsonDecode(b) as Map)['ip']?.toString(),
      'https://ipwho.is/': (b) => (jsonDecode(b) as Map)['ip']?.toString(),
    };
    for (final e in sources.entries) {
      try {
        final r = await http.get(Uri.parse(e.key)).timeout(const Duration(seconds: 4));
        if (r.statusCode == 200) {
          final ip = e.value(r.body);
          if (ip != null && ip.trim().isNotEmpty) return ip.trim();
        }
      } catch (_) {}
    }
    return '';
  }
}
