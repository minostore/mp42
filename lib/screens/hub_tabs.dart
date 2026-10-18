import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../hub/mufhems_screens.dart';
import '../hub/requests_screens.dart';
import '../models/course.dart';
import '../services/firestore_service.dart';
import '../widgets/course_card.dart';
import 'courses_tab.dart';
import 'my_courses_tab.dart';

/// «الكورسات»: كورسات أنشأتها / كورسات اشتريتها / جميع الكورسات.
class CoursesHubTab extends StatelessWidget {
  const CoursesHubTab({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const Scaffold(body: Center(child: Text('يجب تسجيل الدخول أولاً')));
    final service = FirestoreService();
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('الكورسات'),
          centerTitle: true,
          bottom: const TabBar(tabs: [Tab(text: 'كورسات أنشأتها'), Tab(text: 'كورسات اشتريتها'), Tab(text: 'جميع الكورسات')]),
        ),
        body: TabBarView(children: [
          _CreatedCourses(uid: user.uid),
          PurchasedCoursesList(userId: user.uid, service: service),
          const CoursesTab(embedded: true),
        ]),
      ),
    );
  }
}

class _CreatedCourses extends StatelessWidget {
  final String uid;
  const _CreatedCourses({required this.uid});

  @override
  Widget build(BuildContext context) {
    // الحقل يختلف بين السجلات القديمة والجديدة (instructorId / ownerUid / mufhemId)
    final query = FirebaseFirestore.instance.collection('courses').where(Filter.or(
          Filter('instructorId', isEqualTo: uid),
          Filter('ownerUid', isEqualTo: uid),
          Filter('mufhemId', isEqualTo: uid),
        ));
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: query.snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return const Center(child: Text('تعذر تحميل كورساتك'));
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final courses = snap.data!.docs.map((d) => Course.fromMap(d.id, d.data())).toList();
        return Column(children: [
          const Padding(padding: EdgeInsets.fromLTRB(18, 12, 18, 0), child: Align(alignment: Alignment.centerRight, child: AddCourseButton())),
          Expanded(
            child: courses.isEmpty
                ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('لم تنشئ أي كورس بعد.', textAlign: TextAlign.center)))
                : GridView.builder(
                    padding: const EdgeInsets.all(18),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 14, crossAxisSpacing: 14, childAspectRatio: .72),
                    itemCount: courses.length,
                    itemBuilder: (context, i) => CourseCard(course: courses[i], onTap: () => context.push('/course/${courses[i].id}')),
                  ),
          ),
        ]);
      },
    );
  }
}

/// «الاستفهامات»: استفهامات طرحتها / جميع الاستفهامات (مع زر «طرح استفهام جديد»).
class IstifhamatHubTab extends StatelessWidget {
  const IstifhamatHubTab({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('الاستفهامات'),
          centerTitle: true,
          bottom: const TabBar(tabs: [Tab(text: 'استفهامات طرحتها'), Tab(text: 'جميع الاستفهامات')]),
        ),
        body: const TabBarView(children: [
          MyRequestsScreen(embedded: true),
          BrowseRequestsScreen(embedded: true),
        ]),
      ),
    );
  }
}

/// «المفهمين»: المفهمين / أعمال المفهمين.
class MufhemsHubTab extends StatelessWidget {
  const MufhemsHubTab({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('المفهمين'),
          centerTitle: true,
          bottom: const TabBar(tabs: [Tab(text: 'المفهمين'), Tab(text: 'أعمال المفهمين')]),
        ),
        body: const TabBarView(children: [
          MufhemsScreen(embedded: true),
          PortfolioScreen(embedded: true),
        ]),
      ),
    );
  }
}
