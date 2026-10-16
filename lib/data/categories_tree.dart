/// شجرة الأقسام الموحّدة (نفس أقسام منصة الويب).
/// المستوى 1 = القسم الرئيسي (category)، 2 = القسم الفرعي (categorySub)، 3 = التخصص (categoryOpt).
/// أي عنصر `other: true` يفتح مربع كتابة حر.
class CatNode {
  final String name;
  final List<CatNode> children;
  final bool other;
  const CatNode(this.name, {this.children = const [], this.other = false});
  bool get isLeaf => children.isEmpty;
}

const String kOtherLabel = 'غير ذلك';

const List<CatNode> kCategoryTree = [
  CatNode('التعليم الأكاديمي', children: [
    CatNode('التعليم ما قبل الجامعي', children: [
      CatNode('الابتدائية'),
      CatNode('الإعدادية'),
      CatNode('الثانوية (علمي)'),
      CatNode('الثانوية (أدبي)'),
    ]),
    CatNode('التعليم الجامعي', children: [
      CatNode('كليات طبية (أكاديمي)'),
      CatNode('كليات هندسية'),
      CatNode('كليات نظرية'),
    ]),
    CatNode('إتقان اللغات', children: [
      CatNode('لغة عربية'),
      CatNode('لغة إنجليزية'),
      CatNode('لغات أخرى', other: true),
    ]),
  ]),
  CatNode('التقنية والبرمجة', children: [
    CatNode('البرمجيات', children: [
      CatNode('برمجة الويب'),
      CatNode('تطبيقات الجوال'),
    ]),
    CatNode('الذكاء الاصطناعي'),
    CatNode('حلول تقنية'),
  ]),
  CatNode('التصميم والإبداع', children: [
    CatNode('الجرافيك'),
    CatNode('المونتاج'),
    CatNode(kOtherLabel, other: true),
  ]),
  CatNode('مهارات وحرف', children: [
    CatNode('صيانة'),
    CatNode('أعمال يدوية'),
    CatNode('الطبخ'),
    CatNode(kOtherLabel, other: true),
  ]),
  CatNode('العمل والذات', children: [
    CatNode('العمل الحر', children: [
      CatNode('التسويق'),
      CatNode('تطوير'),
    ]),
    CatNode('مهارات شخصية'),
    CatNode(kOtherLabel, other: true),
  ]),
  CatNode(kOtherLabel, other: true),
];

/// اختيار المستخدم: المستويات الثلاثة + النص الحر (لو اختار «غير ذلك»).
class CategoryChoice {
  final String main;
  final String sub;
  final String opt;
  final String custom;
  const CategoryChoice({this.main = '', this.sub = '', this.opt = '', this.custom = ''});

  bool get isEmpty => main.isEmpty;

  /// أدق اسم للقسم (للعرض والفلترة).
  String get leaf {
    if (custom.isNotEmpty) return custom;
    if (opt.isNotEmpty) return opt;
    if (sub.isNotEmpty) return sub;
    return main;
  }

  /// يُحفظ في Firestore بنفس حقول الويب + `categoryCustom`.
  Map<String, dynamic> toFields() => {
        'category': main,
        'categorySub': sub,
        'categoryOpt': opt,
        if (custom.isNotEmpty) 'categoryCustom': custom,
      };

  String get label => [main, sub, opt, custom].where((e) => e.isNotEmpty).join(' › ');

  static CategoryChoice fromMap(Map<String, dynamic> m) => CategoryChoice(
        main: (m['category'] ?? '').toString(),
        sub: (m['categorySub'] ?? '').toString(),
        opt: (m['categoryOpt'] ?? '').toString(),
        custom: (m['categoryCustom'] ?? '').toString(),
      );

  /// هل هذا العنصر (استفهام/كورس/مجموعة/عمل) يطابق الفلتر؟ الفلتر الأعم يطابق كل ما تحته.
  bool matches(Map<String, dynamic> item) {
    if (isEmpty) return true;
    final it = CategoryChoice.fromMap(item);
    if (it.main != main) return false;
    if (sub.isNotEmpty && it.sub != sub) return false;
    if (opt.isNotEmpty && it.opt != opt) return false;
    return true;
  }
}

CatNode? _find(List<CatNode> list, String name) {
  for (final n in list) {
    if (n.name == name) return n;
  }
  return null;
}

List<CatNode> subsOf(String main) => _find(kCategoryTree, main)?.children ?? const [];
List<CatNode> optsOf(String main, String sub) => _find(subsOf(main), sub)?.children ?? const [];
bool isOtherNode(String main, [String sub = '', String opt = '']) {
  if (main.isEmpty) return false;
  final m = _find(kCategoryTree, main);
  if (sub.isEmpty) return m?.other ?? false;
  final s = _find(m?.children ?? const [], sub);
  if (opt.isEmpty) return s?.other ?? false;
  return _find(s?.children ?? const [], opt)?.other ?? false;
}
