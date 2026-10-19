import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' as xl;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../services/api_functions.dart';
import '../services/r2_upload.dart';
import '../theme/app_theme.dart';
import '../widgets/user_avatar.dart';

FirebaseFunctions get _fn => FirebaseFunctions.instanceFor(region: 'us-central1');

String _msg(Object e) {
  if (e is FirebaseFunctionsException) return e.message ?? e.code;
  return e.toString().replaceFirst('Exception: ', '');
}

void _snack(BuildContext c, String t) {
  if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(t)));
}

/// صلاحيات المحرر (نفس مفاتيح الخادم EDITOR_PERMS).
const Map<String, String> kEditorPerms = {
  'uploadVideos': 'رفع الفيديوهات',
  'uploadFiles': 'رفع ملفات PDF',
  'createQuizzes': 'إنشاء الاختبارات',
  'manageSessions': 'إنشاء وإدارة الجلسات',
  'addStudents': 'إضافة طلاب',
};

/// دور المستخدم داخل المجموعة: صاحبها، أو محرر بصلاحيات، أو طالب.
class GroupRole {
  final bool isOwner;
  final Map<String, bool> perms;
  const GroupRole({required this.isOwner, this.perms = const {}});
  bool can(String perm) => isOwner || perms[perm] == true;
  bool get isManager => isOwner || perms.values.any((v) => v);
}

/// يبني [builder] بدور المستخدم الحالي (يستمع لوثيقة عضويته لمعرفة صلاحيات المحرر).
class GroupRoleBuilder extends StatelessWidget {
  final String groupId;
  final String ownerUid;
  final Widget Function(BuildContext, GroupRole) builder;
  const GroupRoleBuilder({super.key, required this.groupId, required this.ownerUid, required this.builder});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return builder(context, const GroupRole(isOwner: false));
    if (uid == ownerUid) return builder(context, const GroupRole(isOwner: true));
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('groups').doc(groupId).collection('members').doc(uid).snapshots(),
      builder: (context, s) {
        final m = s.data?.data() ?? const <String, dynamic>{};
        final perms = <String, bool>{};
        if (m['role'] == 'editor' && m['permissions'] is Map) {
          (m['permissions'] as Map).forEach((k, v) => perms[k.toString()] = v == true);
        }
        return builder(context, GroupRole(isOwner: false, perms: perms));
      },
    );
  }
}

// ============================ رفع فيديو / PDF ============================

Future<void> pickAndUploadGroupContent(BuildContext context, {required String groupId, required String kind}) async {
  final isVideo = kind == 'videos';
  final picked = await FilePicker.platform.pickFiles(
    type: isVideo ? FileType.video : FileType.custom,
    allowedExtensions: isVideo ? null : const ['pdf'],
    withData: false,
  );
  final path = picked?.files.single.path;
  if (path == null || !context.mounted) return;
  final file = File(path);
  final name = picked!.files.single.name;
  final titleC = TextEditingController(text: name.replaceAll(RegExp(r'\.[^.]+$'), ''));
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(isVideo ? 'رفع فيديو جديد' : 'رفع ملف PDF جديد'),
      content: TextField(controller: titleC, maxLength: 120, decoration: const InputDecoration(labelText: 'العنوان')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('رفع')),
      ],
    ),
  );
  if (ok != true || titleC.text.trim().isEmpty || !context.mounted) return;

  final progress = ValueNotifier<double>(0);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('جارٍ الرفع...'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, v, __) => Column(mainAxisSize: MainAxisSize.min, children: [
            LinearProgressIndicator(value: v == 0 ? null : v, minHeight: 8),
            const SizedBox(height: 10),
            Text('${(v * 100).round()}%'),
          ]),
        ),
      ),
    ),
  );
  try {
    final contentType = isVideo ? (name.toLowerCase().endsWith('.mov') ? 'video/quicktime' : 'video/mp4') : 'application/pdf';
    final size = await file.length();
    final res = await _fn.httpsCallable('createGroupUploadUrl').call<Map<String, dynamic>>({
      'groupId': groupId, 'kind': kind, 'fileName': name, 'contentType': contentType, 'size': size,
    });
    final url = (res.data['url'] ?? '').toString();
    final key = (res.data['key'] ?? '').toString();
    if (url.isEmpty || key.isEmpty) throw Exception('رابط الرفع غير مكتمل من الخادم');
    await R2Uploader.put(url: url, file: file, contentType: contentType, onProgress: (p) => progress.value = p);
    await _fn.httpsCallable('registerGroupContent').call<Map<String, dynamic>>({
      'groupId': groupId, 'kind': kind, 'title': titleC.text.trim(), 'r2Key': key, 'size': size, 'contentType': contentType,
    });
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    _snack(context, 'تم الرفع بنجاح');
  } catch (e) {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    _snack(context, 'تعذر الرفع: ${_msg(e)}');
  }
}

// ============================ إنشاء جلسة ============================

Future<void> showCreateSessionDialog(BuildContext context, String groupId) async {
  final titleC = TextEditingController();
  var record = true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: const Text('إنشاء جلسة مباشرة'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: titleC, maxLength: 120, decoration: const InputDecoration(labelText: 'عنوان الجلسة (اختياري)')),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: record,
            onChanged: (v) => setS(() => record = v),
            title: const Text('تسجيل الجلسة'),
            subtitle: const Text('يُضاف التسجيل إلى «الجلسات المسجلة» بعد انتهائها'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ابدأ الآن')),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    final r = await _fn.httpsCallable('startGroupSession').call<Map<String, dynamic>>({
      'groupId': groupId, 'title': titleC.text.trim(), 'record': record,
    });
    final sid = (r.data['sessionId'] ?? '').toString();
    if (sid.isNotEmpty && context.mounted) context.push('/group/$groupId/session/$sid');
  } catch (e) {
    _snack(context, 'تعذر بدء الجلسة: ${_msg(e)}');
  }
}

// ============================ تبويب الطلاب ============================

class GroupStudentsTab extends StatelessWidget {
  final String groupId;
  final GroupRole role;
  const GroupStudentsTab({super.key, required this.groupId, required this.role});

  /// يستخرج الأرقام التعريفية (8 أرقام/حروف) من أي نص: أرقام ملصوقة أو محتوى ملف.
  static List<String> _extractIds(String text) {
    final seen = <String>{};
    for (final t in text.split(RegExp(r'[^0-9A-Za-z]+'))) {
      if (t.length == 8) seen.add(t.toLowerCase());
    }
    return seen.toList();
  }

  Future<void> _invite(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(padding: EdgeInsets.all(14), child: Text('إضافة طلاب', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
          ListTile(leading: const Icon(Icons.person_add_alt_1), title: const Text('دعوة طالب برقمه التعريفي'), onTap: () { Navigator.pop(ctx); _enterIds(context, multi: false); }),
          ListTile(leading: const Icon(Icons.content_paste), title: const Text('لصق عدة أرقام تعريفية'), subtitle: const Text('الصق رسالة فيها أرقام كذا طالب'), onTap: () { Navigator.pop(ctx); _enterIds(context, multi: true); }),
          ListTile(leading: const Icon(Icons.table_chart_outlined), title: const Text('رفع ملف Excel / CSV'), subtitle: const Text('ملف فيه الأرقام التعريفية'), onTap: () { Navigator.pop(ctx); _fromFile(context); }),
          ListTile(leading: const Icon(Icons.link), title: const Text('رابط المجموعة وطلبات الانضمام'), subtitle: const Text('الطلاب يرسلون طلبًا وأنت تقبل أو ترفض'), onTap: () { Navigator.pop(ctx); _linkAndRequests(context); }),
        ]),
      ),
    );
  }

  Future<void> _enterIds(BuildContext context, {required bool multi, String initial = ''}) async {
    final c = TextEditingController(text: initial);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(multi ? 'الأرقام التعريفية' : 'الرقم التعريفي'),
        content: TextField(
          controller: c,
          minLines: multi ? 4 : 1,
          maxLines: multi ? 8 : 1,
          maxLength: multi ? null : 8,
          textDirection: TextDirection.ltr,
          decoration: InputDecoration(labelText: multi ? 'الصق الرسالة أو الأرقام (8 أرقام/حروف لكل طالب)' : 'الرقم التعريفي (8 أرقام/حروف)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('متابعة')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await _confirmAndSend(context, _extractIds(c.text), multi: multi);
  }

  Future<void> _fromFile(BuildContext context) async {
    final pick = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx', 'csv', 'txt'], withData: true);
    final f = pick?.files.single;
    if (f == null || f.bytes == null || !context.mounted) return;
    var text = '';
    try {
      if ((f.extension ?? '').toLowerCase() == 'xlsx') {
        final book = xl.Excel.decodeBytes(f.bytes!);
        final sb = StringBuffer();
        for (final sheet in book.tables.values) {
          for (final row in sheet.rows) {
            for (final cell in row) {
              final v = cell?.value;
              if (v != null) sb.writeln(v.toString());
            }
          }
        }
        text = sb.toString();
      } else {
        text = String.fromCharCodes(f.bytes!);
      }
    } catch (e) {
      _snack(context, 'تعذر قراءة الملف');
      return;
    }
    final ids = _extractIds(text);
    if (ids.isEmpty) {
      _snack(context, 'لم أجد أرقامًا تعريفية في الملف');
      return;
    }
    await _confirmAndSend(context, ids, multi: true);
  }

  /// يعرض أسماء أصحاب الأرقام للتأكيد أو التعديل قبل إرسال الدعوات.
  Future<void> _confirmAndSend(BuildContext context, List<String> ids, {required bool multi}) async {
    if (ids.isEmpty) {
      _snack(context, 'اكتب رقمًا تعريفيًا واحدًا على الأقل');
      return;
    }
    List<dynamic> items;
    try {
      final r = await _fn.httpsCallable('resolveGroupInvitees').call<Map<String, dynamic>>({'groupId': groupId, 'publicIds': ids});
      items = (r.data['items'] as List?) ?? const [];
    } catch (e) {
      _snack(context, _msg(e));
      return;
    }
    if (!context.mounted) return;
    final valid = items.where((e) => e is Map && e['found'] == true && e['alreadyMember'] != true).map((e) => (e as Map)['publicId'].toString()).toList();
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(valid.isEmpty ? 'لا يوجد من يمكن دعوته' : 'هل أنت متأكد من دعوة ${valid.length == 1 ? 'هذا الطالب' : 'هؤلاء الطلاب'}؟'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(shrinkWrap: true, children: [
            for (final e in items)
              if (e is Map)
                ListTile(
                  dense: true,
                  leading: Icon(e['found'] != true ? Icons.error_outline : (e['alreadyMember'] == true ? Icons.info_outline : Icons.check_circle), color: e['found'] != true ? Colors.red : (e['alreadyMember'] == true ? Colors.orange : Colors.green)),
                  title: Text(e['found'] == true ? (e['name'] ?? '').toString() : (e['reason'] ?? 'غير موجود').toString(), style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text('${e['publicId']}${e['alreadyMember'] == true ? ' • عضو بالفعل' : ''}', textDirection: TextDirection.ltr, textAlign: TextAlign.start),
                ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('إلغاء')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'edit'), child: const Text('تعديل الأرقام')),
          if (valid.isNotEmpty) FilledButton(onPressed: () => Navigator.pop(ctx, 'send'), child: Text('تأكيد وإرسال (${valid.length})')),
        ],
      ),
    );
    if (!context.mounted) return;
    if (choice == 'edit') {
      await _enterIds(context, multi: true, initial: ids.join('\n'));
    } else if (choice == 'send') {
      try {
        final r = await _fn.httpsCallable('sendGroupInvites').call<Map<String, dynamic>>({'groupId': groupId, 'publicIds': valid});
        final sent = (r.data['sent'] as List?)?.length ?? 0;
        final skipped = (r.data['skipped'] as List?)?.length ?? 0;
        _snack(context, 'تم إرسال $sent دعوة${skipped > 0 ? ' • تخطي $skipped' : ''}');
      } catch (e) {
        _snack(context, _msg(e));
      }
    }
  }

  Future<void> _linkAndRequests(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _JoinLinkSheet(groupId: groupId),
    );
  }

  Future<void> _editor(BuildContext context, String memberUid, String name, Map<String, dynamic> m) async {
    final isEditor = m['role'] == 'editor';
    final cur = <String, bool>{for (final k in kEditorPerms.keys) k: (m['permissions'] is Map && (m['permissions'] as Map)[k] == true)};
    final res = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(isEditor ? 'صلاحيات المحرر: $name' : 'تعيين $name محررًا'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final e in kEditorPerms.entries)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: cur[e.key],
                onChanged: (v) => setS(() => cur[e.key] = v == true),
                title: Text(e.value),
              ),
          ]),
          actions: [
            if (isEditor) TextButton(onPressed: () => Navigator.pop(ctx, {'editor': false}), child: const Text('إلغاء التحرير', style: TextStyle(color: Colors.red))),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق')),
            FilledButton(onPressed: () => Navigator.pop(ctx, {'editor': true, 'permissions': cur}), child: const Text('حفظ')),
          ],
        ),
      ),
    );
    if (res == null || !context.mounted) return;
    try {
      await _fn.httpsCallable('setGroupEditor').call<Map<String, dynamic>>({'groupId': groupId, 'uid': memberUid, ...res});
      _snack(context, 'تم الحفظ');
    } catch (e) {
      _snack(context, _msg(e));
    }
  }

  Future<void> _remove(BuildContext context, String memberUid, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إزالة طالب'),
        content: Text('هل تريد إزالة $name من المجموعة؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('إزالة')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await _fn.httpsCallable('removeGroupMember').call<Map<String, dynamic>>({'groupId': groupId, 'uid': memberUid});
    } catch (e) {
      _snack(context, _msg(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final members = FirebaseFirestore.instance.collection('groups').doc(groupId).collection('members').snapshots();
    return Column(children: [
      if (role.can('addStudents'))
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: ElevatedButton.icon(onPressed: () => _invite(context), icon: const Icon(Icons.person_add_alt_1), label: const Text('إضافة طالب')),
        ),
      Expanded(
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: members,
          builder: (context, snap) {
            if (snap.hasError) return const Center(child: Text('تعذر تحميل الطلاب'));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final docs = snap.data!.docs;
            if (docs.isEmpty) return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('لا يوجد طلاب بعد.\nأضف طالبًا برقمه التعريفي.', textAlign: TextAlign.center)));
            return ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: docs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final m = docs[i].data();
                final name = (m['name'] ?? 'طالب').toString();
                final isEditor = m['role'] == 'editor';
                return Card(
                  child: ListTile(
                    leading: UserAvatar.fromUid(docs[i].id, radius: 22),
                    title: Row(children: [
                      Flexible(child: Text(name, style: const TextStyle(fontWeight: FontWeight.w800))),
                      if (isEditor)
                        Container(
                          margin: const EdgeInsetsDirectional.only(start: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(99)),
                          child: const Text('محرر', style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w800, fontSize: 11)),
                        ),
                    ]),
                    subtitle: Text((m['publicId'] ?? '').toString(), textDirection: TextDirection.ltr, textAlign: TextAlign.start),
                    trailing: role.isOwner
                        ? PopupMenuButton<String>(
                            onSelected: (v) => v == 'editor' ? _editor(context, docs[i].id, name, m) : _remove(context, docs[i].id, name),
                            itemBuilder: (_) => [
                              PopupMenuItem(value: 'editor', child: Text(isEditor ? 'تعديل صلاحيات المحرر' : 'تعيين كمحرر')),
                              const PopupMenuItem(value: 'remove', child: Text('إزالة من المجموعة')),
                            ],
                          )
                        : null,
                  ),
                );
              },
            );
          },
        ),
      ),
    ]);
  }
}

// ============================ إنشاء اختبار ============================

class _Q {
  String type = 'mcq';
  final text = TextEditingController();
  final points = TextEditingController(text: '1');
  final options = [TextEditingController(), TextEditingController()];
  int correct = 0;
}

class CreateQuizScreen extends StatefulWidget {
  final String groupId;
  const CreateQuizScreen({super.key, required this.groupId});
  @override
  State<CreateQuizScreen> createState() => _CreateQuizScreenState();
}

class _CreateQuizScreenState extends State<CreateQuizScreen> {
  final _title = TextEditingController();
  final List<_Q> _qs = [_Q()];
  bool _saving = false;

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) return _snack(context, 'اكتب عنوان الاختبار');
    final questions = <Map<String, dynamic>>[];
    for (var i = 0; i < _qs.length; i++) {
      final q = _qs[i];
      if (q.text.text.trim().isEmpty) return _snack(context, 'السؤال ${i + 1} فارغ');
      final points = int.tryParse(q.points.text.trim()) ?? 1;
      if (q.type == 'essay') {
        questions.add({'type': 'essay', 'text': q.text.text.trim(), 'points': points});
      } else {
        final opts = [for (final o in q.options) o.text.trim()];
        final nonEmpty = [for (var k = 0; k < opts.length; k++) if (opts[k].isNotEmpty) k];
        if (nonEmpty.length < 2) return _snack(context, 'السؤال ${i + 1}: أضف اختيارين على الأقل');
        if (!nonEmpty.contains(q.correct)) return _snack(context, 'السؤال ${i + 1}: حدّد الإجابة الصحيحة');
        questions.add({
          'type': 'mcq',
          'text': q.text.text.trim(),
          'options': [for (final k in nonEmpty) opts[k]],
          'correct': nonEmpty.indexOf(q.correct),
          'points': points,
        });
      }
    }
    setState(() => _saving = true);
    try {
      await _fn.httpsCallable('createGroupQuiz').call<Map<String, dynamic>>({'groupId': widget.groupId, 'title': _title.text.trim(), 'questions': questions});
      if (!mounted) return;
      _snack(context, 'تم إنشاء الاختبار');
      context.pop();
    } catch (e) {
      _snack(context, _msg(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('إنشاء اختبار جديد')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: _title, maxLength: 120, decoration: const InputDecoration(labelText: 'عنوان الاختبار')),
        const SizedBox(height: 8),
        for (var i = 0; i < _qs.length; i++) _questionCard(i),
        OutlinedButton.icon(onPressed: () => setState(() => _qs.add(_Q())), icon: const Icon(Icons.add), label: const Text('إضافة سؤال')),
        const SizedBox(height: 16),
        ElevatedButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'جارٍ الحفظ...' : 'حفظ الاختبار')),
      ]),
    );
  }

  Widget _questionCard(int i) {
    final q = _qs[i];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text('السؤال ${i + 1}', style: const TextStyle(fontWeight: FontWeight.w900)),
            const Spacer(),
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'mcq', label: Text('اختيارات')), ButtonSegment(value: 'essay', label: Text('مقالي'))],
              selected: {q.type},
              onSelectionChanged: (s) => setState(() => q.type = s.first),
            ),
            if (_qs.length > 1) IconButton(onPressed: () => setState(() => _qs.removeAt(i)), icon: const Icon(Icons.delete_outline, color: Colors.red)),
          ]),
          const SizedBox(height: 8),
          TextField(controller: q.text, maxLines: 2, decoration: const InputDecoration(labelText: 'نص السؤال')),
          const SizedBox(height: 8),
          TextField(controller: q.points, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'الدرجة')),
          if (q.type == 'mcq') ...[
            const SizedBox(height: 8),
            for (var k = 0; k < q.options.length; k++)
              Row(children: [
                Radio<int>(value: k, groupValue: q.correct, onChanged: (v) => setState(() => q.correct = v ?? 0)),
                Expanded(child: TextField(controller: q.options[k], decoration: InputDecoration(labelText: 'الاختيار ${k + 1}${q.correct == k ? ' (الصحيح)' : ''}'))),
              ]),
            if (q.options.length < 6)
              TextButton.icon(onPressed: () => setState(() => q.options.add(TextEditingController())), icon: const Icon(Icons.add), label: const Text('إضافة اختيار')),
          ],
        ]),
      ),
    );
  }
}


/// رابط المجموعة + طلبات الانضمام (قبول/رفض).
class _JoinLinkSheet extends StatefulWidget {
  final String groupId;
  const _JoinLinkSheet({required this.groupId});
  @override
  State<_JoinLinkSheet> createState() => _JoinLinkSheetState();
}

class _JoinLinkSheetState extends State<_JoinLinkSheet> {
  String? _url;
  List<Map<String, dynamic>> _reqs = [];
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final l = await _fn.httpsCallable('getGroupJoinLink').call<Map<String, dynamic>>({'groupId': widget.groupId});
      final r = await _fn.httpsCallable('listGroupJoinRequests').call<Map<String, dynamic>>({'groupId': widget.groupId});
      _url = (l.data['url'] ?? '').toString();
      _reqs = ((r.data['items'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (e) {
      _err = _msg(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _respond(Map<String, dynamic> r, bool accept) async {
    try {
      await _fn.httpsCallable('respondJoinRequest').call<Map<String, dynamic>>({'groupId': widget.groupId, 'uid': r['uid'], 'accept': accept});
      setState(() => _reqs.removeWhere((x) => x['uid'] == r['uid']));
      _snack(context, accept ? 'تم قبول الطالب' : 'تم رفض الطلب');
    } catch (e) {
      _snack(context, _msg(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: _loading
            ? const SizedBox(height: 160, child: Center(child: CircularProgressIndicator()))
            : _err != null
                ? Text(_err!)
                : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('رابط المجموعة', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    const Text('أرسل الرابط للطلاب، يفتحونه ويرسلون طلب انضمام تقبله أو ترفضه هنا.', style: TextStyle(height: 1.5)),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(child: SelectableText(_url ?? '', textDirection: TextDirection.ltr, style: const TextStyle(fontWeight: FontWeight.w700))),
                      IconButton(icon: const Icon(Icons.copy), onPressed: () { Clipboard.setData(ClipboardData(text: _url ?? '')); _snack(context, 'تم نسخ الرابط'); }),
                    ]),
                    const Divider(height: 24),
                    Row(children: [
                      const Expanded(child: Text('طلبات الانضمام', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800))),
                      IconButton(icon: const Icon(Icons.refresh), onPressed: () { setState(() => _loading = true); _load(); }),
                    ]),
                    if (_reqs.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('لا توجد طلبات انضمام حاليًا')),
                    Flexible(
                      child: ListView(shrinkWrap: true, children: [
                        for (final r in _reqs)
                          ListTile(
                            title: Text('${r['name'] ?? 'طالب'}', style: const TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: Text('الرقم التعريفي: ${r['publicId'] ?? ''}', textDirection: TextDirection.ltr, textAlign: TextAlign.start),
                            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                              IconButton(icon: const Icon(Icons.check_circle, color: Colors.green), onPressed: () => _respond(r, true)),
                              IconButton(icon: const Icon(Icons.cancel, color: Colors.red), onPressed: () => _respond(r, false)),
                            ]),
                          ),
                      ]),
                    ),
                  ]),
      ),
    );
  }
}
