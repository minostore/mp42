import 'course_validity.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/course.dart';
import '../services/api_functions.dart';

/// نافذة شراء كورس (نفس منطق المنصة): الدفع من رصيد المحفظة، أو بطرق الدفع الخارجية
/// (يكتب المستخدم الرقم الذي دفع منه، ويُفعَّل الكورس بعد التحقق من العملية).
/// ترجع true لو تم الشراء/أُرسل الطلب.
Future<bool> showCoursePurchaseSheet(BuildContext context, Course course) async {
  final r = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _PurchaseSheet(course: course),
  );
  return r == true;
}

class _PurchaseSheet extends StatefulWidget {
  final Course course;
  const _PurchaseSheet({required this.course});
  @override
  State<_PurchaseSheet> createState() => _PurchaseSheetState();
}

class _PurchaseSheetState extends State<_PurchaseSheet> {
  final _phone = TextEditingController();
  List<Map<String, dynamic>> _methods = [];
  String _method = 'balance';
  double _balance = 0;
  bool _loading = true;
  bool _busy = false;
  String? _msg;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = FirebaseFirestore.instance;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    try {
      final ms = await db.collection('paymentMethods').where('active', isEqualTo: true).get();
      _methods = ms.docs.map((d) => {'id': d.id, ...d.data()}).toList();
    } catch (_) {}
    if (uid != null) {
      try {
        final w = await db.collection('wallets').doc(uid).get();
        final b = w.data()?['balance'];
        if (b is num) _balance = b.toDouble();
      } catch (_) {}
    }
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, String>> _accounts(Map<String, dynamic> m) {
    final list = m['accounts'];
    final out = <Map<String, String>>[];
    if (list is List) {
      for (final a in list) {
        if (a is Map && (a['number'] ?? '').toString().isNotEmpty) out.add({'label': (a['label'] ?? '').toString(), 'number': a['number'].toString()});
      }
    }
    if (out.isEmpty && (m['accountNumber'] ?? '').toString().isNotEmpty) out.add({'label': (m['name'] ?? '').toString(), 'number': m['accountNumber'].toString()});
    return out;
  }

  Future<void> _buy() async {
    final price = widget.course.price;
    if (_method == 'balance' && _balance + 0.0001 < price) {
      setState(() => _msg = 'رصيد المحفظة غير كافٍ (${_balance.toStringAsFixed(2)} جنيه). اشحن المحفظة أو اختر طريقة دفع أخرى.');
      return;
    }
    if (_method != 'balance' && _phone.text.replaceAll(RegExp(r'[^\d+]'), '').length < 8) {
      setState(() => _msg = 'اكتب رقم الحساب/الهاتف الذي دفعت منه');
      return;
    }
    setState(() { _busy = true; _msg = null; });
    try {
      final res = await FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable('purchaseCourse').call<Map<String, dynamic>>({
        'courseId': widget.course.id,
        'paymentMethod': _method,
        if (_method != 'balance') 'phone': _phone.text.trim(),
        'source': 'app',
      });
      final pending = res.data['pending'] == true;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(pending ? 'تم استلام طلبك، سيُفعَّل الكورس بعد التحقق من الدفع' : 'تم شراء الكورس بنجاح')));
      Navigator.pop(context, true);
    } on FirebaseFunctionsException catch (e) {
      if (mounted) setState(() => _msg = e.message ?? 'تعذر إتمام الشراء');
    } catch (e) {
      if (mounted) setState(() => _msg = 'تعذر إتمام الشراء: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final price = widget.course.price;
    Map<String, dynamic>? sel;
    for (final m in _methods) {
      if (m['id'] == _method) sel = m;
    }
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: _loading
            ? const SizedBox(height: 180, child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                padding: const EdgeInsets.all(18),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text('شراء: ${widget.course.title}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(price <= 0 ? 'مجاني' : '${price.toStringAsFixed(price % 1 == 0 ? 0 : 2)} جنيه', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 4),
                  Text('صلاحية الكورس: ${courseValidityLabel(widget.course.raw)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    value: 'balance',
                    groupValue: _method,
                    onChanged: (v) => setState(() => _method = v!),
                    title: const Text('رصيد المحفظة'),
                    subtitle: Text('رصيدك: ${_balance.toStringAsFixed(2)} جنيه'),
                  ),
                  for (final m in _methods)
                    RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      value: m['id'].toString(),
                      groupValue: _method,
                      onChanged: (v) => setState(() => _method = v!),
                      title: Text((m['name'] ?? m['id']).toString()),
                    ),
                  if (sel != null) ...[
                    const Text('حوّل المبلغ على:', style: TextStyle(fontWeight: FontWeight.w700)),
                    for (final a in _accounts(sel))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(a['number']!, textDirection: TextDirection.ltr, style: const TextStyle(fontWeight: FontWeight.w800)),
                        subtitle: a['label']!.isEmpty ? null : Text(a['label']!),
                        trailing: IconButton(icon: const Icon(Icons.copy, size: 18), onPressed: () => Clipboard.setData(ClipboardData(text: a['number']!))),
                      ),
                    TextField(controller: _phone, keyboardType: TextInputType.phone, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'الرقم الذي دفعت منه')),
                  ],
                  if (_msg != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_msg!, style: const TextStyle(color: Color(0xFFDC2626)))),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _busy ? null : _buy,
                      child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('تأكيد الشراء'),
                    ),
                  ),
                ]),
              ),
      ),
    );
  }
}
