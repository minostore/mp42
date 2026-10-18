import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/api_functions.dart';
import '../services/auth_service.dart';

/// تغيير كلمة المرور:
///  1) الطريقة العادية: كلمة المرور الحالية ثم الجديدة وتأكيدها.
///  2) لو نسي الحالية: كود تأكيد يُرسل على الإيميل أو رقم الهاتف (حسب اختياره) ثم كلمة جديدة.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});
  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _oldPass = TextEditingController();
  final _newPass = TextEditingController();
  final _confirm = TextEditingController();
  final _code = TextEditingController();
  bool _loading = false;
  bool _obscure = true;

  bool _forgot = false; // وضع «نسيت كلمة المرور الحالية»
  String _channel = 'email'; // email | phone
  bool _codeSent = false;
  String _sentTo = '';

  @override
  void dispose() {
    _oldPass.dispose();
    _newPass.dispose();
    _confirm.dispose();
    _code.dispose();
    super.dispose();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  String? _validateNew() {
    if (_newPass.text.length < 6) return 'كلمة المرور يجب أن تكون 6 أحرف على الأقل';
    if (_newPass.text != _confirm.text) return 'كلمتا المرور غير متطابقتين';
    return null;
  }

  Future<void> _saveWithOld() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || (user.email ?? '').isEmpty) { _snack('يجب تسجيل الدخول أولاً'); return; }
    if (_oldPass.text.isEmpty) { _snack('اكتب كلمة المرور الحالية'); return; }
    final err = _validateNew();
    if (err != null) { _snack(err); return; }
    if (_newPass.text == _oldPass.text) { _snack('كلمة المرور الجديدة مطابقة للحالية'); return; }
    setState(() => _loading = true);
    try {
      // نتأكد من كلمة المرور الحالية أولًا
      await user.reauthenticateWithCredential(EmailAuthProvider.credential(email: user.email!, password: _oldPass.text));
      await AuthService().updatePassword(_newPass.text);
      if (!mounted) return;
      _snack('تم تغيير كلمة المرور بنجاح');
      Navigator.pop(context);
    } on FirebaseAuthException catch (e) {
      final wrong = e.code == 'wrong-password' || e.code == 'invalid-credential' || e.code == 'invalid-login-credentials';
      _snack(wrong ? 'كلمة المرور الحالية غير صحيحة' : (e.code == 'too-many-requests' ? 'محاولات كثيرة، حاول بعد قليل' : (e.message ?? 'تعذر تغيير كلمة المرور')));
    } catch (e) {
      _snack('تعذر تغيير كلمة المرور: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _sendCode() async {
    setState(() => _loading = true);
    try {
      final r = await FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable('requestPasswordChangeCode').call<Map<String, dynamic>>({'channel': _channel});
      if (!mounted) return;
      setState(() {
        _codeSent = true;
        _sentTo = (r.data['sentTo'] ?? '').toString();
      });
      _snack('تم إرسال الكود');
    } on FirebaseFunctionsException catch (e) {
      _snack(e.message ?? 'تعذر إرسال الكود');
    } catch (e) {
      _snack('تعذر إرسال الكود: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _confirmWithCode() async {
    if (_code.text.trim().length != 6) { _snack('اكتب الكود المكوّن من 6 أرقام'); return; }
    final err = _validateNew();
    if (err != null) { _snack(err); return; }
    final email = FirebaseAuth.instance.currentUser?.email ?? '';
    setState(() => _loading = true);
    try {
      await FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable('confirmPasswordChangeWithCode').call<Map<String, dynamic>>({
        'code': _code.text.trim(),
        'newPassword': _newPass.text,
      });
      // تغيير الباسورد من الخادم قد يُنهي الجلسة الحالية: ندخل بالكلمة الجديدة لنبقى مسجلين
      if (email.isNotEmpty) {
        try { await FirebaseAuth.instance.signInWithEmailAndPassword(email: email, password: _newPass.text); } catch (_) {}
      }
      if (!mounted) return;
      _snack('تم تغيير كلمة المرور بنجاح');
      Navigator.pop(context);
    } on FirebaseFunctionsException catch (e) {
      _snack(e.message ?? 'تعذر تغيير كلمة المرور');
    } catch (e) {
      _snack('تعذر تغيير كلمة المرور: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _newFields() => Column(children: [
        TextField(
          controller: _newPass,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: 'كلمة المرور الجديدة',
            suffixIcon: IconButton(onPressed: () => setState(() => _obscure = !_obscure), icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off)),
          ),
        ),
        const SizedBox(height: 14),
        TextField(controller: _confirm, obscureText: _obscure, decoration: const InputDecoration(labelText: 'تأكيد كلمة المرور الجديدة')),
      ]);

  Widget _spinner() => const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('تغيير كلمة المرور')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: _forgot ? _forgotBody() : _normalBody(),
        ),
      );

  List<Widget> _normalBody() => [
        const Text('اكتب كلمة المرور الحالية ثم كلمة المرور الجديدة.', style: TextStyle(color: Colors.grey)),
        const SizedBox(height: 20),
        TextField(controller: _oldPass, obscureText: _obscure, decoration: const InputDecoration(labelText: 'كلمة المرور الحالية')),
        const SizedBox(height: 14),
        _newFields(),
        const SizedBox(height: 24),
        ElevatedButton(onPressed: _loading ? null : _saveWithOld, child: _loading ? _spinner() : const Text('تغيير كلمة المرور')),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _loading ? null : () => setState(() => _forgot = true),
          child: const Text('لا أتذكر كلمة المرور الحالية'),
        ),
      ];

  List<Widget> _forgotBody() => [
        const Text('هنبعتلك كود تأكيد لتأكيد أنك صاحب الحساب، ثم تكتب كلمة مرور جديدة.', style: TextStyle(color: Colors.grey)),
        const SizedBox(height: 16),
        const Text('أرسل الكود على:', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'email', icon: Icon(Icons.email_outlined), label: Text('البريد الإلكتروني')),
            ButtonSegment(value: 'phone', icon: Icon(Icons.phone_outlined), label: Text('رقم الهاتف')),
          ],
          selected: {_channel},
          onSelectionChanged: _loading ? null : (v) => setState(() { _channel = v.first; _codeSent = false; }),
        ),
        const SizedBox(height: 14),
        OutlinedButton(onPressed: _loading ? null : _sendCode, child: _loading && !_codeSent ? _spinner() : Text(_codeSent ? 'إعادة إرسال الكود' : 'إرسال الكود')),
        if (_codeSent) ...[
          const SizedBox(height: 10),
          Text('تم إرسال الكود إلى $_sentTo', style: const TextStyle(color: Colors.green, fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          TextField(controller: _code, keyboardType: TextInputType.number, maxLength: 6, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'كود التأكيد (6 أرقام)', counterText: '')),
          const SizedBox(height: 10),
          _newFields(),
          const SizedBox(height: 24),
          ElevatedButton(onPressed: _loading ? null : _confirmWithCode, child: _loading ? _spinner() : const Text('تأكيد وتغيير كلمة المرور')),
        ],
        const SizedBox(height: 8),
        TextButton(onPressed: _loading ? null : () => setState(() { _forgot = false; _codeSent = false; }), child: const Text('رجوع، أتذكر كلمة المرور الحالية')),
      ];
}
