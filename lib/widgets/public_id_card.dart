import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_functions.dart';
import '../theme/app_theme.dart';

/// بطاقة «رقمك التعريفي» (يُولَّد من السيرفر لو لم يكن موجودًا) مع زر نسخ.
class PublicIdCard extends StatefulWidget {
  final EdgeInsetsGeometry margin;
  const PublicIdCard({super.key, this.margin = const EdgeInsets.fromLTRB(14, 10, 14, 0)});

  static String? _cached;

  @override
  State<PublicIdCard> createState() => _PublicIdCardState();
}

class _PublicIdCardState extends State<PublicIdCard> {
  String? _id = PublicIdCard._cached;

  @override
  void initState() {
    super.initState();
    if (_id == null) _load();
  }

  Future<void> _load() async {
    try {
      final r = await FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable('ensurePublicId').call<Map<String, dynamic>>();
      final v = (r.data['publicId'] ?? '').toString();
      if (v.isNotEmpty) {
        PublicIdCard._cached = v;
        if (mounted) setState(() => _id = v);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final id = _id;
    if (id == null) return const SizedBox.shrink();
    return Container(
      margin: widget.margin,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        const Icon(Icons.badge_outlined, color: AppColors.accent),
        const SizedBox(width: 10),
        const Text('رقمك التعريفي:', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(width: 8),
        Expanded(child: Text(id, textDirection: TextDirection.ltr, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17, letterSpacing: 1.5))),
        IconButton(
          tooltip: 'نسخ',
          icon: const Icon(Icons.copy, size: 20),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: id));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم نسخ الرقم التعريفي')));
          },
        ),
      ]),
    );
  }
}
