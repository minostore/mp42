import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_functions.dart';
import '../theme/app_theme.dart';

/// بطاقة «رقمك التعريفي» (يُولَّد من السيرفر لو لم يكن موجودًا) مع زر نسخ.
class PublicIdCard extends StatefulWidget {
  final EdgeInsetsGeometry margin;
  const PublicIdCard({super.key, this.margin = const EdgeInsets.fromLTRB(14, 10, 14, 0)});

  static String? _cached;

  @override
  State<PublicIdCard> createState() => _PublicIdCardState();
}

class _PublicIdCardState extends State<PublicIdCard> {
  String? _id = PublicIdCard._cached;

  @override
  void initState() {
    super.initState();
    if (_id == null) _load();
  }

  Future<void> _load() async {
    try {
      final r = await FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable('ensurePublicId').call<Map<String, dynamic>>();
      final v = (r.data['publicId'] ?? '').toString();
      if (v.isNotEmpty) {
        PublicIdCard._cached = v;
        if (mounted) setState(() => _id = v);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final id = _id;
    if (id == null) return const SizedBox.shrink();
    return Container(
      margin: widget.margin,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        const Icon(Icons.badge_outlined, color: AppColors.accent),
        const SizedBox(width: 10),
        const Text('رقمك التعريفي:', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(width: 8),
        Expanded(child: Text(id, textDirection: TextDirection.ltr, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17, letterSpacing: 1.5))),
        IconButton(
          tooltip: 'نسخ',
          icon: const Icon(Icons.copy, size: 20),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: id));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم نسخ الرقم التعريفي')));
          },
        ),
      ]),
      // معرّف الحساب الداخلي + البريد: لتحديد أي حساب مسجَّل عليه الجهاز الآن
      Padding(
        padding: const EdgeInsetsDirectional.only(start: 34, bottom: 2),
        child: SelectableText('الحساب: ${FirebaseAuth.instance.currentUser?.email ?? ''}\nUID: ${FirebaseAuth.instance.currentUser?.uid ?? ''}', textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 10.5, color: Colors.black54)),
      ),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: () => _checkMyContent(context),
          icon: const Icon(Icons.search, size: 18),
          label: const Text('لا تظهر كورساتي أو مجموعاتي؟ افحص حسابي', style: TextStyle(fontSize: 12.5)),
        ),
      ),
      ]),
    );
  }
}

/// تشخيص: ما يملكه الحساب الحالي + حسابات أخرى بنفس البريد (غالبًا سبب «اختفاء» الكورسات/المجموعات)، مع نقل المحتوى بتأكيد.
Future<void> _checkMyContent(BuildContext context) async {
  final fn = FirebaseFunctions.instanceFor(region: 'us-central1');
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('فحص حسابي'),
      content: SizedBox(
        width: double.maxFinite,
        child: FutureBuilder<dynamic>(
          future: fn.httpsCallable('diagnoseMyContent').call<Map<String, dynamic>>(),
          builder: (c, snap) {
            if (snap.connectionState != ConnectionState.done) return const SizedBox(height: 90, child: Center(child: CircularProgressIndicator()));
            if (snap.hasError) return Text('تعذر الفحص: ${snap.error}');
            final d = Map<String, dynamic>.from(snap.data.data as Map);
            final mine = Map<String, dynamic>.from(d['mine'] as Map);
            final others = ((d['others'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
            String line(Map<String, dynamic> m) => 'مجموعات أنشأها: ${m['groups']} • كورسات: ${m['courses']} • مجموعات منضم لها: ${m['memberships']} • مشتريات: ${m['purchases']}';
            return SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text('الحساب الحالي: ${d['email']}', style: const TextStyle(fontWeight: FontWeight.w800)),
                Text(line(mine), style: const TextStyle(height: 1.6)),
                const Divider(height: 22),
                if (others.isEmpty) const Text('لا توجد حسابات أخرى بنفس البريد. لو بياناتك ناقصة فهي غالبًا مسجّلة على بريد مختلف؛ سجّل الدخول به.', style: TextStyle(height: 1.6)),
                for (final o in others) ...[
                  Text('حساب آخر بنفس البريد (${o['name']}):', style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text(line(o), style: const TextStyle(height: 1.6)),
                  const SizedBox(height: 6),
                  FilledButton(
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: ctx,
                        builder: (c2) => AlertDialog(
                          title: const Text('نقل المحتوى لحسابي؟'),
                          content: const Text('ستنتقل ملكية المجموعات والكورسات والعضويات والمشتريات من الحساب الآخر إلى حسابك الحالي.'),
                          actions: [TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('نقل'))],
                        ),
                      );
                      if (ok != true) return;
                      try {
                        final r = await fn.httpsCallable('transferContentToMe').call<Map<String, dynamic>>({'fromUid': o['uid']});
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تم النقل: ${r.data['moved']}')));
                        }
                      } catch (e) {
                        if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('تعذر النقل: $e')));
                      }
                    },
                    child: const Text('نقل محتواه لحسابي'),
                  ),
                ],
              ]),
            );
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق'))],
    ),
  );
}
