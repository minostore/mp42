import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../models/user_profile.dart';
import '../services/firestore_service.dart';
import '../theme/app_theme.dart';
import '../widgets/user_avatar.dart';

class EditProfileScreen extends StatefulWidget {
  final UserProfile profile;
  const EditProfileScreen({super.key, required this.profile});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final TextEditingController _name;
  XFile? _picked;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.profile.name);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final image = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 82, maxWidth: 900);
    if (image != null && mounted) setState(() => _picked = image);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('الاسم مطلوب')));
      return;
    }
    setState(() => _saving = true);
    try {
      final user = FirebaseAuth.instance.currentUser!;
      await FirestoreService().updateUserProfile(uid: user.uid, name: name);
      if (_picked != null) {
        // الصورة لا تُنشر مباشرة: تُحفظ كطلب مراجعة، وتبقى الصورة الحالية/الافتراضية حتى تقبلها الإدارة
        final ref = FirebaseStorage.instance.ref('pending/profiles/${user.uid}_${DateTime.now().millisecondsSinceEpoch}.jpg');
        await ref.putFile(File(_picked!.path), SettableMetadata(contentType: 'image/jpeg'));
        final pendingUrl = await ref.getDownloadURL();
        await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'pendingProfilePictureUrl': pendingUrl,
          'profilePicturePending': true,
          'profilePictureRejectReason': FieldValue.delete(),
        }, SetOptions(merge: true));
      }
      await user.updateDisplayName(name);
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_picked != null ? 'تم حفظ بياناتك. صورتك الجديدة قيد المراجعة وستظهر بعد الموافقة عليها.' : 'تم تحديث الملف الشخصي')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر حفظ الملف: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentPhoto = widget.profile.photoUrl;
    return Scaffold(
      appBar: AppBar(title: const Text('تعديل الملف الشخصي')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(
            child: GestureDetector(
              onTap: _pickImage,
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  _picked != null
                      ? CircleAvatar(radius: 52, backgroundImage: FileImage(File(_picked!.path)))
                      : UserAvatar(photoUrl: currentPhoto, gender: widget.profile.gender, radius: 52),
                  const CircleAvatar(radius: 17, child: Icon(Icons.camera_alt, size: 18)),
                ],
              ),
            ),
          ),
          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance.collection('users').doc(FirebaseAuth.instance.currentUser!.uid).snapshots(),
            builder: (_, s) => PhotoStatusBanner(user: s.data?.data()),
          ),
          const SizedBox(height: 26),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'الاسم')),
          const SizedBox(height: 12),
          TextFormField(
            initialValue: widget.profile.email,
            enabled: false,
            decoration: const InputDecoration(labelText: 'البريد الإلكتروني'),
          ),
          const SizedBox(height: 22),
          ElevatedButton(
            onPressed: _saving ? null : _save,
            child: _saving ? const CircularProgressIndicator(strokeWidth: 2) : const Text('حفظ التغييرات'),
          ),
        ],
      ),
    );
  }
}
