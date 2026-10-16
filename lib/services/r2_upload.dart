import 'dart:async';
import 'dart:io';

/// رفع ملف كبير مباشرة إلى Cloudflare R2 عبر رابط PUT مؤقت، مع نسبة تقدم (بدون تحميل الملف كله في الذاكرة).
class R2Uploader {
  static Future<void> put({
    required String url,
    required File file,
    required String contentType,
    void Function(double progress)? onProgress,
  }) async {
    final total = await file.length();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    try {
      final req = await client.putUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.contentTypeHeader, contentType);
      req.contentLength = total;
      var sent = 0;
      var lastReport = -1;
      await req.addStream(file.openRead().map((chunk) {
        sent += chunk.length;
        final pct = total == 0 ? 100 : (sent * 100 ~/ total);
        if (pct != lastReport) {
          lastReport = pct;
          onProgress?.call(pct / 100);
        }
        return chunk;
      }));
      final res = await req.close();
      await res.drain<void>();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw HttpException('فشل رفع الملف (HTTP ${res.statusCode})');
      }
      onProgress?.call(1);
    } finally {
      client.close(force: true);
    }
  }
}
