import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

const String kAvatarMale = 'assets/avatars/avatar_male.jpg';
const String kAvatarFemale = 'assets/avatars/avatar_female.jpg';

String defaultAvatarAsset(String? gender) => gender == 'female' ? kAvatarFemale : kAvatarMale;

/// الصورة المعتمدة لحساب: صورة المستخدم بعد موافقة الإدارة، وإلا الصورة الافتراضية حسب الجنس.
/// (الصورة المرفوعة الجديدة تُحفظ في pendingPhotoUrl ولا تظهر للناس قبل المراجعة.)
String approvedPhotoOf(Map<String, dynamic>? m) {
  if (m == null) return '';
  final url = (m['profilePictureUrl'] ?? m['photoUrl'] ?? m['imageUrl'] ?? '').toString().trim();
  return url;
}

class UserAvatar extends StatelessWidget {
  final String? photoUrl;
  final String? gender;
  final double radius;
  const UserAvatar({super.key, this.photoUrl, this.gender, this.radius = 24});

  /// يقرأ الصورة والجنس من users/{uid} مباشرة.
  static Widget fromUid(String uid, {double radius = 24}) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
      builder: (_, s) {
        final m = s.data?.data();
        return UserAvatar(photoUrl: approvedPhotoOf(m), gender: (m?['gender'] ?? '').toString(), radius: radius);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final fallback = AssetImage(defaultAvatarAsset(gender));
    final url = (photoUrl ?? '').trim();
    final size = radius * 2;
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: url.isEmpty
            ? Image(image: fallback, fit: BoxFit.cover)
            : CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                placeholder: (_, __) => Image(image: fallback, fit: BoxFit.cover),
                errorWidget: (_, __, ___) => Image(image: fallback, fit: BoxFit.cover),
              ),
      ),
    );
  }
}

/// بطاقة حالة الصورة المرفوعة (قيد المراجعة / مرفوضة مع السبب).
class PhotoStatusBanner extends StatelessWidget {
  final Map<String, dynamic>? user;
  const PhotoStatusBanner({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    final pending = user?['profilePicturePending'] == true;
    final reason = (user?['profilePictureRejectReason'] ?? '').toString();
    final rejected = !pending && reason.isNotEmpty;
    if (!pending && !rejected) return const SizedBox.shrink();
    final c = rejected ? const Color(0xFFDC2626) : AppColors.accent;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: c.withOpacity(.1), borderRadius: BorderRadius.circular(12), border: Border.all(color: c.withOpacity(.4))),
      child: Text(
        rejected
            ? 'تم رفض صورتك${reason.isEmpty ? '' : ': $reason'}\nستبقى الصورة الافتراضية حتى ترفع صورة مطابقة للشروط.'
            : 'صورتك قيد المراجعة من الإدارة، وستظهر للآخرين بعد الموافقة عليها.',
        style: TextStyle(color: c, fontWeight: FontWeight.w700, height: 1.6),
      ),
    );
  }
}
