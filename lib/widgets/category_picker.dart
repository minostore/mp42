import 'package:flutter/material.dart';

import '../data/categories_tree.dart';
import '../theme/app_theme.dart';

/// اختيار القسم على 3 مستويات (يُستخدم عند كتابة استفهام / إنشاء كورس / مجموعة / عمل).
class CategoryPicker extends StatefulWidget {
  final CategoryChoice value;
  final ValueChanged<CategoryChoice> onChanged;
  final bool required;
  const CategoryPicker({super.key, required this.value, required this.onChanged, this.required = true});

  @override
  State<CategoryPicker> createState() => _CategoryPickerState();
}

class _CategoryPickerState extends State<CategoryPicker> {
  late final TextEditingController _custom = TextEditingController(text: widget.value.custom);

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  CategoryChoice get _v => widget.value;

  void _emit({String? main, String? sub, String? opt, String? custom}) {
    final m = main ?? _v.main;
    // تغيير مستوى أعلى يصفّر ما تحته
    final s = main != null ? '' : (sub ?? _v.sub);
    final o = (main != null || sub != null) ? '' : (opt ?? _v.opt);
    var c = custom ?? _v.custom;
    if (main != null || sub != null || opt != null) {
      c = '';
      _custom.clear();
    }
    widget.onChanged(CategoryChoice(main: m, sub: s, opt: o, custom: c));
  }

  Widget _dd(String label, String value, List<CatNode> items, void Function(String) onPick) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        value: items.any((c) => c.name == value) ? value : null,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: [for (final c in items) DropdownMenuItem(value: c.name, child: Text(c.name))],
        onChanged: (v) => onPick(v ?? ''),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final subs = _v.main.isEmpty ? const <CatNode>[] : subsOf(_v.main);
    final opts = _v.sub.isEmpty ? const <CatNode>[] : optsOf(_v.main, _v.sub);
    final needCustom = (_v.main.isNotEmpty && isOtherNode(_v.main)) ||
        (_v.sub.isNotEmpty && isOtherNode(_v.main, _v.sub)) ||
        (_v.opt.isNotEmpty && isOtherNode(_v.main, _v.sub, _v.opt));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _dd('القسم', _v.main, kCategoryTree, (v) => _emit(main: v)),
      if (subs.isNotEmpty) _dd('القسم الفرعي', _v.sub, subs, (v) => _emit(sub: v)),
      if (opts.isNotEmpty) _dd('التخصص', _v.opt, opts, (v) => _emit(opt: v)),
      if (needCustom)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: _custom,
            maxLength: 60,
            decoration: const InputDecoration(labelText: 'اكتب القسم', hintText: 'اكتب اسم القسم المناسب'),
            onChanged: (t) => _emit(custom: t.trim()),
          ),
        ),
    ]);
  }
}

/// زر فلترة بالأقسام: يفتح نافذة اختيار ويرجّع [CategoryChoice] (فارغ = الكل).
class CategoryFilterButton extends StatelessWidget {
  final CategoryChoice value;
  final ValueChanged<CategoryChoice> onChanged;
  const CategoryFilterButton({super.key, required this.value, required this.onChanged});

  Future<void> _open(BuildContext context) async {
    var temp = value;
    final res = await showModalBottomSheet<CategoryChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: StatefulBuilder(
          builder: (ctx, setS) => Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('تصفية حسب القسم', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                const SizedBox(height: 14),
                CategoryPicker(value: temp, required: false, onChanged: (c) => setS(() => temp = c)),
                Row(children: [
                  Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(ctx, const CategoryChoice()), child: const Text('إظهار الكل'))),
                  const SizedBox(width: 10),
                  Expanded(child: ElevatedButton(onPressed: () => Navigator.pop(ctx, temp), child: const Text('تطبيق'))),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
    if (res != null) onChanged(res);
  }

  @override
  Widget build(BuildContext context) {
    final active = !value.isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
      child: Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _open(context),
            icon: Icon(Icons.filter_list, color: active ? AppColors.accent : AppColors.primaryDark),
            label: Text(active ? value.label : 'كل الأقسام', maxLines: 1, overflow: TextOverflow.ellipsis),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44), alignment: AlignmentDirectional.centerStart),
          ),
        ),
        if (active) IconButton(onPressed: () => onChanged(const CategoryChoice()), icon: const Icon(Icons.close)),
      ]),
    );
  }
}
