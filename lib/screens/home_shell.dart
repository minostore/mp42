import 'package:flutter/material.dart';

import 'hub_tabs.dart';
import 'meetings_tab.dart';
import '../theme/app_theme.dart';
import '../hub/app_drawer.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  int _refreshNonce = 0;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  final List<Widget> _tabs = const [
    CoursesHubTab(),
    MeetingsTab(),
    IstifhamatHubTab(),
    MufhemsHubTab(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      drawer: const AppDrawer(),
      body: IndexedStack(
        index: _index,
        children: _tabs.map((tab) => KeyedSubtree(
          key: ValueKey('$_refreshNonce-${tab.runtimeType}'),
          child: tab,
        )).toList(),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) {
          // آخر زر "المزيد" يفتح القائمة الجانبية بدون تغيير التبويب
          if (index == _tabs.length) {
            _scaffoldKey.currentState?.openDrawer();
            return;
          }
          setState(() => _index = index);
        },
        backgroundColor: AppColors.white,
        indicatorColor: AppColors.emeraldLight,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.school_outlined), selectedIcon: Icon(Icons.school), label: 'الكورسات'),
          NavigationDestination(icon: Icon(Icons.video_camera_front_outlined), selectedIcon: Icon(Icons.video_camera_front), label: 'المحاضرات'),
          NavigationDestination(icon: Icon(Icons.help_outline), selectedIcon: Icon(Icons.help), label: 'الاستفهامات'),
          NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: 'المفهمين'),
          NavigationDestination(icon: Icon(Icons.menu), selectedIcon: Icon(Icons.menu_open), label: 'المزيد'),
        ],
      ),
    );
  }
}
