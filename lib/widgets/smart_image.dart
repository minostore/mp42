import 'dart:convert';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// يفك رابط data:image/...;base64,... إلى بايتات (أو null لو ليس data URI صالحًا).
Uint8List? decodeDataUri(String url) {
  final u = url.trim();
  if (!u.startsWith('data:')) return null;
  final comma = u.indexOf(',');
  if (comma < 0) return null;
  try {
    final meta = u.substring(5, comma);
    final payload = u.substring(comma + 1);
    if (meta.contains(';base64')) return base64Decode(payload.replaceAll(RegExp(r'\s'), ''));
    return Uint8List.fromList(utf8.encode(Uri.decodeComponent(payload)));
  } catch (_) {
    return null;
  }
}

/// ImageProvider يتعامل مع data: (صور الويب المحفوظة base64) والروابط العادية.
/// بديل لـ NetworkImage(url) الذي يفشل بـ «No host specified in URI data:image…».
ImageProvider smartImageProvider(String url) {
  final bytes = decodeDataUri(url);
  if (bytes != null) return MemoryImage(bytes);
  return CachedNetworkImageProvider(url);
}

/// بديل Image.network / CachedNetworkImage يدعم data: URI.
class SmartImage extends StatelessWidget {
  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget? placeholder;
  final Widget? error;
  const SmartImage(this.url, {super.key, this.fit = BoxFit.cover, this.width, this.height, this.placeholder, this.error});

  @override
  Widget build(BuildContext context) {
    final u = url.trim();
    final fallback = error ?? const SizedBox.shrink();
    if (u.isEmpty) return fallback;
    final bytes = decodeDataUri(u);
    if (u.startsWith('data:')) {
      if (bytes == null) return fallback;
      return Image.memory(bytes, fit: fit, width: width, height: height, gaplessPlayback: true, errorBuilder: (_, __, ___) => fallback);
    }
    return CachedNetworkImage(
      imageUrl: u,
      fit: fit,
      width: width,
      height: height,
      placeholder: placeholder == null ? null : (_, __) => placeholder!,
      errorWidget: (_, __, ___) => fallback,
    );
  }
}
