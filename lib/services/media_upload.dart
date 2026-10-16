import 'dart:io';
import 'dart:typed_data';

import 'api_functions.dart';
import 'r2_upload.dart';

/// رفع وسائط إلى Cloudflare R2 عبر رابط مؤقت من السيرفر (بدون Firebase Storage).
/// kind: 'profile' | 'portfolio' | 'meeting' — يرجّع الرابط العام للملف.
class MediaUpload {
  static FirebaseFunctions get _fn => FirebaseFunctions.instanceFor(region: 'us-central1');

  static Future<String> _sign(String kind, String name, String contentType, int size, String? channel) async {
    final res = await _fn.httpsCallable('createMediaUploadUrl').call<Map<String, dynamic>>({
      'kind': kind, 'fileName': name, 'contentType': contentType, 'size': size, if (channel != null) 'channel': channel,
    });
    return '${res.data['url']}\u0000${res.data['publicUrl']}';
  }

  static Future<String> uploadFile({
    required String kind,
    required File file,
    required String fileName,
    required String contentType,
    String? channel,
    void Function(double)? onProgress,
  }) async {
    final parts = (await _sign(kind, fileName, contentType, await file.length(), channel)).split('\u0000');
    await R2Uploader.put(url: parts[0], file: file, contentType: contentType, onProgress: onProgress);
    return parts[1];
  }

  /// للملفات الصغيرة الموجودة في الذاكرة (مثل ملف اختاره المستخدم بـ withData).
  static Future<String> uploadBytes({
    required String kind,
    required Uint8List bytes,
    required String fileName,
    required String contentType,
    String? channel,
  }) async {
    final tmp = File('${Directory.systemTemp.path}/up_${DateTime.now().microsecondsSinceEpoch}');
    await tmp.writeAsBytes(bytes);
    try {
      return await uploadFile(kind: kind, file: tmp, fileName: fileName, contentType: contentType, channel: channel);
    } finally {
      try { await tmp.delete(); } catch (_) {}
    }
  }
}
