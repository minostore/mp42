import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/categories_tree.dart';
import '../services/api_functions.dart';
import '../services/r2_upload.dart';
import '../theme/app_theme.dart';
import '../widgets/category_picker.dart';

class _LessonDraft {
  final title = TextEditingController();
  File? video;
  String videoName = '';
  bool freePreview = false;
}

/// إضافة كورس جديد من التطبيق: بيانات الكورس + غلاف + دروس (فيديو لكل درس) تُرفع إلى R2.
/// يُحفظ الكورس بحالة `pending` وينتظر اعتماد الإدارة قبل ظهوره للعامة.
class CreateCourseScreen extends StatefulWidget {
  const CreateCourseScreen({super.key});
  @override
  State<CreateCourseScreen> createState() => _CreateCourseScreenState();
}

class _CreateCourseScreenState extends State<CreateCourseScreen> {
  final _title = TextEditingController();
  final _desc = TextEditingController();
  final _price = TextEditingController(text: '0');
  CategoryChoice _choice = const CategoryChoice();
  File? _cover;
  String _coverName = 'cover.jpg';
  final List<_LessonDraft> _lessons = [_LessonDraft()];
  bool _busy = false;
  String _status = '';
  double _progress = 0;

  FirebaseFunctions get _fn => FirebaseFunctions.instanceFor(region: 'us-central1');

  Future<void> _pickCover() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.image);
    final f = r?.files.single;
    if (f?.path == null) return;
    setState(() {
      _cover = File(f!.path!);
      _coverName = f.name;
    });
  }

  Future<void> _pickVideo(_LessonDraft l) async {
    final r = await FilePicker.platform.pickFiles(type: FileType.video);
    final f = r?.files.single;
    if (f?.path == null) return;
    setState(() {
      l.video = File(f!.path!);
      l.videoName = f.name;
      if (l.title.text.trim().isEmpty) l.title.text = f.name.replaceAll(RegExp(r'\.[^.]+$'), '');
    });
  }

  void _toast(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  String _ctype(String name, {required bool video}) {
    final n = name.toLowerCase();
    if (video) return n.endsWith('.mov') ? 'video/quicktime' : 'video/mp4';
    return n.endsWith('.png') ? 'image/png' : 'image/jpeg';
  }

  Future<Map<String, dynamic>> _upload({required String courseId, required String kind, required File file, required String name, required String contentType, int lessonNumber = 0}) async {
    final res = await _fn.httpsCallable('createR2UploadUrl').call<Map<String, dynamic>>({
      'courseId': courseId, 'kind': kind, 'fileName': name, 'contentType': contentType, 'lessonNumber': lessonNumber,
    });
    final url = (res.data['url'] ?? '').toString();
    if (url.isEmpty) throw Exception('رابط الرفع غير مكتمل');
    await R2Uploader.put(url: url, file: file, contentType: contentType, onProgress: (p) => setState(() => _progress = p));
    return Map<String, dynamic>.from(res.data);
  }

  Future<void> _submit() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final price = double.tryParse(_price.text.trim());
    if (_title.text.trim().length < 4) return _toast('اكتب عنوان الكورس');
    if (_desc.text.trim().length < 10) return _toast('اكتب وصفًا للكورس');
    if (price == null || price < 0) return _toast('السعر غير صحيح');
    if (_choice.isEmpty || (isOtherNode(_choice.main, _choice.sub, _choice.opt) && _choice.custom.isEmpty)) return _toast('اختر قسم الكورس');
    if (_cover == null) return _toast('اختر صورة غلاف للكورس');
    final lessons = _lessons.where((l) => l.video != null).toList();
    if (lessons.isEmpty) return _toast('أضف درسًا واحدًا على الأقل مع فيديو');
    if (lessons.any((l) => l.title.text.trim().isEmpty)) return _toast('اكتب عنوانًا لكل درس');

    setState(() {
      _busy = true;
      _progress = 0;
    });
    try {
      final db = FirebaseFirestore.instance;
      final ref = db.collection('courses').doc();
      setState(() => _status = 'رفع صورة الغلاف...');
      final cover = await _upload(courseId: ref.id, kind: 'cover', file: _cover!, name: _coverName, contentType: _ctype(_coverName, video: false));
      final lessonDocs = <Map<String, dynamic>>[];
      for (var i = 0; i < lessons.length; i++) {
        final l = lessons[i];
        setState(() {
          _status = 'رفع الدرس ${i + 1} من ${lessons.length}...';
          _progress = 0;
        });
        final up = await _upload(courseId: ref.id, kind: 'lesson', file: l.video!, name: l.videoName, contentType: _ctype(l.videoName, video: true), lessonNumber: i + 1);
        lessonDocs.add({
          'title': l.title.text.trim(),
          'order': i + 1,
          'r2Key': up['key'],
          'isFreePreview': i == 0 && l.freePreview, // المعاينة المجانية للدرس الأول فقط (كما في الويب)
          'createdAt': DateTime.now().toIso8601String(),
        });
      }
      setState(() => _status = 'حفظ الكورس...');
      await ref.set({
        'title': _title.text.trim(),
        'description': _desc.text.trim(),
        'price': price,
        ..._choice.toFields(),
        'thumbnailUrl': cover['token'] ?? cover['key'],
        'coverKey': cover['key'],
        'instructorId': user.uid,
        'ownerUid': user.uid,
        'instructorName': user.displayName ?? '',
        'lessonsCount': lessonDocs.length,
        'status': 'pending',
        'createdAt': DateTime.now().toIso8601String(),
      });
      final batch = db.batch();
      for (var i = 0; i < lessonDocs.length; i++) {
        batch.set(ref.collection('lessons').doc('lesson_${(i + 1).toString().padLeft(2, '0')}'), lessonDocs[i]);
      }
      await batch.commit();
      if (!mounted) return;
      _toast('تم رفع الكورس، وسيظهر بعد مراجعة الإدارة');
      context.pop();
    } catch (e) {
      if (mounted) _toast('تعذر إنشاء الكورس: ${e is FirebaseFunctionsException ? (e.message ?? e.code) : e}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('إضافة كورس جديد')),
        body: _busy
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(_status, style: const TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 14),
                    LinearProgressIndicator(value: _progress == 0 ? null : _progress, minHeight: 8),
                    const SizedBox(height: 8),
                    Text('${(_progress * 100).round()}%'),
                    const SizedBox(height: 12),
                    const Text('لا تغلق التطبيق أثناء الرفع', style: TextStyle(color: AppColors.muted)),
                  ]),
                ),
              )
            : ListView(padding: const EdgeInsets.all(16), children: [
                TextField(controller: _title, decoration: const InputDecoration(labelText: 'عنوان الكورس')),
                const SizedBox(height: 12),
                TextField(controller: _desc, maxLines: 4, decoration: const InputDecoration(labelText: 'وصف الكورس')),
                const SizedBox(height: 12),
                TextField(controller: _price, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'السعر (ج.م) — 0 للمجاني')),
                const SizedBox(height: 12),
                CategoryPicker(value: _choice, onChanged: (c) => setState(() => _choice = c)),
                OutlinedButton.icon(
                  onPressed: _pickCover,
                  icon: const Icon(Icons.image_outlined),
                  label: Text(_cover == null ? 'اختيار صورة الغلاف' : 'الغلاف: $_coverName'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                ),
                const SizedBox(height: 18),
                const Text('الدروس', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                const SizedBox(height: 8),
                for (var i = 0; i < _lessons.length; i++) _lessonCard(i),
                OutlinedButton.icon(
                  onPressed: _lessons.length >= 110 ? null : () => setState(() => _lessons.add(_LessonDraft())),
                  icon: const Icon(Icons.add),
                  label: const Text('إضافة درس'),
                ),
                const SizedBox(height: 18),
                ElevatedButton(onPressed: _submit, child: const Text('رفع الكورس وإرساله للمراجعة')),
              ]),
      ),
    );
  }

  Widget _lessonCard(int i) {
    final l = _lessons[i];
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text('الدرس ${i + 1}', style: const TextStyle(fontWeight: FontWeight.w900)),
            const Spacer(),
            if (_lessons.length > 1) IconButton(onPressed: () => setState(() => _lessons.removeAt(i)), icon: const Icon(Icons.delete_outline, color: Colors.red)),
          ]),
          TextField(controller: l.title, decoration: const InputDecoration(labelText: 'عنوان الدرس')),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _pickVideo(l),
            icon: const Icon(Icons.video_file_outlined),
            label: Text(l.video == null ? 'اختيار الفيديو' : l.videoName, overflow: TextOverflow.ellipsis),
          ),
          if (i == 0)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: l.freePreview,
              onChanged: (v) => setState(() => l.freePreview = v),
              title: const Text('معاينة مجانية'),
              subtitle: const Text('تُفتح على الويب للجميع؛ باقي الدروس تُفتح في التطبيق فقط'),
            ),
        ]),
      ),
    );
  }
}
