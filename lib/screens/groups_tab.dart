import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/api_functions.dart';
import '../services/groups_service.dart';
import '../data/categories_tree.dart';
import '../theme/app_theme.dart';
import '../widgets/category_picker.dart';

/// تبويب «المجموعات»: المجموعات التي أنشأها المُفهم + المجموعات التي انضم لها الطالب (تظهر تلقائيًا من منصة فهمت).
class GroupsTab extends StatefulWidget {
  const GroupsTab({super.key});

  @override
  State<GroupsTab> createState() => _GroupsTabState();
}

class _GroupsTabState extends State<GroupsTab> {
  final _service = GroupsService();
  CategoryChoice _filter = const CategoryChoice();
  StreamSubscription? _a, _b;
  List<Map<String, dynamic>> _owned = [];
  List<Map<String, dynamic>> _joined = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _loading = false;
      return;
    }
    _a = _service.watchOwned(uid).listen((snap) {
      _owned = snap.docs.map((d) => {'id': d.id, ...d.data(), 'owner': true}).toList();
      if (mounted) setState(() => _loading = false);
    }, onError: (e) {
      if (mounted) setState(() { _error = 'تعذر تحميل المجموعات'; _loading = false; });
    });
    _b = _service.watchMemberships(uid).listen((snap) async {
      final groups = <Map<String, dynamic>>[];
      for (final m in snap.docs) {
        try {
          final g = await _service.getGroup(m.id);
          if (g.exists) groups.add({'id': g.id, ...?g.data(), 'owner': false});
        } catch (_) {/* مجموعة محذوفة أو متوقفة */}
      }
      _joined = groups;
      if (mounted) setState(() => _loading = false);
    }, onError: (e) {
      if (mounted) setState(() => _loading = false);
    });
  }

  @override
  void dispose() {
    _a?.cancel();
    _b?.cancel();
    super.dispose();
  }

  Future<void> _create() async {
    final nameC = TextEditingController();
    final descC = TextEditingController();
    var choice = const CategoryChoice();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('إنشاء مجموعة جديدة'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: nameC, maxLength: 80, decoration: const InputDecoration(labelText: 'اسم المجموعة')),
              TextField(controller: descC, maxLength: 500, maxLines: 2, decoration: const InputDecoration(labelText: 'وصف (اختياري)')),
              const SizedBox(height: 8),
              CategoryPicker(value: choice, onChanged: (c) => setS(() => choice = c)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('إنشاء')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (nameC.text.trim().length < 3) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('اسم المجموعة 3 أحرف على الأقل')));
      return;
    }
    if (choice.isEmpty || (isOtherNode(choice.main, choice.sub, choice.opt) && choice.custom.isEmpty)) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('اختر قسم المجموعة')));
      return;
    }
    try {
      final r = await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('createGroup')
          .call<Map<String, dynamic>>({'name': nameC.text.trim(), 'description': descC.text.trim(), ...choice.toFields()});
      final id = (r.data['groupId'] ?? '').toString();
      if (mounted && id.isNotEmpty) context.push('/group/$id');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _respond(String inviteId, bool accept) async {
    try {
      await FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable('respondGroupInvite').call<Map<String, dynamic>>({'inviteId': inviteId, 'accept': accept});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Widget _list(List<Map<String, dynamic>> all, String empty) {
    final list = all.where((g) => _filter.matches(g)).toList();
    if (list.isEmpty) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(empty, textAlign: TextAlign.center)));
    return ListView.separated(
      padding: const EdgeInsets.all(14),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final g = list[i];
        final frozen = (g['status'] ?? 'active') != 'active';
        return Card(
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: frozen ? Colors.grey.shade300 : AppColors.primaryLight,
              child: Icon(frozen ? Icons.ac_unit : Icons.groups, color: AppColors.primaryDark),
            ),
            title: Text((g['name'] ?? 'مجموعة').toString(), style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(frozen
                ? 'المجموعة متوقفة مؤقتًا'
                : '${g['owner'] == true ? 'أنت صاحب المجموعة' : 'المُفهم: ${g['ownerName'] ?? ''}'} • ${g['memberCount'] ?? 0} طالب'),
            trailing: const Icon(Icons.chevron_left),
            onTap: frozen ? null : () => context.push('/group/${g['id']}'),
          ),
        );
      },
    );
  }

  Widget _invites() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const SizedBox.shrink();
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('groupInvites').where('toUid', isEqualTo: uid).snapshots(),
      builder: (context, snap) {
        final pending = (snap.data?.docs ?? []).where((d) => d.data()['status'] == 'pending').toList();
        if (pending.isEmpty) return const SizedBox.shrink();
        return Column(children: [
          for (final d in pending)
            Card(
              color: AppColors.primaryLight,
              margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: ListTile(
                title: Text('دعوة للانضمام: ${d.data()['groupName'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text('من: ${d.data()['ownerName'] ?? ''}'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(icon: const Icon(Icons.check_circle, color: Colors.green), onPressed: () => _respond(d.id, true)),
                  IconButton(icon: const Icon(Icons.cancel, color: Colors.red), onPressed: () => _respond(d.id, false)),
                ]),
              ),
            ),
        ]);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('المجموعات'),
          centerTitle: true,
          bottom: const TabBar(tabs: [Tab(text: 'مجموعات أنشأتها'), Tab(text: 'مجموعات انضممت لها')]),
        ),
        floatingActionButton: FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.add), label: const Text('إنشاء مجموعة جديدة')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text(_error!))
                : Column(children: [
                    const SizedBox(height: 8),
                    CategoryFilterButton(value: _filter, onChanged: (c) => setState(() => _filter = c)),
                    Expanded(child: TabBarView(children: [
                    _list(_owned, 'لم تنشئ أي مجموعة بعد.\nاضغط «إنشاء مجموعة جديدة» للبدء.'),
                    Column(children: [
                      _invites(),
                      Expanded(child: _list(_joined, 'لم تنضم لأي مجموعة بعد.\nعندما يدعوك صاحب مجموعة برقمك التعريفي ستظهر الدعوة هنا، وتنضم بعد قبولها.')),
                    ]),
                  ])),
                  ]),
      ),
    );
  }
}
