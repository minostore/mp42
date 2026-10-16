import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/firestore_service.dart';
import '../models/course.dart';
import '../widgets/course_card.dart';
import '../data/categories_tree.dart';
import '../theme/app_theme.dart';
import '../widgets/category_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class CoursesTab extends StatefulWidget {
  final bool embedded;
  const CoursesTab({super.key, this.embedded = false});

  @override
  State<CoursesTab> createState() => _CoursesTabState();
}

class _CoursesTabState extends State<CoursesTab> {
  CategoryChoice _cat = const CategoryChoice();
  final _firestore = FirestoreService();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          if (!widget.embedded)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
              child: Row(children: [
                Text('الكورسات', style: Theme.of(context).textTheme.headlineSmall),
                const Spacer(),
                const _AddCourseButton(),
              ]),
            ),
          const SizedBox(height: 6),
          CategoryFilterButton(value: _cat, onChanged: (c) => setState(() => _cat = c)),
          Expanded(
            child: StreamBuilder<List<Course>>(
              stream: _firestore.watchCourses(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'جاري إعادة الاتصال وتحميل الكورسات من منصة فهمت...\nسيتم تحديث القائمة تلقائيًا عند عودة الاتصال.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.muted),
                      ),
                    ),
                  );
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final courses = snap.data!.where((c) => _cat.matches(c.raw)).toList();
                if (courses.isEmpty) {
                  return const Center(
                    child: Text(
                      'لا يوجد كورسات في هذا التصنيف',
                      style: TextStyle(color: AppColors.muted),
                    ),
                  );
                }
                return GridView.builder(
                  padding: const EdgeInsets.all(18),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2, mainAxisSpacing: 14, crossAxisSpacing: 14, childAspectRatio: .72,
                  ),
                  itemCount: courses.length,
                  itemBuilder: (context, i) => CourseCard(course: courses[i], onTap: () => context.push('/course/${courses[i].id}')),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}


/// زر «إضافة كورس جديد» — يظهر للمُفهّم والأدمن فقط.
class _AddCourseButton extends StatelessWidget {
  const _AddCourseButton();
  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const SizedBox.shrink();
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
      builder: (context, s) {
        final m = s.data?.data() ?? const <String, dynamic>{};
        final ok = m['role'] == 'mufhem' || m['mode'] == 'mofahhem' || m['role'] == 'admin' || m['isAdmin'] == true;
        if (!ok) return const SizedBox.shrink();
        return ElevatedButton.icon(
          onPressed: () => context.push('/courses/new'),
          icon: const Icon(Icons.add),
          label: const Text('إضافة كورس جديد'),
          style: ElevatedButton.styleFrom(minimumSize: const Size(0, 40)),
        );
      },
    );
  }
}
