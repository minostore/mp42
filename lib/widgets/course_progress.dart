import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/firestore_service.dart';
import '../theme/app_theme.dart';

/// شريط «التقدم في الكورس» للمستفهم الذي اشترى الكورس: نسبة ما أنجزه من دروس الكورس.
/// النسبة = متوسط تقدم الدروس (الدرس المكتمل = 100%) ÷ عدد دروس الكورس.
class CourseProgressBar extends StatelessWidget {
  final String courseId;
  const CourseProgressBar({super.key, required this.courseId});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const SizedBox.shrink();
    return FutureBuilder(
      future: FirestoreService().getLessons(courseId),
      builder: (context, lessonsSnap) {
        final total = lessonsSnap.data?.length ?? 0;
        if (total == 0) return const SizedBox.shrink();
        final ids = lessonsSnap.data!.map((l) => l.id).toSet();
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance.collection('progress').where('uid', isEqualTo: uid).where('courseId', isEqualTo: courseId).snapshots(),
          builder: (context, snap) {
            var sum = 0.0;
            var done = 0;
            for (final d in snap.data?.docs ?? const <QueryDocumentSnapshot<Map<String, dynamic>>>[]) {
              final m = d.data();
              if (!ids.contains((m['lessonId'] ?? '').toString())) continue; // درس محذوف
              final p = (m['percent'] is num) ? (m['percent'] as num).toDouble() : 0.0;
              final completed = m['completed'] == true || p >= 95;
              if (completed) done++;
              sum += completed ? 100 : p.clamp(0, 100);
            }
            final pct = (sum / (100.0 * total)).clamp(0.0, 1.0);
            return Container(
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(14)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.trending_up, color: AppColors.accent, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('التقدم في الكورس', style: TextStyle(fontWeight: FontWeight.w800))),
                  Text('${(pct * 100).round()}%', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                ]),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(value: pct, minHeight: 10, backgroundColor: Colors.white, color: AppColors.accent),
                ),
                const SizedBox(height: 6),
                Text('أكملت $done من $total دروس', style: const TextStyle(fontSize: 12, color: AppColors.muted)),
              ]),
            );
          },
        );
      },
    );
  }
}
