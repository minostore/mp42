import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_functions.dart';

/// تسجيل الجلسة من الجهاز نفسه (بدل Agora السحابي):
///  1) فيديو: تسجيل شاشة التطبيق (MediaProjection) إلى mp4.
///  2) صوت: Agora startAudioRecording (صوت الجميع مختلطًا) إلى aac، ثم يُدمج مع الفيديو.
///  3) عند الانتهاء يُرفع الملف إلى Cloudflare R2 برابط مؤقت من السيرفر، ثم يتحقق السيرفر من وصوله قبل اعتباره «جاهز».
///  4) أي ملف لم يكتمل رفعه (انقطاع نت/إغلاق التطبيق) يُستكمل تلقائيًا عند فتح التطبيق — بنفس المفتاح فلا تتكرر التسجيلات.
/// أندرويد فقط (iOS غير مدعوم حاليًا).
class SessionRecorder {
  static const _ch = MethodChannel('fahmt/screen_record');
  static const _prefKey = 'pending_session_recordings_v1';
  static final _fn = FirebaseFunctions.instanceFor(region: 'us-central1');

  static bool _uploading = false;
  static Map<String, dynamic>? _active; // التسجيل الجاري
  static RtcEngine? _engine;

  static bool get supported => Platform.isAndroid;
  static bool get isRecording => _active != null;

  // ---------------------------------------------------------------- مخزن الانتظار
  static Future<List<Map<String, dynamic>>> _loadPending() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_prefKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _savePending(List<Map<String, dynamic>> list) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_prefKey, jsonEncode(list));
  }

  static Future<void> _upsert(Map<String, dynamic> item) async {
    final list = await _loadPending();
    list.removeWhere((e) => e['id'] == item['id']);
    list.add(item);
    await _savePending(list);
  }

  static Future<void> _remove(String id) async {
    final list = await _loadPending();
    list.removeWhere((e) => e['id'] == id);
    await _savePending(list);
  }

  static Map<String, dynamic> _payload(Map<String, dynamic> m) => {
        'kind': m['kind'],
        if ((m['groupId'] ?? '').toString().isNotEmpty) 'groupId': m['groupId'],
        if ((m['sessionId'] ?? '').toString().isNotEmpty) 'sessionId': m['sessionId'],
        if ((m['requestId'] ?? '').toString().isNotEmpty) 'requestId': m['requestId'],
      };

  /// يبلّغ السيرفر بسبب فشل التسجيل ليظهر في لوحة الإدارة بحالة واضحة.
  static Future<void> reportFailure(Map<String, String> meta, String reason) async {
    try {
      await _fn.httpsCallable('failClientRecording').call<Map<String, dynamic>>({..._payload(meta), 'error': reason});
    } catch (_) {}
  }

  // ---------------------------------------------------------------- البدء
  /// meta: kind ('group'|'istifham') + groupId/sessionId أو requestId + title.
  /// يرجع null عند النجاح، أو رسالة السبب عند الفشل (ويُبلَّغ السيرفر بها).
  static Future<String?> start(RtcEngine? engine, Map<String, String> meta) async {
    if (!supported) {
      const why = 'تسجيل الجلسة من الجهاز مدعوم على أندرويد فقط';
      await reportFailure(meta, why);
      return why;
    }
    if (_active != null) return null;
    try {
      final dir = await getApplicationSupportDirectory();
      final base = Directory('${dir.path}/recordings');
      if (!await base.exists()) await base.create(recursive: true);
      final key = (meta['kind'] == 'istifham' ? 'i_${meta['requestId']}' : 'g_${meta['groupId']}_${meta['sessionId']}');
      final video = '${base.path}/$key.video.mp4';
      final audio = '${base.path}/$key.audio.aac';
      final out = '${base.path}/$key.mp4';
      for (final f in [video, audio, out]) {
        final file = File(f);
        if (await file.exists()) await file.delete();
      }
      final ok = await _ch.invokeMethod<bool>('start', {'path': video}) ?? false;
      if (!ok) {
        String? err;
        try { err = await _ch.invokeMethod<String>('lastError'); } catch (_) {}
        final why = (err == null || err.isEmpty) ? 'لم يوافق المستخدم على إذن تسجيل الشاشة' : 'تعذر بدء تسجيل الشاشة: $err';
        await reportFailure(meta, why);
        return why;
      }
      bool audioOk = false;
      try {
        await engine?.startAudioRecording(AudioRecordingConfiguration(
          filePath: audio,
          sampleRate: 32000,
          quality: AudioRecordingQualityType.audioRecordingQualityMedium,
          fileRecordingType: AudioFileRecordingType.audioFileRecordingMixed,
        ));
        audioOk = engine != null;
      } catch (_) {}
      _engine = engine;
      _active = {
        'id': key,
        ...meta,
        'video': video,
        'audio': audioOk ? audio : '',
        'out': out,
        'status': 'recording',
        'startedMs': DateTime.now().millisecondsSinceEpoch,
        'attempts': 0,
      };
      await _upsert(_active!); // لو أُغلق التطبيق أثناء التسجيل نستكمل ما تم حفظه لاحقًا
      return null;
    } catch (e) {
      final why = 'تعذر بدء التسجيل: $e';
      await reportFailure(meta, why);
      return why;
    }
  }

  // ---------------------------------------------------------------- الإيقاف + الرفع
  /// يوقف التسجيل ويدمج الصوت ويبدأ الرفع في الخلفية. لا يرمي أخطاء.
  static Future<void> stopAndUpload() async {
    final a = _active;
    if (a == null) return;
    _active = null;
    try { await _engine?.stopAudioRecording(); } catch (_) {}
    _engine = null;
    bool stopped = false;
    try { stopped = await _ch.invokeMethod<bool>('stop') ?? false; } catch (_) {}
    a['status'] = stopped ? 'stopped' : 'stopped_unclean';
    await _upsert(a);
    unawaited(uploadPending());
  }

  // ---------------------------------------------------------------- الدمج والرفع
  static Future<bool> _ensureMuxed(Map<String, dynamic> it) async {
    final out = (it['out'] ?? '').toString();
    if (out.isNotEmpty && await File(out).exists() && await File(out).length() > 1024) return true;
    final video = (it['video'] ?? '').toString();
    if (video.isEmpty || !await File(video).exists() || await File(video).length() < 1024) return false;
    final audio = (it['audio'] ?? '').toString();
    return await _ch.invokeMethod<bool>('mux', {'video': video, 'audio': audio.isEmpty ? null : audio, 'out': out}) ?? false;
  }

  /// يرفع كل التسجيلات المعلّقة (يُستدعى بعد الإنهاء وعند فتح التطبيق). آمن للاستدعاء المتكرر.
  static Future<void> uploadPending() async {
    if (_uploading || !supported) return;
    _uploading = true;
    try {
      for (final it in await _loadPending()) {
        if (it['id'] == _active?['id']) continue; // ما زال يُسجَّل
        final id = it['id'].toString();
        final meta = {for (final k in ['kind', 'groupId', 'sessionId', 'requestId', 'title']) k: (it[k] ?? '').toString()};
        try {
          if (!await _ensureMuxed(it)) {
            final vp = (it['video'] ?? '').toString();
            final vs = vp.isNotEmpty && await File(vp).exists() ? await File(vp).length() : 0;
            String? ne;
            try { ne = await _ch.invokeMethod<String>('lastError'); } catch (_) {}
            await reportFailure(meta, 'لم يُنتج ملف تسجيل صالح على الجهاز (حجم الفيديو: $vs بايت، الحالة: ${it['status']}${(ne ?? '').isEmpty ? '' : '، $ne'})');
            await _removeFiles(it);
            await _remove(id);
            continue;
          }
          final out = File(it['out'].toString());
          final size = await out.length();
          final signed = await _fn.httpsCallable('createRecordingUploadUrl').call<Map<String, dynamic>>({..._payload(it), 'size': size, 'contentType': 'video/mp4'});
          final url = (signed.data['url'] ?? '').toString();
          if (url.isEmpty) throw StateError('رابط الرفع غير متاح');
          final req = http.StreamedRequest('PUT', Uri.parse(url))
            ..headers['Content-Type'] = 'video/mp4'
            ..contentLength = size;
          out.openRead().listen(req.sink.add, onDone: req.sink.close, onError: req.sink.addError, cancelOnError: true);
          final resp = await req.send().timeout(const Duration(minutes: 30));
          if (resp.statusCode < 200 || resp.statusCode >= 300) throw StateError('فشل الرفع (HTTP ${resp.statusCode})');
          final startedMs = (it['startedMs'] is num) ? (it['startedMs'] as num).toInt() : 0;
          final dur = startedMs > 0 ? ((DateTime.now().millisecondsSinceEpoch - startedMs) / 1000).round() : 0;
          await _fn.httpsCallable('completeClientRecording').call<Map<String, dynamic>>({..._payload(it), 'size': size, 'durationSec': dur});
          await _removeFiles(it);
          await _remove(id);
        } catch (e) {
          // نبقيه في الانتظار ونعيد المحاولة لاحقًا (بنفس المفتاح فلا تتكرر التسجيلات)
          final attempts = ((it['attempts'] is num) ? (it['attempts'] as num).toInt() : 0) + 1;
          it['attempts'] = attempts;
          await _upsert(it);
          if (attempts == 3 || attempts % 10 == 0) await reportFailure(meta, 'تعذر رفع التسجيل (محاولة $attempts): $e');
        }
      }
    } finally {
      _uploading = false;
    }
  }

  static Future<void> _removeFiles(Map<String, dynamic> it) async {
    for (final k in ['video', 'audio', 'out']) {
      final p = (it[k] ?? '').toString();
      if (p.isEmpty) continue;
      try { final f = File(p); if (await f.exists()) await f.delete(); } catch (_) {}
    }
  }
}
