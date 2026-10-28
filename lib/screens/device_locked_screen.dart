import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/device_lock_service.dart';

/// الحساب مرتبط بجهاز آخر: المستخدم يرسل طلبًا رسميًا (مع السبب) فتراجعه الإدارة،
/// وبعد الموافقة يضغط «تحقق الآن» فيدخل بجهازه الجديد.
class DeviceLockedScreen extends StatefulWidget {
  const DeviceLockedScreen({super.key});
  @override
  State<DeviceLockedScreen> createState() => _DeviceLockedScreenState();
}

class _DeviceLockedScreenState extends State<DeviceLockedScreen> {
  final _reason = TextEditingController();
  String _status = 'none';
  String _note = '';
  bool _busy = false;
  String? _msg;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final s = await DeviceLockService.requestStatus();
    if (mounted) setState(() { _status = s.status; _note = s.note; });
  }

  Future<void> _send() async {
    setState(() { _busy = true; _msg = null; });
    final err = await DeviceLockService.requestChange(_reason.text.trim());
    if (!mounted) return;
    setState(() { _busy = false; _msg = err ?? 'تم إرسال طلبك، سنراجعه قريبًا.'; });
    if (err == null) _refresh();
  }

  Future<void> _check() async {
    setState(() { _busy = true; _msg = null; });
    final lock = await DeviceLockService.claim();
    if (!mounted) return;
    if (!lock.locked) {
      context.go('/home');
      return;
    }
    setState(() { _busy = false; });
    await _refresh();
    if (mounted) setState(() => _msg = _status == 'rejected' ? 'تم رفض الطلب. ${_note.isEmpty ? '' : _note}' : 'لم تتم الموافقة بعد.');
  }

  Future<void> _signOut() async {
    await FirebaseAuth.instance.signOut();
    if (mounted) context.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    final pending = _status == 'pending';
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(title: const Text('الحساب مسجّل على جهاز آخر'), automaticallyImplyLeading: false),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Icon(Icons.phonelink_lock, size: 56),
            const SizedBox(height: 12),
            const Text('هذا الحساب مرتبط بجهاز آخر، ولا يمكن استخدامه على أكثر من جهاز. لو غيّرت هاتفك أو فقدته أرسل طلبًا لاعتماد هذا الجهاز وستراجعه الإدارة.', style: TextStyle(height: 1.6)),
            const SizedBox(height: 16),
            if (pending) const Card(child: Padding(padding: EdgeInsets.all(14), child: Text('طلبك قيد المراجعة. اضغط «تحقق الآن» بعد الموافقة.', style: TextStyle(fontWeight: FontWeight.w700))))
            else ...[
              TextField(controller: _reason, maxLines: 3, maxLength: 500, decoration: const InputDecoration(labelText: 'سبب طلب تغيير الجهاز (مثلًا: فقدت الهاتف / غيّرت الهاتف)')),
              const SizedBox(height: 8),
              FilledButton(onPressed: _busy ? null : _send, child: const Text('إرسال الطلب للإدارة')),
            ],
            const SizedBox(height: 10),
            OutlinedButton(onPressed: _busy ? null : _check, child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('تحقق الآن')),
            if (_msg != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_msg!, style: const TextStyle(fontWeight: FontWeight.w700))),
            const SizedBox(height: 16),
            TextButton(onPressed: _signOut, child: const Text('تسجيل الخروج')),
          ],
        ),
      ),
    );
  }
}
