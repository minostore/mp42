import 'dart:convert';

/// نتيجة فحص توكن JaaS محليًا على الجهاز (بدون أي اتصال بالإنترنت).
class JaasTokenReport {
  final Map<String, dynamic> header;
  final Map<String, dynamic> payload;

  /// مشاكل مؤكدة: JaaS سيرفض هذا التوكن حتمًا، فلا فائدة من فتح الاجتماع.
  final List<String> blocking;

  /// ملاحظات محتملة: لا نمنع الدخول بسببها، لكن نعرضها لو فشل الدخول بعدها.
  final List<String> warnings;

  JaasTokenReport({
    required this.header,
    required this.payload,
    this.blocking = const [],
    this.warnings = const [],
  });

  bool get isBlocking => blocking.isNotEmpty;

  /// ملخص تقني آمن للعرض (بدون التوكن نفسه).
  String get summary {
    final ctx = payload['context'];
    final user = ctx is Map ? ctx['user'] : null;
    return 'alg=${header['alg']} kid=${header['kid']} | '
        'sub=${payload['sub']} aud=${payload['aud']} iss=${payload['iss']} '
        'room=${payload['room']} exp=${payload['exp']} nbf=${payload['nbf']} '
        'moderator=${user is Map ? user['moderator'] : '?'}';
  }
}

class JaasTokenInspector {
  JaasTokenInspector._();

  static Map<String, dynamic>? _decodePart(String part) {
    try {
      final bytes = base64Url.decode(base64Url.normalize(part));
      final obj = jsonDecode(utf8.decode(bytes));
      return obj is Map ? Map<String, dynamic>.from(obj) : null;
    } catch (_) {
      return null;
    }
  }

  /// [expectedAppId]  : الـ App ID الموجود في اسم الغرفة (vpaas-magic-cookie-...).
  /// [roomName]       : اسم الغرفة بدون الـ App ID (مثل Fahimni_<id>).
  static JaasTokenReport inspect(
    String token, {
    required String expectedAppId,
    required String roomName,
  }) {
    final parts = token.trim().split('.');
    if (parts.length != 3) {
      return JaasTokenReport(
        header: const {},
        payload: const {},
        blocking: ['الرد ليس توكن JWT صالحًا (عدد الأجزاء ${parts.length} بدل 3).'],
      );
    }
    final h = _decodePart(parts[0]);
    final p = _decodePart(parts[1]);
    if (h == null || p == null) {
      return JaasTokenReport(
        header: h ?? const {},
        payload: p ?? const {},
        blocking: const ['تعذّر فك ترميز التوكن (Base64/JSON غير صالح).'],
      );
    }

    final blocking = <String>[];
    final warnings = <String>[];
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    if ((h['alg'] ?? '').toString() != 'RS256') {
      blocking.add('خوارزمية التوقيع alg=${h['alg']} بينما JaaS يقبل RS256 فقط.');
    }

    final sub = (p['sub'] ?? '').toString();
    if (sub != expectedAppId) {
      blocking.add('الـ App ID داخل التوكن (sub=$sub) مختلف عن الـ App ID في اسم الغرفة ($expectedAppId).');
    }

    if ((p['aud'] ?? '').toString() != 'jitsi') {
      blocking.add('حقل aud في التوكن = ${p['aud']} والمطلوب jitsi.');
    }

    final roomClaim = (p['room'] ?? '').toString();
    if (roomClaim.isEmpty) {
      blocking.add('حقل room غير موجود في التوكن.');
    } else if (roomClaim != '*' && roomClaim != roomName) {
      blocking.add('اسم الغرفة داخل التوكن (room=$roomClaim) مختلف عن الغرفة التي يفتحها التطبيق ($roomName).');
    }

    final exp = p['exp'];
    if (exp is num && nowSec >= exp.toInt()) {
      blocking.add('التوكن منتهي الصلاحية (exp قبل الوقت الحالي بـ ${nowSec - exp.toInt()} ثانية). غالبًا ساعة الجهاز غير مضبوطة.');
    }

    final kid = (h['kid'] ?? '').toString();
    if (kid.isEmpty) {
      warnings.add('رأس التوكن لا يحتوي kid.');
    } else if (!kid.startsWith('$expectedAppId/')) {
      warnings.add('قيمة kid=$kid لا تبدأ بـ "$expectedAppId/". JaaS يطلب kid بصيغة <AppID>/<KeyID> كاملة، فاحتمال كبير أن JAAS_KEY_ID في السيرفر ناقص الجزء الأول.');
    }

    // السيرفر يضبط nbf = وقت السيرفر - 5 ثواني، فنقدر نعرف فرق ساعة الجهاز.
    final nbf = p['nbf'];
    if (nbf is num) {
      final skew = nowSec - (nbf.toInt() + 5);
      if (skew.abs() > 120) {
        final mins = (skew.abs() / 60).round();
        warnings.add('ساعة الجهاز ${skew > 0 ? 'متقدمة' : 'متأخرة'} عن السيرفر بحوالي $mins دقيقة، اضبط التاريخ والوقت على تلقائي.');
      }
    }

    return JaasTokenReport(header: h, payload: p, blocking: blocking, warnings: warnings);
  }
}
