import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../services/viewer_identity.dart';

/// علامة مائية متحركة: IP + رقم الهاتف + البريد بخط صغير، تتكرر في عدة أماكن
/// وتغيّر مكانها كل بضع ثوانٍ (غير ثابتة) فلا يمكن قصّها من التسجيل بسهولة.
/// ضعها داخل Stack فوق الفيديو/الـ PDF؛ لا تلتقط اللمس.
class MovingWatermark extends StatefulWidget {
  /// نص إضافي (مثل الاسم/المعرّف من الخادم) يُضاف للأسطر.
  final String extra;
  final int copies;
  final double fontSize;
  final Color color;
  const MovingWatermark({super.key, this.extra = '', this.copies = 3, this.fontSize = 9.5, this.color = const Color(0x66FFFFFF)});

  @override
  State<MovingWatermark> createState() => _MovingWatermarkState();
}

class _MovingWatermarkState extends State<MovingWatermark> {
  final _rnd = Random();
  ViewerIdentity _id = const ViewerIdentity();
  late List<Alignment> _spots;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _spots = List.generate(widget.copies, (_) => _randomSpot());
    ViewerIdentity.load().then((v) {
      if (mounted) setState(() => _id = v);
    });
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      setState(() => _spots = List.generate(widget.copies, (_) => _randomSpot()));
    });
  }

  Alignment _randomSpot() => Alignment(_rnd.nextDouble() * 1.7 - .85, _rnd.nextDouble() * 1.7 - .85);

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lines = [..._id.lines, if (widget.extra.trim().isNotEmpty) widget.extra.trim()];
    if (lines.isEmpty) return const SizedBox.shrink();
    final style = TextStyle(color: widget.color, fontSize: widget.fontSize, fontWeight: FontWeight.w600, height: 1.25, shadows: const [Shadow(color: Colors.black54, blurRadius: 2)]);
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          for (final a in _spots)
            AnimatedAlign(
              duration: const Duration(milliseconds: 1800),
              curve: Curves.easeInOut,
              alignment: a,
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: Text(lines.join('\n'), style: style, textAlign: TextAlign.center),
              ),
            ),
        ],
      ),
    );
  }
}

/// أيقونة «فهمت» (حرف ف) أعلى يمين الفيديو.
class FahmtLogoBadge extends StatelessWidget {
  final double size;
  const FahmtLogoBadge({super.key, this.size = 30});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Opacity(
        opacity: .85,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(size * .22),
          child: Image.asset('assets/images/logo.png', width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
        ),
      ),
    );
  }
}
