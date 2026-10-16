import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../data/countries.dart';
import '../theme/app_theme.dart';

/// إنشاء حساب جديد — نفس حقول وقواعد التسجيل في منصة الويب.
class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});
  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  Country _country = kCountries.firstWhere((c) => c.iso == 'EG', orElse: () => kCountries.first);
  String _role = 'mustafhem';
  String _gender = '';
  DateTime? _birth;
  bool _terms = false;
  bool _hide = true;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_first, _last, _email, _phone, _pass, _pass2]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _validate() {
    if (_first.text.trim().length < 2 || _last.text.trim().length < 2) return 'اكتب الاسم الأول والأخير';
    final email = _email.text.trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) return 'البريد الإلكتروني غير صحيح';
    final num = _phone.text.trim().replaceAll(RegExp(r'^0+'), '');
    final pe = validatePhone(_country, num);
    if (pe != null) return pe;
    if (_pass.text.length < 8) return 'كلمة المرور يجب ألا تقل عن 8 أحرف';
    if (_pass.text != _pass2.text) return 'كلمتا المرور غير متطابقتين';
    if (_gender.isEmpty) return 'اختر الجنس';
    if (_birth == null) return 'اختر تاريخ الميلاد';
    final now = DateTime.now();
    var age = now.year - _birth!.year;
    if (now.month < _birth!.month || (now.month == _birth!.month && now.day < _birth!.day)) age--;
    if (age < 16) return 'يجب ألا يقل عمرك عن 16 سنة';
    if (!_terms) return 'يجب الموافقة على الشروط والأحكام';
    return null;
  }

  Future<void> _submit() async {
    final err = _validate();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final email = _email.text.trim().toLowerCase();
      final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(email: email, password: _pass.text);
      final user = cred.user!;
      final fullName = '${_first.text.trim()} ${_last.text.trim()}';
      final num = _phone.text.trim().replaceAll(RegExp(r'^0+'), '');
      await user.updateDisplayName(fullName);
      // ملاحظة: كلمة المرور لا تُخزَّن أبدًا في Firestore (تُدار بواسطة Firebase Auth فقط)
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'id': user.uid,
        'firstName': _first.text.trim(),
        'lastName': _last.text.trim(),
        'fullName': fullName,
        'name': fullName,
        'email': email,
        'phoneNumber': '+${_country.code}$num',
        'phone': '+${_country.code}$num',
        'role': _role,
        'mode': _role == 'mufhem' ? 'mofahhem' : 'mostafhem',
        'gender': _gender,
        'birthDate': _birth!.toIso8601String(),
        'isProfileApproved': false,
        'status': 'active',
        'needsProfileCompletion': true,
        'createdAt': DateTime.now().toIso8601String(),
        'joinedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      if (mounted) context.go('/home');
    } on FirebaseAuthException catch (e) {
      setState(() => _error = switch (e.code) {
            'email-already-in-use' => 'هذا البريد مسجّل بالفعل، جرّب تسجيل الدخول',
            'weak-password' => 'كلمة المرور ضعيفة',
            'invalid-email' => 'البريد الإلكتروني غير صحيح',
            _ => 'تعذر إنشاء الحساب: ${e.message ?? e.code}',
          });
    } catch (e) {
      setState(() => _error = 'تعذر إنشاء الحساب: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _choice(String label, String value, String group, IconData icon, ValueChanged<String> onTap) {
    final sel = group == value;
    return Expanded(
      child: InkWell(
        onTap: () => onTap(value),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: sel ? AppColors.primaryLight : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: sel ? AppColors.primary : AppColors.line, width: sel ? 2 : 1),
          ),
          child: Column(children: [
            Icon(icon, color: sel ? AppColors.primaryDark : AppColors.muted),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontWeight: FontWeight.w800, color: sel ? AppColors.primaryDark : AppColors.muted)),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('إنشاء حساب جديد')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Center(child: Image.asset('assets/images/logo.png', width: 64, height: 64)),
          const SizedBox(height: 16),
          const Text('أنا أريد أن:', style: TextStyle(fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          Row(children: [
            _choice('أستفهم (طالب علم)', 'mustafhem', _role, Icons.help_outline, (v) => setState(() => _role = v)),
            const SizedBox(width: 10),
            _choice('أُفهِّم (مُفهِّم)', 'mufhem', _role, Icons.school_outlined, (v) => setState(() => _role = v)),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: TextField(controller: _first, decoration: const InputDecoration(labelText: 'الاسم الأول'))),
            const SizedBox(width: 10),
            Expanded(child: TextField(controller: _last, decoration: const InputDecoration(labelText: 'الاسم الأخير'))),
          ]),
          const SizedBox(height: 12),
          TextField(controller: _email, keyboardType: TextInputType.emailAddress, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'البريد الإلكتروني')),
          const SizedBox(height: 12),
          Row(textDirection: TextDirection.ltr, children: [
            Expanded(
              flex: 5,
              child: TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                textDirection: TextDirection.ltr,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'رقم الهاتف'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 5,
              child: DropdownButtonFormField<Country>(
                value: _country,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'الدولة'),
                items: [for (final c in kCountries) DropdownMenuItem(value: c, child: Text('${c.flag} +${c.code}', overflow: TextOverflow.ellipsis))],
                onChanged: (c) => setState(() => _country = c ?? _country),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          const Text('الجنس', style: TextStyle(fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          Row(children: [
            _choice('ذكر', 'male', _gender, Icons.male, (v) => setState(() => _gender = v)),
            const SizedBox(width: 10),
            _choice('أنثى', 'female', _gender, Icons.female, (v) => setState(() => _gender = v)),
          ]),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () async {
              final now = DateTime.now();
              final d = await showDatePicker(
                context: context,
                initialDate: _birth ?? DateTime(now.year - 18),
                firstDate: DateTime(1940),
                lastDate: DateTime(now.year - 16, now.month, now.day),
              );
              if (d != null) setState(() => _birth = d);
            },
            icon: const Icon(Icons.cake_outlined),
            label: Text(_birth == null ? 'تاريخ الميلاد' : '${_birth!.year}/${_birth!.month}/${_birth!.day}'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pass,
            obscureText: _hide,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(
              labelText: 'كلمة المرور (8 أحرف على الأقل)',
              suffixIcon: IconButton(onPressed: () => setState(() => _hide = !_hide), icon: Icon(_hide ? Icons.visibility_off : Icons.visibility)),
            ),
          ),
          const SizedBox(height: 12),
          TextField(controller: _pass2, obscureText: _hide, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'تأكيد كلمة المرور')),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _terms,
            onChanged: (v) => setState(() => _terms = v == true),
            title: const Text('أوافق على الشروط والأحكام وسياسة الخصوصية'),
          ),
          if (_error != null)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(12)),
              child: Text(_error!, style: const TextStyle(color: Color(0xFFB91C1C), fontWeight: FontWeight.w700)),
            ),
          ElevatedButton(
            onPressed: _loading ? null : _submit,
            child: _loading ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('إنشاء الحساب'),
          ),
          TextButton(onPressed: () => context.go('/login'), child: const Text('لدي حساب بالفعل؟ تسجيل الدخول')),
        ]),
      ),
    );
  }
}
