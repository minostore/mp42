import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/app_theme.dart';
import 'hub_common.dart';

/// القائمة الجانبية: نفس أقسام المنصة، وكل صفحة تُفتح داخل التطبيق.
class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid;

    void go(String route) {
      Navigator.pop(context); // إغلاق القائمة
      context.push(route);
    }

    Widget item(IconData icon, String label, String route) => ListTile(
          dense: true,
          leading: Icon(icon, color: AppColors.primaryDark),
          title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
          onTap: () => go(route),
        );

    Widget web(IconData icon, String label, String path) => ListTile(
          dense: true,
          leading: Icon(icon, color: AppColors.muted),
          title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          onTap: () {
            Navigator.pop(context);
            openWebPage(context, path);
          },
        );

    Widget heading(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
          child: Text(t, style: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w800, fontSize: 12)),
        );

    return Drawer(
      child: SafeArea(
        child: StreamBuilder<String>(
          stream: uid == null ? const Stream.empty() : watchWebRole(uid),
          builder: (context, roleSnap) {
            final isMufhem = roleSnap.data == 'mufhem';
            return ListView(padding: EdgeInsets.zero, children: [
              Container(
                padding: const EdgeInsets.all(18),
                color: AppColors.primaryLight,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('فهمت', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: AppColors.primaryDark)),
                  const SizedBox(height: 4),
                  Text(user?.displayName?.isNotEmpty == true ? user!.displayName! : (user?.email ?? ''), style: const TextStyle(color: AppColors.ink)),
                  const SizedBox(height: 10),
                  if (uid != null)
                    OutlinedButton.icon(
                      onPressed: () async {
                        try {
                          await setWebRole(uid, isMufhem ? 'mustafhem' : 'mufhem');
                        } catch (e) {
                          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر تبديل الوضع حاليًا')));
                        }
                      },
                      icon: const Icon(Icons.swap_horiz),
                      label: Text(isMufhem ? 'أنت في وضع المُفهم • تحويل لمُستفهم' : 'أنت في وضع المُستفهم • تحويل لمُفهم'),
                    ),
                ]),
              ),
              // أعلى «المزيد»: حسابي ثم المحفظة مباشرة تحته
              item(Icons.person_outline, 'حسابي', '/account'),
              web(Icons.account_balance_wallet_outlined, 'المحفظة', '/wallet'),
              item(Icons.groups_outlined, 'المجموعات', '/groups'),
              item(Icons.favorite_border, 'المفضلة', '/favorites'),
              item(Icons.notifications_none, 'الإشعارات', '/notifications'),
              if (isMufhem) item(Icons.bolt, 'عروضي', '/offers/mine'),
              heading('المساعدة والمعلومات'),
              web(Icons.menu_book_outlined, 'الدليل الإرشادي', '/guide'),
              web(Icons.help_outline, 'الأسئلة الشائعة', '/support'),
              web(Icons.support_agent, 'الدعم الفني', '/contact-us'),
              web(Icons.info_outline, 'عن فهمت', '/about'),
              web(Icons.verified_user_outlined, 'ضمان الحقوق', '/guarantees'),
              web(Icons.gavel, 'شروط الاستخدام', '/terms'),
              web(Icons.privacy_tip_outlined, 'سياسة الخصوصية', '/privacy-policy'),
              web(Icons.currency_exchange, 'سياسة الاسترجاع', '/refund-policy'),
              web(Icons.work_outline, 'الوظائف', '/jobs'),
              const SizedBox(height: 20),
            ]);
          },
        ),
      ),
    );
  }
}
