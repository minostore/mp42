import 'package:flutter/material.dart';

import '../services/api_functions.dart';
import '../theme/app_theme.dart';

const String kAskNowText = 'يمكنك الان الاستفهام عن أي نقطة تحتاج فهمها من مفهم متخصص، انشر استفهامك الآن وتلقى عروضا من مفهمين متخصصين واختار الأنسب لك بعد مشاهدة معارض أعمالهم';

/// رسالة «استفهم الآن» بعد انتهاء فيديو/جلسة. ترجع 'ask' أو 'second' (الخيار الثاني) أو null عند الإغلاق.
/// - للفيديوهات: الخيار الثاني «الدرس التالي» (غير قابل للضغط لو انتهى الكورس).
/// - للميتنج: الخيار الثاني «الخروج من الجلسة».
Future<String?> showAskNowPrompt(
  BuildContext context, {
  required String secondLabel,
  bool secondEnabled = true,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        icon: const Icon(Icons.lightbulb_outline, size: 36, color: AppColors.accent),
        content: const Text(kAskNowText, textAlign: TextAlign.center, style: TextStyle(height: 1.6, fontWeight: FontWeight.w700)),
        actionsAlignment: MainAxisAlignment.center,
        actionsOverflowButtonSpacing: 8,
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx, 'ask'), child: const Text('استفهم الآن')),
          OutlinedButton(onPressed: secondEnabled ? () => Navigator.pop(ctx, 'second') : null, child: Text(secondLabel)),
        ],
      ),
    ),
  );
}

/// تقييم الجلسة بعد انتهائها: جودة الجلسة + تقييم المفهم (1-5). يرسل للسيرفر ويرجع عند الإرسال أو التخطي.
Future<void> showSessionRatingDialog(
  BuildContext context, {
  String? requestId,
  String? groupId,
  String? sessionId,
}) async {
  var quality = 0;
  var mufhem = 0;
  final comment = TextEditingController();
  Widget stars(int value, void Function(int) set, StateSetter setLocal) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 1; i <= 5; i++)
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () => setLocal(() => set(i)),
              icon: Icon(i <= value ? Icons.star : Icons.star_border, color: AppColors.accent, size: 32),
            ),
        ],
      );
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: const Text('قيّم الجلسة', textAlign: TextAlign.center),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('جودة الجلسة', style: TextStyle(fontWeight: FontWeight.w800)),
            stars(quality, (v) => quality = v, setLocal),
            const SizedBox(height: 6),
            const Text('تقييم المفهم', style: TextStyle(fontWeight: FontWeight.w800)),
            stars(mufhem, (v) => mufhem = v, setLocal),
            TextField(controller: comment, maxLines: 2, maxLength: 300, decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('تخطي')),
          FilledButton(
            onPressed: (quality == 0 || mufhem == 0)
                ? null
                : () async {
                    try {
                      await FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable('submitSessionRating').call<Map<String, dynamic>>({
                        if (requestId != null) 'requestId': requestId,
                        if (groupId != null) 'groupId': groupId,
                        if (sessionId != null) 'sessionId': sessionId,
                        'quality': quality,
                        'mufhemRating': mufhem,
                        'comment': comment.text.trim(),
                      });
                    } catch (_) {}
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
            child: const Text('إرسال'),
          ),
        ],
      ),
    ),
  );
  comment.dispose();
}


/// تقديم شكوى على جلسة استفهام: تُبقي تسجيل الجلسة عند الإدارة (حتى 14 يومًا كحد أقصى أو حتى الرد).
Future<void> showSessionComplaintDialog(BuildContext context, String requestId) async {
  final text = TextEditingController();
  final send = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('تقديم شكوى على الجلسة'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('سيراجع فريق الإدارة تسجيل الجلسة. اكتب ما حدث بإيجاز.', style: TextStyle(height: 1.5)),
        const SizedBox(height: 10),
        TextField(controller: text, maxLines: 4, maxLength: 800, decoration: const InputDecoration(labelText: 'تفاصيل الشكوى')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('إرسال الشكوى')),
      ],
    ),
  );
  final body = text.text.trim();
  text.dispose();
  if (send != true || !context.mounted) return;
  if (body.length < 5) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('اكتب تفاصيل الشكوى')));
    return;
  }
  try {
    await FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable('fileSessionComplaint').call<Map<String, dynamic>>({'requestId': requestId, 'text': body});
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم إرسال الشكوى للإدارة')));
  } on FirebaseFunctionsException catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message ?? 'تعذر إرسال الشكوى')));
  } catch (_) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر إرسال الشكوى')));
  }
}
