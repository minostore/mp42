import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

/// يطلب Agora RTC Token من Cloudflare Worker (بدل Firebase Functions).
/// يمكن تغيير الرابط وقت البناء: --dart-define=AGORA_WORKER_URL=https://...
class AgoraTokenService {
  static const String _defaultUrl = 'https://fahmny-agora.mohamedragabewiess.workers.dev';

  static String get workerUrl {
    const configured = String.fromEnvironment('AGORA_WORKER_URL');
    final v = configured.trim().isEmpty ? _defaultUrl : configured.trim();
    return v.replaceFirst(RegExp(r'/+$'), '');
  }

  static Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('لازم تسجل الدخول أولاً');
    final idToken = await user.getIdToken();
    final res = await http
        .post(
          Uri.parse('$workerUrl$path'),
          headers: {'Authorization': 'Bearer $idToken', 'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    Map<String, dynamic> data = {};
    final raw = utf8.decode(res.bodyBytes, allowMalformed: true);
    try {
      final d = jsonDecode(raw);
      if (d is Map<String, dynamic>) data = d;
    } catch (_) {}
    if (res.statusCode != 200) {
      final err = data['error'];
      final msg = err is Map ? (err['message'] ?? '').toString() : '';
      throw Exception(msg.isNotEmpty ? msg : 'تعذر إصدار توكن الاجتماع (HTTP ${res.statusCode})');
    }
    if (data.isEmpty) {
      final snip = raw.length > 200 ? raw.substring(0, 200) : raw;
      throw Exception('رد غير متوقع من Worker: HTTP ${res.statusCode} type=${res.headers['content-type']} body=$snip');
    }
    return data;
  }

  static Future<Map<String, dynamic>> meetingToken(String requestId) =>
      _post('/meeting', {'requestId': requestId});

  static Future<Map<String, dynamic>> groupToken(String groupId, String sessionId) =>
      _post('/group', {'groupId': groupId, 'sessionId': sessionId});
}
