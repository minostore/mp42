import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

import '../theme/app_theme.dart';
import 'hub_common.dart';

final _db = FirebaseFirestore.instance;

// ======================= تصفح المفهمين =======================
class MufhemsScreen extends StatefulWidget {
  final bool embedded;
  const MufhemsScreen({super.key, this.embedded = false});
  @override
  State<MufhemsScreen> createState() => _MufhemsScreenState();
}

class _MufhemsScreenState extends State<MufhemsScreen> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('تصفح المفهمين')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: TextField(
            onChanged: (v) => setState(() => _q = v.trim()),
            decoration: const InputDecoration(hintText: 'ابحث بالاسم أو التخصص...', prefixIcon: Icon(Icons.search)),
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _db.collection('users').where('role', isEqualTo: 'mufhem').where('isProfileApproved', isEqualTo: true).snapshots(),
            builder: (context, snap) {
              if (snap.hasError) return EmptyHint(icon: Icons.error_outline, text: 'تعذر تحميل المفهمين\n${snap.error}');
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final docs = snap.data!.docs.where((d) {
                if (_q.isEmpty) return true;
                final m = d.data();
                return '${m['fullName']} ${m['specialization']}'.contains(_q);
              }).toList();
              if (docs.isEmpty) return const EmptyHint(icon: Icons.people_outline, text: 'لا يوجد مفهمون مطابقون');
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 24),
                itemCount: docs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final m = docs[i].data();
                  final pic = (m['profilePictureUrl'] ?? '').toString();
                  return Card(
                    child: ListTile(
                      onTap: () => context.push('/mufhems/${docs[i].id}'),
                      leading: CircleAvatar(radius: 26, backgroundImage: pic.isEmpty ? null : CachedNetworkImageProvider(pic), child: pic.isEmpty ? const Icon(Icons.person) : null),
                      title: Row(children: [
                        Flexible(child: Text((m['fullName'] ?? 'مفهم').toString(), style: const TextStyle(fontWeight: FontWeight.w800))),
                        if (m['isVerified'] == true) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.verified, size: 16, color: Color(0xFF2563EB))),
                      ]),
                      subtitle: Text((m['specialization'] ?? '').toString()),
                      trailing: const Icon(Icons.chevron_left),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ]),
    );
  }
}

// ======================= ملف المفهم =======================
class MufhemProfileScreen extends StatelessWidget {
  final String mufhemId;
  const MufhemProfileScreen({super.key, required this.mufhemId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ملف المفهم')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: _db.collection('users').doc(mufhemId).snapshots(),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final m = snap.data!.data();
          if (m == null) return const EmptyHint(icon: Icons.person_off, text: 'الحساب غير موجود');
          final pic = (m['profilePictureUrl'] ?? '').toString();
          return ListView(padding: const EdgeInsets.all(16), children: [
            Center(child: CircleAvatar(radius: 48, backgroundImage: pic.isEmpty ? null : CachedNetworkImageProvider(pic), child: pic.isEmpty ? const Icon(Icons.person, size: 40) : null)),
            const SizedBox(height: 10),
            Center(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text((m['fullName'] ?? 'مفهم').toString(), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                if (m['isVerified'] == true) const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.verified, size: 20, color: Color(0xFF2563EB))),
              ]),
            ),
            if ((m['specialization'] ?? '').toString().isNotEmpty) Center(child: Text(m['specialization'].toString(), style: const TextStyle(color: AppColors.muted))),
            if ((m['bio'] ?? '').toString().isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: AppColors.paperDim, borderRadius: BorderRadius.circular(14)),
                child: Text(m['bio'].toString(), style: const TextStyle(height: 1.7)),
              ),
            ],
            const SizedBox(height: 20),
            const Text('أعمال المفهم', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _db.collection('portfolio').where('mufhemId', isEqualTo: mufhemId).where('status', isEqualTo: 'approved').snapshots(),
              builder: (context, w) {
                final works = w.data?.docs ?? [];
                if (works.isEmpty) return const EmptyHint(icon: Icons.video_library_outlined, text: 'لا توجد أعمال منشورة بعد');
                return _WorksGrid(works: works);
              },
            ),
          ]);
        },
      ),
    );
  }
}

// ======================= تصفح أعمال المفهمين =======================
class PortfolioScreen extends StatefulWidget {
  final bool embedded;
  const PortfolioScreen({super.key, this.embedded = false});
  @override
  State<PortfolioScreen> createState() => _PortfolioScreenState();
}

class _PortfolioScreenState extends State<PortfolioScreen> {
  String _cat = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('أعمال المفهمين')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _db.collection('portfolio').where('status', isEqualTo: 'approved').snapshots(),
        builder: (context, snap) {
          if (snap.hasError) return EmptyHint(icon: Icons.error_outline, text: 'تعذر تحميل الأعمال\n${snap.error}');
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final all = snap.data!.docs.toList()
            ..sort((a, b) => (parseDate(b['createdAt']) ?? DateTime(2000)).compareTo(parseDate(a['createdAt']) ?? DateTime(2000)));
          final cats = <String>{for (final d in all) if ((d['category'] ?? '').toString().isNotEmpty) d['category'].toString()}.toList();
          final shown = _cat.isEmpty ? all : all.where((d) => d['category'] == _cat).toList();
          return Column(children: [
            if (cats.isNotEmpty)
              SizedBox(
                height: 52,
                child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), children: [
                  Padding(padding: const EdgeInsets.only(left: 6), child: ChoiceChip(label: const Text('الكل'), selected: _cat.isEmpty, onSelected: (_) => setState(() => _cat = ''))),
                  for (final c in cats)
                    Padding(padding: const EdgeInsets.only(left: 6), child: ChoiceChip(label: Text(c), selected: _cat == c, onSelected: (_) => setState(() => _cat = c))),
                ]),
              ),
            Expanded(
              child: shown.isEmpty
                  ? const EmptyHint(icon: Icons.video_library_outlined, text: 'لا توجد أعمال منشورة حاليًا')
                  : SingleChildScrollView(padding: const EdgeInsets.all(12), child: _WorksGrid(works: shown)),
            ),
          ]);
        },
      ),
    );
  }
}

class _WorksGrid extends StatelessWidget {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> works;
  const _WorksGrid({required this.works});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: works.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: .82),
      itemBuilder: (_, i) {
        final w = works[i].data();
        final thumb = (w['thumbnailUrl'] ?? '').toString();
        return InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => context.push('/portfolio/${works[i].id}'),
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Stack(fit: StackFit.expand, children: [
                  thumb.isEmpty ? Container(color: AppColors.paperDim) : CachedNetworkImage(imageUrl: thumb, fit: BoxFit.cover),
                  if (w['mediaType'] == 'video') const Center(child: Icon(Icons.play_circle_fill, color: Colors.white, size: 40)),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text((w['title'] ?? '').toString(), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text((w['category'] ?? '').toString(), style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }
}

// ======================= تفاصيل العمل =======================
class PortfolioDetailScreen extends StatefulWidget {
  final String workId;
  const PortfolioDetailScreen({super.key, required this.workId});
  @override
  State<PortfolioDetailScreen> createState() => _PortfolioDetailScreenState();
}

class _PortfolioDetailScreenState extends State<PortfolioDetailScreen> {
  VideoPlayerController? _video;
  String? _loadedUrl;

  Future<void> _initVideo(String url) async {
    if (_loadedUrl == url) return;
    _loadedUrl = url;
    final c = VideoPlayerController.networkUrl(Uri.parse(url));
    await c.initialize();
    if (!mounted) { await c.dispose(); return; }
    setState(() => _video = c);
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تفاصيل العمل')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: _db.collection('portfolio').doc(widget.workId).snapshots(),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final w = snap.data!.data();
          if (w == null) return const EmptyHint(icon: Icons.search_off, text: 'العمل غير موجود');
          final media = (w['mediaUrl'] ?? '').toString();
          final isVideo = w['mediaType'] == 'video';
          if (isVideo && media.isNotEmpty) _initVideo(media);
          final c = _video;
          return ListView(children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: isVideo
                  ? (c != null && c.value.isInitialized
                      ? GestureDetector(
                          onTap: () => setState(() => c.value.isPlaying ? c.pause() : c.play()),
                          child: Stack(alignment: Alignment.center, children: [
                            VideoPlayer(c),
                            if (!c.value.isPlaying) const Icon(Icons.play_circle_fill, color: Colors.white, size: 64),
                            Positioned(bottom: 0, left: 0, right: 0, child: VideoProgressIndicator(c, allowScrubbing: true, colors: const VideoProgressColors(playedColor: AppColors.accent))),
                          ]),
                        )
                      : Container(color: Colors.black, child: const Center(child: CircularProgressIndicator())))
                  : (media.isEmpty ? Container(color: AppColors.paperDim) : CachedNetworkImage(imageUrl: media, fit: BoxFit.cover)),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text((w['title'] ?? '').toString(), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                const SizedBox(height: 6),
                if ((w['category'] ?? '').toString().isNotEmpty) Chip(label: Text(w['category'].toString()), backgroundColor: AppColors.primaryLight),
                const SizedBox(height: 8),
                Text((w['description'] ?? '').toString(), style: const TextStyle(height: 1.7)),
                const SizedBox(height: 16),
                if ((w['mufhemId'] ?? '').toString().isNotEmpty)
                  StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                    stream: _db.collection('users').doc(w['mufhemId'].toString()).snapshots(),
                    builder: (context, u) {
                      final m = u.data?.data();
                      if (m == null) return const SizedBox.shrink();
                      final pic = (m['profilePictureUrl'] ?? '').toString();
                      return Card(
                        child: ListTile(
                          onTap: () => context.push('/mufhems/${w['mufhemId']}'),
                          leading: CircleAvatar(backgroundImage: pic.isEmpty ? null : CachedNetworkImageProvider(pic), child: pic.isEmpty ? const Icon(Icons.person) : null),
                          title: Text((m['fullName'] ?? 'مفهم').toString(), style: const TextStyle(fontWeight: FontWeight.w800)),
                          subtitle: const Text('عرض ملف المفهم'),
                          trailing: const Icon(Icons.chevron_left),
                        ),
                      );
                    },
                  ),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}
