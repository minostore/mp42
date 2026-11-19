import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// ينسخ نص الخطأ إلى الحافظة مع تأكيد.
Future<void> copyErrorText(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم نسخ الخطأ')));
  }
}

/// نافذة تعرض الخطأ كاملًا (قابل للتحديد) مع زر «نسخ الخطأ».
Future<void> showErrorWithCopy(BuildContext context, {required String title, required String text}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: SelectableText(text, textDirection: TextDirection.ltr, style: const TextStyle(height: 1.5, fontSize: 13))),
      actions: [
        TextButton.icon(onPressed: () => copyErrorText(ctx, text), icon: const Icon(Icons.copy, size: 18), label: const Text('نسخ الخطأ')),
        FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق')),
      ],
    ),
  );
}
