import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/categories_tree.dart';
import '../services/gender_rules.dart';
import '../theme/app_theme.dart';
import '../widgets/category_picker.dart';
import '../widgets/user_avatar.dart';
import 'hub_common.dart';

CollectionReference<Map<String, dynamic>> get _istifhams => FirebaseFirestore.instance.collection('istifhams');

// ======================= تصفح الاستفهامات =======================
class BrowseRequestsScreen extends StatefulWidget {
  final bool embedded; // داخل تبويب «الاستفهامات» بدون شريط علوي
  const BrowseRequestsScreen({super.key, this.embedded = false});
  @override
  State<BrowseRequestsScreen> createState() => _BrowseRequestsScreenState();
}

class _BrowseRequestsScreenState extends State<BrowseRequestsScreen> {
  String _q = '';
  CategoryChoice _cat = const CategoryChoice();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('تصفح الاستفهامات')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/requests/new'),
        icon: const Icon(Icons.add),
        label: const Text('طرح استفهام جديد'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: TextField(
            onChanged: (v) => setState(() => _q = v.trim()),
            decoration: const InputDecoration(hintText: 'ابحث في الاستفهامات...', prefixIcon: Icon(Icons.search)),
          ),
        ),
        CategoryFilterButton(value: _cat, onChanged: (c) => setState(() => _cat = c)),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _istifhams.where('status', isEqualTo: 'active').limit(100).snapshots(),
            builder: (context, snap) {
              if (snap.hasError) return EmptyHint(icon: Icons.error_outline, text: 'تعذر تحميل الاستفهامات\n${snap.error}');
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final docs = snap.data!.docs.where((d) {
                final m = d.data();
                if (!_cat.matches(m)) return false;
                if (_q.isEmpty) return true;
                return '${m['title']} ${m['description']} ${m['category']} ${m['categorySub']} ${m['categoryOpt']} ${m['categoryCustom']}'.contains(_q);
              }).toList()
                ..sort((a, b) => (parseDate(b['createdAt']) ?? DateTime(2000)).compareTo(parseDate(a['createdAt']) ?? DateTime(2000)));
              if (docs.isEmpty) return const EmptyHint(icon: Icons.help_outline, text: 'لا توجد استفهامات مفتوحة حاليًا');
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 90),
                itemCount: docs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) => RequestCard(id: docs[i].id, data: docs[i].data()),
              );
            },
          ),
        ),
      ]),
    );
  }
}

class RequestCard extends StatelessWidget {
  final String id;
  final Map<String, dynamic> data;
  final String? me;
  const RequestCard({super.key, required this.id, required this.data, this.me});

  @override
  Widget build(BuildContext context) {
    final status = (data['status'] ?? '').toString();
    final who = me != null && data['mustafhemId'] == me ? (data['mufhemName'] ?? 'بانتظار مفهم') : (data['mustafhemName'] ?? '');
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => context.push('/requests/$id'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text((data['title'] ?? '').toString(), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.primaryDark))),
              StatusChip(status),
            ]),
            const SizedBox(height: 6),
            Text((data['description'] ?? '').toString(), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.muted, height: 1.5)),
            const SizedBox(height: 8),
            Wrap(spacing: 14, runSpacing: 4, children: [
              _meta(Icons.person_outline, who.toString()),
              _meta(Icons.access_time, 'منذ ${timeAgo(data['createdAt'])}'),
              if ((data['category'] ?? '').toString().isNotEmpty) _meta(Icons.category_outlined, CategoryChoice.fromMap(data).leaf),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _meta(IconData i, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(i, size: 14, color: AppColors.muted),
        const SizedBox(width: 4),
        Text(t, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
      ]);
}

// ======================= استفهاماتي =======================
class MyRequestsScreen extends StatelessWidget {
  final bool embedded;
  const MyRequestsScreen({super.key, this.embedded = false});

  static const _tabs = <(String, String)>[
    ('pending_approval', 'المراجعة'),
    ('active', 'الانتظار'),
    ('accepted', 'المقبولة'),
    ('paid', 'المدفوعة'),
    ('completed', 'المكتملة'),
    ('canceled', 'الملغية'),
  ];

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const Scaffold(body: Center(child: Text('سجّل الدخول أولًا')));
    return DefaultTabController(
      length: _tabs.length,
      child: Scaffold(
        appBar: embedded
            ? PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: Material(color: Colors.white, child: TabBar(isScrollable: true, tabs: [for (final t in _tabs) Tab(text: t.$2)])),
              )
            : AppBar(
                title: const Text('استفهاماتي'),
                bottom: TabBar(isScrollable: true, tabs: [for (final t in _tabs) Tab(text: t.$2)]),
              ),
        floatingActionButton: embedded
            ? null
            : FloatingActionButton.extended(
                onPressed: () => context.push('/requests/new'),
                icon: const Icon(Icons.add),
                label: const Text('طرح استفهام'),
              ),
        body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _istifhams.where('mustafhemId', isEqualTo: uid).limit(50).snapshots(),
          builder: (context, a) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _istifhams.where('mufhemId', isEqualTo: uid).limit(50).snapshots(),
            builder: (context, b) {
              if (!a.hasData && !b.hasData) return const Center(child: CircularProgressIndicator());
              final map = <String, Map<String, dynamic>>{};
              for (final d in [...?a.data?.docs, ...?b.data?.docs]) {
                map[d.id] = d.data();
              }
              final all = map.entries.toList()
                ..sort((x, y) => (parseDate(y.value['createdAt']) ?? DateTime(2000)).compareTo(parseDate(x.value['createdAt']) ?? DateTime(2000)));
              return TabBarView(children: [
                for (final t in _tabs)
                  Builder(builder: (_) {
                    final items = all.where((e) => e.value['status'] == t.$1).toList();
                    if (items.isEmpty) return const EmptyHint(icon: Icons.assignment_outlined, text: 'لا توجد استفهامات في هذا القسم حاليًا');
                    return ListView.separated(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 90),
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (_, i) => RequestCard(id: items[i].key, data: items[i].value, me: uid),
                    );
                  }),
              ]);
            },
          ),
        ),
      ),
    );
  }
}

// ======================= تفاصيل الاستفهام =======================
class RequestDetailScreen extends StatelessWidget {
  final String requestId;
  const RequestDetailScreen({super.key, required this.requestId});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return Scaffold(
      appBar: AppBar(title: const Text('تفاصيل الاستفهام')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: _istifhams.doc(requestId).snapshots(),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final r = snap.data!.data();
          if (r == null) return const EmptyHint(icon: Icons.search_off, text: 'الاستفهام غير موجود');
          final status = (r['status'] ?? '').toString();
          final isOwner = uid != null && r['mustafhemId'] == uid;
          return StreamBuilder<String>(
            stream: uid == null ? const Stream.empty() : watchWebRole(uid),
            builder: (context, roleSnap) {
              final isMufhem = roleSnap.data == 'mufhem';
              return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _istifhams.doc(requestId).collection('offers').orderBy('createdAt', descending: true).snapshots(),
                builder: (context, offersSnap) {
                  final offers = offersSnap.data?.docs ?? [];
                  QueryDocumentSnapshot<Map<String, dynamic>>? mine;
                  for (final o in offers) {
                    if (o.data()['mufhemId'] == uid) mine = o;
                  }
                  return ListView(padding: const EdgeInsets.all(16), children: [
                    Row(children: [
                      if ((r['category'] ?? '').toString().isNotEmpty)
                        Flexible(child: Chip(label: Text(CategoryChoice.fromMap(r).label, overflow: TextOverflow.ellipsis), backgroundColor: AppColors.primaryLight)),
                      const Spacer(),
                      StatusChip(status),
                    ]),
                    Text((r['title'] ?? '').toString(), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, height: 1.4)),
                    const SizedBox(height: 4),
                    Text('${r['mustafhemName'] ?? ''} • منذ ${timeAgo(r['createdAt'])}', style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                    const SizedBox(height: 16),
                    _section('تفاصيل الاستفهام', Icons.description_outlined, (r['description'] ?? '').toString()),
                    if ((r['goal'] ?? '').toString().isNotEmpty) _section('الهدف المرجو تحقيقه', Icons.flag_outlined, (r['goal'] ?? '').toString()),
                    if (r['meetingTime'] != null) _section('الموعد المقترح', Icons.event, prettyDateTime(r['meetingTime'])),
                    const SizedBox(height: 8),
                    // المفهم: تقديم عرض
                    if (!isOwner && isMufhem && status == 'active' && uid != null)
                      FutureBuilder<String?>(
                        future: GenderRules.offerBlockReason(mufhemUid: uid, mustafhemUid: (r['mustafhemId'] ?? '').toString()),
                        builder: (context, g) {
                          if (g.connectionState != ConnectionState.done) return const LinearProgressIndicator();
                          final reason = g.data;
                          if (reason != null) {
                            return Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(12)),
                              child: Text(reason, style: const TextStyle(color: Color(0xFFB91C1C), fontWeight: FontWeight.w700, height: 1.6)),
                            );
                          }
                          return ElevatedButton.icon(
                            onPressed: () => context.push('/requests/$requestId/offer'),
                            icon: const Icon(Icons.bolt),
                            label: Text(mine == null ? 'قدّم عرضك الآن' : 'تعديل عرضي'),
                          );
                        },
                      ),
                    if (mine != null && !isOwner)
                      Card(
                        color: const Color(0xFFEFF6FF),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Text('لقد قدّمت عرضًا بالفعل', style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF1D4ED8))),
                            const SizedBox(height: 4),
                            Text((mine.data()['details'] ?? '').toString()),
                            Text('الموعد: ${prettyDateTime(mine.data()['readyAt'])}', style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                          ]),
                        ),
                      ),
                    // دخول المحاضرة بعد الدفع
                    if (status == 'paid' && uid != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: ElevatedButton.icon(
                          onPressed: () => context.push('/meeting/$requestId'),
                          icon: const Icon(Icons.video_call),
                          label: const Text('دخول المحاضرة'),
                        ),
                      ),
                    // صاحب الاستفهام: العروض المقدمة
                    if (isOwner && status == 'active') ...[
                      const SizedBox(height: 18),
                      Text('العروض المقدمة (${offers.length})', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 8),
                      if (offers.isEmpty) const EmptyHint(icon: Icons.hourglass_empty, text: 'لم يصلك أي عرض بعد'),
                      for (final o in offers) _offerCard(context, o.id, o.data()),
                    ],
                  ]);
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _section(String title, IconData icon, String body) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Icon(icon, size: 18, color: AppColors.primary), const SizedBox(width: 6), Text(title, style: const TextStyle(fontWeight: FontWeight.w800))]),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: AppColors.paperDim, borderRadius: BorderRadius.circular(14)),
            child: Text(body, style: const TextStyle(height: 1.7)),
          ),
        ]),
      );

  Widget _offerCard(BuildContext context, String offerId, Map<String, dynamic> o) {
    final avatar = (o['mufhemAvatar'] ?? '').toString();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            (o['mufhemId'] ?? '').toString().isEmpty ? UserAvatar(photoUrl: avatar) : UserAvatar.fromUid(o['mufhemId'].toString()),
            const SizedBox(width: 10),
            Expanded(child: InkWell(onTap: () => context.push('/mufhems/${o['mufhemId']}'), child: Text((o['mufhemName'] ?? '').toString(), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)))),
          ]),
          const SizedBox(height: 8),
          Text((o['details'] ?? '').toString(), style: const TextStyle(height: 1.6)),
          const SizedBox(height: 6),
          Text('موعد الجاهزية: ${prettyDateTime(o['readyAt'])}', style: const TextStyle(color: AppColors.muted, fontSize: 12)),
          const SizedBox(height: 10),
          // الدفع متاح على المنصة فقط (التطبيق بدون دفع)
          ElevatedButton(
            onPressed: () => openWebPage(context, '/checkout/$requestId?offerId=$offerId', inApp: false),
            child: const Text('قبول العرض (إتمام الدفع على المنصة)'),
          ),
        ]),
      ),
    );
  }
}

// ======================= تقديم عرض =======================
class MakeOfferScreen extends StatefulWidget {
  final String requestId;
  const MakeOfferScreen({super.key, required this.requestId});
  @override
  State<MakeOfferScreen> createState() => _MakeOfferScreenState();
}

class _MakeOfferScreenState extends State<MakeOfferScreen> {
  final _details = TextEditingController();
  DateTime? _readyAt;
  bool _saving = false;
  String? _existingId;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      final q = await _istifhams.doc(widget.requestId).collection('offers').where('mufhemId', isEqualTo: uid).limit(1).get();
      if (q.docs.isNotEmpty) {
        _existingId = q.docs.first.id;
        _details.text = (q.docs.first.data()['details'] ?? '').toString();
        _readyAt = parseDate(q.docs.first.data()['readyAt']);
      }
    }
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _submit() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (_readyAt == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('حدّد موعد جاهزيتك للجلسة')));
      return;
    }
    setState(() => _saving = true);
    try {
      final reqSnap = await _istifhams.doc(widget.requestId).get();
      final reason = await GenderRules.offerBlockReason(
        mufhemUid: user.uid,
        mustafhemUid: (reqSnap.data()?['mustafhemId'] ?? '').toString(),
      );
      if (reason != null) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(reason)));
        return;
      }
      final col = _istifhams.doc(widget.requestId).collection('offers');
      final base = {'readyAt': webDateTime(_readyAt!), 'details': _details.text.trim()};
      if (_existingId != null) {
        await col.doc(_existingId).update(base);
      } else {
        await col.add({
          'mufhemId': user.uid,
          'mufhemName': user.displayName ?? 'مفهم',
          'mufhemAvatar': '',
          'amount': 0, // الفترة المجانية: دائمًا صفر
          ...base,
          'status': 'pending',
          'createdAt': DateTime.now().toIso8601String(),
        });
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم إرسال عرضك بنجاح')));
      context.pop();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('فشل إرسال العرض: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تقديم عرض تفهيم')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: _istifhams.doc(widget.requestId).snapshots(),
                builder: (_, s) {
                  final r = s.data?.data();
                  if (r == null) return const SizedBox.shrink();
                  return Card(
                    color: AppColors.primaryDark,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('أنت تقدّم عرضًا على:', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        Text((r['title'] ?? '').toString(), style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
                      ]),
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              const Text('موعد جاهزيتك للجلسة', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: () async {
                  final d = await pickDateTime(context);
                  if (d != null) setState(() => _readyAt = d);
                },
                icon: const Icon(Icons.event),
                label: Text(_readyAt == null ? 'اختر التاريخ والوقت' : prettyDateTime(_readyAt!.toIso8601String())),
              ),
              const SizedBox(height: 16),
              const Text('خطة الشرح الخاصة بك', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              TextField(controller: _details, maxLines: 6, decoration: const InputDecoration(hintText: 'اشرح كيف ستساعد المستفهم...')),
              const SizedBox(height: 20),
              ElevatedButton(onPressed: _saving ? null : _submit, child: Text(_saving ? 'جارٍ الإرسال...' : (_existingId == null ? 'إرسال العرض' : 'حفظ التعديل'))),
            ]),
    );
  }
}

// ======================= طرح استفهام جديد =======================
class CreateRequestScreen extends StatefulWidget {
  const CreateRequestScreen({super.key});
  @override
  State<CreateRequestScreen> createState() => _CreateRequestScreenState();
}

class _CreateRequestScreenState extends State<CreateRequestScreen> {
  final _title = TextEditingController();
  final _desc = TextEditingController();
  final _goal = TextEditingController();
  CategoryChoice _choice = const CategoryChoice();
  DateTime? _when;
  bool _saving = false;

  Future<void> _submit() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (_title.text.trim().isEmpty || _desc.text.trim().isEmpty || _goal.text.trim().isEmpty || _choice.isEmpty || (isOtherNode(_choice.main, _choice.sub, _choice.opt) && _choice.custom.isEmpty) || _when == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('يرجى تعبئة كافة الحقول المطلوبة')));
      return;
    }
    setState(() => _saving = true);
    try {
      await _istifhams.add({
        'title': _title.text.trim(),
        'description': _desc.text.trim(),
        'goal': _goal.text.trim(),
        ..._choice.toFields(),
        'meetingTime': webDateTime(_when!),
        'originalAmount': 0,
        'amount': 0,
        'couponApplied': null,
        'status': 'pending_approval',
        'mustafhemId': user.uid,
        'mustafhemName': user.displayName ?? 'مستخدم',
        'createdAt': DateTime.now().toIso8601String(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم الإرسال! سيتم مراجعة طلبك ونشره خلال دقائق')));
      context.pop();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('فشل إرسال الطلب: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('طرح استفهام جديد')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: _title, decoration: const InputDecoration(labelText: 'عنوان الاستفهام')),
        const SizedBox(height: 12),
        TextField(controller: _desc, maxLines: 5, decoration: const InputDecoration(labelText: 'تفاصيل الاستفهام')),
        const SizedBox(height: 12),
        TextField(controller: _goal, maxLines: 3, decoration: const InputDecoration(labelText: 'الهدف المرجو تحقيقه')),
        const SizedBox(height: 12),
        CategoryPicker(value: _choice, onChanged: (c) => setState(() => _choice = c)),
        const Text('الموعد المقترح للمحاضرة', style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        OutlinedButton.icon(
          onPressed: () async {
            final d = await pickDateTime(context);
            if (d != null) setState(() => _when = d);
          },
          icon: const Icon(Icons.event),
          label: Text(_when == null ? 'اختر التاريخ والوقت' : prettyDateTime(_when!.toIso8601String())),
        ),
        const SizedBox(height: 20),
        ElevatedButton(onPressed: _saving ? null : _submit, child: Text(_saving ? 'جارٍ الإرسال...' : 'نشر الاستفهام')),
      ]),
    );
  }
}

// ======================= عروضي (للمفهم) =======================
class MyOffersScreen extends StatelessWidget {
  const MyOffersScreen({super.key});

  Future<List<(String, Map<String, dynamic>, Map<String, dynamic>)>> _load(String uid) async {
    // نفس طريقة الويب: لا توجد قاعدة collectionGroup، فنمر على الاستفهامات الظاهرة.
    final reqs = await _istifhams.where('status', whereIn: ['active', 'accepted', 'paid', 'completed']).limit(150).get();
    final results = await Future.wait(reqs.docs.map((r) async {
      final o = await r.reference.collection('offers').where('mufhemId', isEqualTo: uid).limit(1).get();
      if (o.docs.isEmpty) return null;
      return (r.id, r.data(), {...o.docs.first.data(), 'id': o.docs.first.id});
    }));
    final list = results.whereType<(String, Map<String, dynamic>, Map<String, dynamic>)>().toList()
      ..sort((a, b) => (parseDate(b.$3['createdAt']) ?? DateTime(2000)).compareTo(parseDate(a.$3['createdAt']) ?? DateTime(2000)));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return Scaffold(
      appBar: AppBar(title: const Text('عروضي')),
      body: uid == null
          ? const EmptyHint(icon: Icons.lock_outline, text: 'سجّل الدخول أولًا')
          : FutureBuilder(
              future: _load(uid),
              builder: (context, snap) {
                if (snap.hasError) return EmptyHint(icon: Icons.error_outline, text: 'تعذر تحميل عروضك\n${snap.error}');
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final items = snap.data!;
                if (items.isEmpty) return const EmptyHint(icon: Icons.bolt, text: 'لم تقدّم أي عروض بعد.\nتصفّح الاستفهامات وقدّم عرضك الأول');
                return ListView.separated(
                  padding: const EdgeInsets.all(14),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final (id, r, o) = items[i];
                    return Card(
                      child: ListTile(
                        onTap: () => context.push('/requests/$id'),
                        title: Text((r['title'] ?? '').toString(), style: const TextStyle(fontWeight: FontWeight.w800)),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text('${o['details'] ?? ''}\nموعدك: ${prettyDateTime(o['readyAt'])}', maxLines: 3, overflow: TextOverflow.ellipsis),
                        ),
                        trailing: StatusChip((r['status'] ?? '').toString()),
                        isThreeLine: true,
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}
