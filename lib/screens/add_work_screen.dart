import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/categories_tree.dart';
import '../widgets/category_picker.dart';

/// إضافة عمل جديد إلى «أعمال المفهمين» (فيديو + صورة مصغّرة + قسم). يُنشر بعد اعتماد الإدارة.
class AddWorkScreen extends StatefulWidget {
  const AddWorkScreen({super.key});
  @override
  State<AddWorkScreen> createState() => _AddWorkScreenState();
}

class _AddWorkScreenState extends State<AddWorkScreen> {
  final _title = TextEditingController();
  final _desc = TextEditingController();
  CategoryChoice _choice = const CategoryChoice();
  File? _video, _thumb;
  String _videoName = '', _thumbName = '';
  bool _busy = false;
  double _progress = 0;

  void _toast(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _pick(bool video) async {
    final r = await FilePicker.platform.pickFiles(type: video ? FileType.video : FileType.image);
    final f = r?.files.single;
    if (f?.path == null) return;
    setState(() {
      if (video) {
        _video = File(f!.path!);
        _videoName = f.name;
      } else {
        _thumb = File(f!.path!);
        _thumbName = f.name;
      }
    });
  }

  Future<void> _submit() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (_title.text.trim().length < 3) return _toast('اكتب عنوان العمل');
    if (_choice.isEmpty || (isOtherNode(_choice.main, _choice.sub, _choice.opt) && _choice.custom.isEmpty)) return _toast('اختر قسم العمل');
    if (_video == null || _thumb == null) return _toast('اختر الفيديو والصورة المصغّرة');
    setState(() {
      _busy = true;
      _progress = 0;
    });
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final vRef = FirebaseStorage.instance.ref('portfolio/${user.uid}/v_$ts');
      final task = vRef.putFile(_video!, SettableMetadata(contentType: _videoName.toLowerCase().endsWith('.mov') ? 'video/quicktime' : 'video/mp4'));
      task.snapshotEvents.listen((s) {
        if (s.totalBytes > 0 && mounted) setState(() => _progress = s.bytesTransferred / s.totalBytes);
      });
      await task;
      final tRef = FirebaseStorage.instance.ref('portfolio/${user.uid}/t_$ts');
      await tRef.putFile(_thumb!, SettableMetadata(contentType: 'image/jpeg'));
      await FirebaseFirestore.instance.collection('portfolio').add({
        'mufhemId': user.uid,
        'mufhemName': user.displayName ?? '',
        'title': _title.text.trim(),
        'description': _desc.text.trim(),
        ..._choice.toFields(),
        'mediaUrl': await vRef.getDownloadURL(),
        'thumbnailUrl': await tRef.getDownloadURL(),
        'mediaType': 'video',
        'status': 'pending_approval',
        'createdAt': DateTime.now().toIso8601String(),
      });
      if (!mounted) return;
      _toast('تم الإرسال للمراجعة، وسيُنشر بعد اعتماده');
      context.pop();
    } catch (e) {
      if (mounted) _toast('فشل رفع العمل: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('إضافة عمل جديد')),
      body: _busy
          ? Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('جارٍ رفع العمل...', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 14),
              LinearProgressIndicator(value: _progress == 0 ? null : _progress, minHeight: 8),
              const SizedBox(height: 8),
              Text('${(_progress * 100).round()}%'),
            ])))
          : ListView(padding: const EdgeInsets.all(16), children: [
              TextField(controller: _title, decoration: const InputDecoration(labelText: 'عنوان العمل')),
              const SizedBox(height: 12),
              TextField(controller: _desc, maxLines: 3, decoration: const InputDecoration(labelText: 'وصف العمل (اختياري)')),
              const SizedBox(height: 12),
              CategoryPicker(value: _choice, onChanged: (c) => setState(() => _choice = c)),
              OutlinedButton.icon(onPressed: () => _pick(true), icon: const Icon(Icons.video_file_outlined), label: Text(_video == null ? 'اختيار الفيديو' : _videoName, overflow: TextOverflow.ellipsis), style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50))),
              const SizedBox(height: 10),
              OutlinedButton.icon(onPressed: () => _pick(false), icon: const Icon(Icons.image_outlined), label: Text(_thumb == null ? 'اختيار الصورة المصغّرة' : _thumbName, overflow: TextOverflow.ellipsis), style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50))),
              const SizedBox(height: 20),
              ElevatedButton(onPressed: _submit, child: const Text('إرسال للمراجعة')),
            ]),
    );
  }
}
