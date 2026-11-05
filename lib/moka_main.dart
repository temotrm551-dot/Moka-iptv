import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'main.dart' hide main;
import 'moka_account_page.dart';

void main() => runApp(const MokaShellApp());

class MokaShellApp extends StatelessWidget {
  const MokaShellApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'MOKA IPTV',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFC8742B),
            brightness: Brightness.dark,
          ),
        ),
        home: const MokaShell(),
      );
}

class MokaShell extends StatefulWidget {
  const MokaShell({super.key});

  @override
  State<MokaShell> createState() => _MokaShellState();
}

class _MokaShellState extends State<MokaShell> {
  int _tab = 0;
  int _homeVersion = 0;

  void _logout() {
    if (!mounted) return;
    setState(() {
      _tab = 0;
      _homeVersion++;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: IndexedStack(
          index: _tab,
          children: [
            HomePage(key: ValueKey(_homeVersion)),
            VodBrowser(kind: 'movie', active: _tab == 1),
            VodBrowser(kind: 'series', active: _tab == 2),
            MokaAccountPage(onLogout: _logout),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.live_tv),
              label: 'Live',
            ),
            NavigationDestination(
              icon: Icon(Icons.movie),
              label: 'Movies',
            ),
            NavigationDestination(
              icon: Icon(Icons.video_library),
              label: 'Series',
            ),
            NavigationDestination(
              icon: Icon(Icons.account_circle_outlined),
              label: 'Account',
            ),
          ],
        ),
      );
}

/// Bumped whenever favorites or "continue watching" change.
final ValueNotifier<int> vodRev = ValueNotifier<int>(0);

const String kVodFav = '__fav';
const String kVodRecent = '__recent';

String vodFmt(int ms) {
  final d = Duration(milliseconds: ms);
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  return h > 0
      ? '$h:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}'
      : '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
}

class VodCat {
  final String id, name;
  const VodCat(this.id, this.name);
}

class VodItem {
  final String id, name, poster, ext, rating;

  const VodItem({
    required this.id,
    required this.name,
    this.poster = '',
    this.ext = 'mp4',
    this.rating = '',
  });
}

class VodEntry {
  final String title, url;
  const VodEntry(this.title, this.url);
}

/// One quality of a movie/series (e.g. FHD, HD).
class VodVariant {
  final String id, ext, quality, fullName;

  const VodVariant({
    required this.id,
    required this.ext,
    required this.quality,
    required this.fullName,
  });

  Map<String, dynamic> toJson() =>
      {'id': id, 'ext': ext, 'q': quality, 'n': fullName};

  factory VodVariant.fromJson(Map<String, dynamic> j) => VodVariant(
        id: '${j['id']}',
        ext: '${j['ext'] ?? 'mp4'}',
        quality: '${j['q'] ?? ''}',
        fullName: '${j['n'] ?? ''}',
      );
}

/// A movie/series with all of its available qualities.
class VodGroup {
  final String kind, name, poster;
  final List<VodVariant> variants;

  const VodGroup({
    required this.kind,
    required this.name,
    required this.poster,
    required this.variants,
  });

  String get key => '$kind|${name.toLowerCase()}';

  String get qualities => [
        for (final v in variants)
          if (v.quality.isNotEmpty) v.quality
      ].toSet().join(' · ');

  Map<String, dynamic> toJson() => {
        'k': kind,
        'n': name,
        'p': poster,
        'v': [for (final v in variants) v.toJson()],
      };

  factory VodGroup.fromJson(Map<String, dynamic> j) => VodGroup(
        kind: '${j['k']}',
        name: '${j['n']}',
        poster: '${j['p'] ?? ''}',
        variants: [
          for (final v in (j['v'] as List))
            VodVariant.fromJson(Map<String, dynamic>.from(v as Map))
        ],
      );
}

class VodRecent {
  final String url, title, poster, kind;
  final int posMs, durMs, ts, index;
  final List<List<String>> items;

  const VodRecent({
    required this.url,
    required this.title,
    required this.poster,
    required this.kind,
    required this.posMs,
    required this.durMs,
    required this.ts,
    required this.index,
    required this.items,
  });

  Map<String, dynamic> toJson() => {
        'u': url,
        't': title,
        'p': poster,
        'k': kind,
        'pos': posMs,
        'dur': durMs,
        'ts': ts,
        'i': index,
        'items': items,
      };

  factory VodRecent.fromJson(Map<String, dynamic> j) => VodRecent(
        url: '${j['u']}',
        title: '${j['t']}',
        poster: '${j['p'] ?? ''}',
        kind: '${j['k'] ?? 'movie'}',
        posMs: (j['pos'] as num?)?.toInt() ?? 0,
        durMs: (j['dur'] as num?)?.toInt() ?? 0,
        ts: (j['ts'] as num?)?.toInt() ?? 0,
        index: (j['i'] as num?)?.toInt() ?? 0,
        items: [
          for (final e in (j['items'] as List))
            [for (final s in (e as List)) '$s']
        ],
      );
}

class VodStore {
  static Future<SharedPreferences> get _p => SharedPreferences.getInstance();

  static String _fk(Source s) => 'vfav:${s.url}|${s.user}';

  static Future<List<VodGroup>> favs(Source s) async {
    final raw = (await _p).getString(_fk(s));
    if (raw == null) return [];
    try {
      return [
        for (final j in jsonDecode(raw) as List)
          VodGroup.fromJson(Map<String, dynamic>.from(j as Map))
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<bool> toggleFav(Source s, VodGroup g) async {
    final l = await favs(s);
    final i = l.indexWhere((x) => x.key == g.key);
    final added = i < 0;
    if (added) {
      l.insert(0, g);
    } else {
      l.removeAt(i);
    }
    await (await _p).setString(
      _fk(s),
      jsonEncode([for (final x in l) x.toJson()]),
    );
    vodRev.value++;
    return added;
  }

  static Future<int> savedPos(String url) async =>
      (await _p).getInt('pos:$url') ?? 0;

  static Future<List<VodRecent>> recents() async {
    final raw = (await _p).getString('vrecent');
    if (raw == null) return [];
    try {
      return [
        for (final j in jsonDecode(raw) as List)
          VodRecent.fromJson(Map<String, dynamic>.from(j as Map))
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> _saveRecents(
    List<VodRecent> l, {
    bool notify = true,
  }) async {
    await (await _p).setString(
      'vrecent',
      jsonEncode([for (final r in l) r.toJson()]),
    );
    if (notify) vodRev.value++;
  }

  static Future<void> upsertRecent(
    VodRecent r, {
    bool notify = false,
  }) async {
    final l = await recents();
    l.removeWhere((x) => x.url == r.url);
    l.insert(0, r);
    if (l.length > 12) l.removeRange(12, l.length);
    await _saveRecents(l, notify: notify);
  }

  static Future<void> removeRecent(String url) async {
    final l = await recents();
    final before = l.length;
    l.removeWhere((x) => x.url == url);
    if (l.length != before) await _saveRecents(l);
  }
}

final RegExp _qRe = RegExp(
  r'\s*[\(\[\{]\s*(4k|uhd|fhd|hd|sd|hq|1080p?|720p?|480p?)\s*[\)\]\}]\s*$',
  caseSensitive: false,
);

class _Q {
  final String base, q;
  const _Q(this.base, this.q);
}

_Q vodSplitQuality(String name) {
  var s = name.trim();
  var q = '';
  while (true) {
    final m = _qRe.firstMatch(s);
    if (m == null) break;
    if (q.isEmpty) q = m.group(1)!.toUpperCase();
    s = s.substring(0, m.start).trim();
  }
  return _Q(s.isEmpty ? name.trim() : s, q);
}

int _qRank(String q) {
  switch (q) {
    case '4K':
    case 'UHD':
      return 0;
    case 'FHD':
    case '1080P':
    case '1080':
      return 1;
    case 'HD':
    case '720P':
    case '720':
      return 2;
    case 'HQ':
      return 3;
    case 'SD':
    case '480P':
    case '480':
      return 4;
    default:
      return 5;
  }
}

VodGroup _makeGroup(String kind, String name, List<VodItem> its) {
  final vs = [
    for (final it in its)
      VodVariant(
        id: it.id,
        ext: it.ext,
        quality: vodSplitQuality(it.name).q,
        fullName: it.name,
      )
  ]..sort((a, b) => _qRank(a.quality).compareTo(_qRank(b.quality)));
  final withPoster = its.where((x) => x.poster.isNotEmpty);
  return VodGroup(
    kind: kind,
    name: name,
    poster: withPoster.isEmpty ? '' : withPoster.first.poster,
    variants: vs,
  );
}

List<VodGroup> vodGroupItems(String kind, List<VodItem> items) {
  final map = <String, List<VodItem>>{};
  final names = <String, String>{};
  for (final it in items) {
    final q = vodSplitQuality(it.name);
    final key = q.base.toLowerCase();
    (map[key] ??= <VodItem>[]).add(it);
    names.putIfAbsent(key, () => q.base);
  }
  return [
    for (final e in map.entries)
      _makeGroup(kind, names[e.key] ?? e.key, e.value)
  ];
}

String _base(Source s) => s.url.replaceAll(RegExp(r'/+$'), '');

String _apiUrl(Source s, String action, [String extra = '']) =>
    '${_base(s)}/player_api.php'
    '?username=${Uri.encodeComponent(s.user)}'
    '&password=${Uri.encodeComponent(s.pass)}'
    '&action=$action$extra';

String _mediaUrl(Source s, String kind, String id, String ext) =>
    '${_base(s)}/$kind/${s.user}/${s.pass}/$id.$ext';

Future<dynamic> _getJson(String url) async {
  final res =
      await http.get(Uri.parse(url)).timeout(const Duration(seconds: 45));
  if (res.statusCode != 200) throw 'HTTP ${res.statusCode}';
  return jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
}

String _txt(dynamic v) {
  if (v == null) return '';
  final s = '$v'.trim();
  return s == 'null' ? '' : s;
}

/// Details (plot, cast...) from get_vod_info / get_series_info.
class _Info {
  String plot = '';
  String cast = '';
  String director = '';
  String genre = '';
  String release = '';
  String duration = '';
  String rating = '';
}

_Info _parseInfo(dynamic info) {
  final r = _Info();
  if (info is! Map) return r;
  r.plot = _txt(info['plot'] ?? info['description']);
  r.cast = _txt(info['cast'] ?? info['actors']);
  r.director = _txt(info['director']);
  r.genre = _txt(info['genre']);
  r.release =
      _txt(info['releasedate'] ?? info['release_date'] ?? info['releaseDate']);
  r.duration = _txt(info['duration']);
  r.rating = _txt(info['rating'] ?? info['rating_5based']);
  return r;
}

/// Opens the details page (it does NOT start playback).
void vodOpenGroup(BuildContext context, Source s, VodGroup g) {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => g.kind == 'series'
          ? SeriesDetailPage(source: s, group: g)
          : VodDetailPage(source: s, group: g),
    ),
  );
}

class _PosterTile extends StatelessWidget {
  final VodGroup group;
  final bool isFav;
  final VoidCallback onTap, onFav;

  const _PosterTile({
    required this.group,
    required this.isFav,
    required this.onTap,
    required this.onFav,
  });

  Widget _ph() => const ColoredBox(
        color: Colors.black26,
        child: Center(child: Icon(Icons.movie, size: 40)),
      );

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    group.poster.isEmpty
                        ? _ph()
                        : Image.network(
                            group.poster,
                            fit: BoxFit.cover,
                            cacheWidth: 300,
                            errorBuilder: (_, __, ___) => _ph(),
                          ),
                    if (group.qualities.isNotEmpty)
                      Positioned(
                        left: 4,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            group.qualities,
                            style: const TextStyle(fontSize: 10),
                          ),
                        ),
                      ),
                    Positioned(
                      top: 0,
                      right: 0,
                      child: ExcludeFocus(
                        child: IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: Icon(isFav ? Icons.star : Icons.star_border),
                          color: Colors.amber,
                          onPressed: onFav,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              group.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
}

/// Poster + title + rating + plot + cast.
class _InfoPanel extends StatelessWidget {
  final String poster, title;
  final _Info info;

  const _InfoPanel({
    required this.poster,
    required this.title,
    required this.info,
  });

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 900;
    final pw = wide ? 220.0 : 110.0;
    final t = Theme.of(context).textTheme;
    final meta = <String>[
      if (info.release.isNotEmpty) info.release,
      if (info.duration.isNotEmpty) info.duration,
      if (info.genre.isNotEmpty) info.genre,
    ];
    final rating = double.tryParse(info.rating) ?? 0;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (poster.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(
                  poster,
                  width: pw,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      SizedBox(width: pw, height: pw * 1.4),
                ),
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: wide ? t.headlineSmall : t.titleLarge),
                const SizedBox(height: 6),
                if (rating > 0 || meta.isNotEmpty)
                  Wrap(
                    spacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (rating > 0)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.star, size: 16, color: Colors.amber),
                            const SizedBox(width: 4),
                            Text(rating.toStringAsFixed(1)),
                          ],
                        ),
                      for (final m in meta) Text(m, style: t.bodySmall),
                    ],
                  ),
                const SizedBox(height: 10),
                Text(info.plot.isEmpty
                    ? 'No description available.'
                    : info.plot),
                if (info.cast.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text('Cast: ${info.cast}', style: t.bodySmall),
                ],
                if (info.director.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('Director: ${info.director}', style: t.bodySmall),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Movies or Series browser (Xtream Codes only).
class VodBrowser extends StatefulWidget {
  final String kind;
  final bool active;

  const VodBrowser({
    super.key,
    required this.kind,
    required this.active,
  });

  @override
  State<VodBrowser> createState() => _VodBrowserState();
}

class _VodBrowserState extends State<VodBrowser> {
  Source? _src;
  String _sig = '';
  bool _started = false;
  List<VodCat> _cats = [];
  String _cat = '';
  List<VodGroup> _groups = [];
  List<VodGroup> _favs = [];
  Set<String> _favKeys = {};
  List<VodRecent> _recents = [];
  String _query = '';
  bool _loading = false;
  String? _error;

  bool get _isMovie => widget.kind == 'movie';

  @override
  void initState() {
    super.initState();
    vodRev.addListener(_reloadLists);
    if (widget.active) _sync();
  }

  @override
  void dispose() {
    vodRev.removeListener(_reloadLists);
    super.dispose();
  }

  @override
  void didUpdateWidget(VodBrowser old) {
    super.didUpdateWidget(old);
    if (widget.active) _sync();
  }

  Future<void> _reloadLists() async {
    final s = _src;
    if (s == null) return;
    final f = await VodStore.favs(s);
    final all = await VodStore.recents();
    final base = _base(s);
    final r = all
        .where((x) =>
            x.kind == widget.kind &&
            x.items.isNotEmpty &&
            x.url.startsWith(base))
        .toList();
    if (!mounted) return;
    setState(() {
      _favKeys = {for (final g in f) g.key};
      _favs = f.where((g) => g.kind == widget.kind).toList();
      _recents = r;
    });
  }

  Future<void> _sync({bool force = false}) async {
    final list = await Store.sources();
    final i = await Store.active();
    final s = list.isEmpty ? null : list[i < list.length ? i : 0];
    final sig = s == null ? '' : '${s.type}|${s.url}|${s.user}|${s.pass}';

    if (_started && sig == _sig && !force) return;

    _started = true;
    _sig = sig;
    _src = s;
    _cats = [];
    _groups = [];
    _cat = '';
    _error = null;

    if (mounted) setState(() {});
    await _reloadLists();

    if (s != null && s.type == 'xtream') {
      await _loadCats();
    }
  }

  Future<void> _loadCats() async {
    final s = _src;
    if (s == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final hide = await Store.adultLock();
      final data = await _getJson(
        _apiUrl(
          s,
          _isMovie ? 'get_vod_categories' : 'get_series_categories',
        ),
      );

      if (data is! List) throw 'Unexpected reply from server';

      var cats = [
        for (final c in data)
          VodCat('${c['category_id']}', '${c['category_name']}')
      ];

      if (hide) {
        cats = cats
            .where((c) => !isAdult(Channel(c.name, '', '', '')))
            .toList();
      }

      if (!mounted) return;
      setState(() => _cats = cats);

      if (cats.isNotEmpty) await _pick(cats.first.id);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pick(String id) async {
    final s = _src;
    if (s == null) return;

    if (id == kVodFav || id == kVodRecent) {
      setState(() {
        _cat = id;
        _error = null;
      });
      _reloadLists();
      return;
    }

    setState(() {
      _cat = id;
      _groups = [];
      _loading = true;
      _error = null;
    });

    try {
      final data = await _getJson(
        _apiUrl(
          s,
          _isMovie ? 'get_vod_streams' : 'get_series',
          id.isEmpty ? '' : '&category_id=$id',
        ),
      );

      if (data is! List) throw 'Unexpected reply from server';

      final items = [
        for (final x in data)
          VodItem(
            id: '${_isMovie ? x['stream_id'] : x['series_id']}',
            name: '${x['name']}',
            poster: '${(_isMovie ? x['stream_icon'] : x['cover']) ?? ''}',
            ext: '${x['container_extension'] ?? 'mp4'}',
            rating: '${x['rating'] ?? ''}',
          )
      ];

      if (mounted && _cat == id) {
        setState(() => _groups = vodGroupItems(widget.kind, items));
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _recentList(List<VodRecent> list) {
    if (list.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Nothing to continue yet.\nStart something and it will appear here.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (_, i) {
        final r = list[i];
        final frac = r.durMs > 0
            ? (r.posMs / r.durMs).clamp(0.0, 1.0).toDouble()
            : 0.0;
        return ListTile(
          leading: SizedBox(
            width: 48,
            child: r.poster.isEmpty
                ? const Icon(Icons.movie)
                : Image.network(
                    r.poster,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(Icons.movie),
                  ),
          ),
          title: Text(r.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 4),
              LinearProgressIndicator(value: frac),
              const SizedBox(height: 4),
              Text('${vodFmt(r.posMs)} / ${vodFmt(r.durMs)}'),
            ],
          ),
          trailing: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => VodStore.removeRecent(r.url),
          ),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => VodPlayerPage(
                items: [for (final it in r.items) VodEntry(it[0], it[1])],
                index: r.index.clamp(0, r.items.length - 1).toInt(),
                poster: r.poster,
                kind: r.kind,
                startMs: r.posMs,
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _src;
    final q = _query.toLowerCase();
    final favView = _cat == kVodFav;
    final recentView = _cat == kVodRecent;
    final shown = (favView ? _favs : _groups)
        .where((g) => g.name.toLowerCase().contains(q))
        .toList();
    final recents =
        _recents.where((r) => r.title.toLowerCase().contains(q)).toList();

    final width = MediaQuery.of(context).size.width;
    final wide = width >= 900;
    final panelWidth = wide ? 260.0 : (width >= 600 ? 200.0 : 130.0);
    final posterExtent = wide ? 190.0 : 140.0;

    Widget catTile(VodCat c) => ListTile(
          dense: !wide,
          selected: _cat == c.id,
          selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          title: Text(c.name, maxLines: 2, overflow: TextOverflow.ellipsis),
          onTap: () => _pick(c.id),
        );

    Widget body;

    if (!_started || s == null) {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Add a playlist from the Live tab first',
            textAlign: TextAlign.center,
          ),
        ),
      );
    } else if (s.type != 'xtream') {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Movies and series need an Xtream account.\nAdd one from the Live tab.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    } else {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: panelWidth,
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                catTile(VodCat(kVodFav, '★ Favorites (${_favs.length})')),
                catTile(const VodCat(kVodRecent, '▶ Continue watching')),
                const Divider(height: 1),
                for (final c in [const VodCat('', 'All'), ..._cats])
                  catTile(c),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                if (_loading) const LinearProgressIndicator(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search',
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
                Expanded(
                  child: recentView
                      ? _recentList(recents)
                      : (shown.isEmpty && !_loading
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  favView
                                      ? 'No favorites yet.\nOpen a title and tap the star.'
                                      : 'Nothing here',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            )
                          : GridView.builder(
                              padding: const EdgeInsets.all(12),
                              gridDelegate:
                                  SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: posterExtent,
                                childAspectRatio: 0.58,
                                crossAxisSpacing: 10,
                                mainAxisSpacing: 10,
                              ),
                              itemCount: shown.length,
                              itemBuilder: (_, i) {
                                final g = shown[i];
                                return _PosterTile(
                                  group: g,
                                  isFav: _favKeys.contains(g.key),
                                  onTap: () => vodOpenGroup(context, s, g),
                                  onFav: () => VodStore.toggleFav(s, g),
                                );
                              },
                            )),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isMovie ? 'Movies' : 'Series',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _sync(force: true),
          ),
        ],
      ),
      body: body,
    );
  }
}

/// Movie details: info, qualities, resume.
class VodDetailPage extends StatefulWidget {
  final Source source;
  final VodGroup group;

  const VodDetailPage({super.key, required this.source, required this.group});

  @override
  State<VodDetailPage> createState() => _VodDetailPageState();
}

class _VodDetailPageState extends State<VodDetailPage> {
  _Info _info = _Info();
  bool _fav = false;
  final Map<String, int> _saved = {};

  String _url(VodVariant v) => _mediaUrl(widget.source, 'movie', v.id, v.ext);

  int _sp(VodVariant v) => _saved[v.id] ?? 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, int>> _computeSaved() async {
    final m = <String, int>{};
    for (final v in widget.group.variants) {
      m[v.id] = await VodStore.savedPos(_url(v));
    }
    return m;
  }

  Future<void> _load() async {
    final favs = await VodStore.favs(widget.source);
    final f = favs.any((x) => x.key == widget.group.key);
    final m = await _computeSaved();
    if (!mounted) return;
    setState(() {
      _fav = f;
      _saved
        ..clear()
        ..addAll(m);
    });
    try {
      final d = await _getJson(
        _apiUrl(
          widget.source,
          'get_vod_info',
          '&vod_id=${widget.group.variants.first.id}',
        ),
      );
      if (d is Map && mounted) {
        setState(() => _info = _parseInfo(d['info']));
      }
    } catch (_) {}
  }

  Future<void> _toggleFav() async {
    final added = await VodStore.toggleFav(widget.source, widget.group);
    if (mounted) setState(() => _fav = added);
  }

  Future<void> _play(VodVariant v, int startMs) async {
    final g = widget.group;
    final title = v.quality.isEmpty ? g.name : '${g.name} (${v.quality})';
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VodPlayerPage(
          items: [VodEntry(title, _url(v))],
          index: 0,
          poster: g.poster,
          kind: 'movie',
          startMs: startMs,
        ),
      ),
    );
    final m = await _computeSaved();
    if (!mounted) return;
    setState(() {
      _saved
        ..clear()
        ..addAll(m);
    });
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    return Scaffold(
      appBar: AppBar(
        title: Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: Icon(_fav ? Icons.star : Icons.star_border),
            color: Colors.amber,
            onPressed: _toggleFav,
          ),
        ],
      ),
      body: ListView(
        children: [
          _InfoPanel(poster: g.poster, title: g.name, info: _info),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Watch',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          for (final v in g.variants)
            ListTile(
              autofocus: v == g.variants.first,
              leading: const Icon(Icons.play_circle_outline),
              title: Text(
                v.quality.isEmpty ? 'Play' : 'Play · ${v.quality}',
              ),
              subtitle: _sp(v) > 10000
                  ? Text('Stopped at ${vodFmt(_sp(v))} - tap to resume')
                  : null,
              trailing: _sp(v) > 10000
                  ? TextButton(
                      onPressed: () => _play(v, 0),
                      child: const Text('Start over'),
                    )
                  : null,
              onTap: () => _play(v, _sp(v) > 10000 ? _sp(v) : 0),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _Ep {
  final String id, title, number, ext;
  const _Ep(this.id, this.title, this.number, this.ext);
}

class _Resume {
  final String season;
  final int index, posMs;
  const _Resume(this.season, this.index, this.posMs);
}

/// Series details: info, qualities, seasons, episodes, resume.
class SeriesDetailPage extends StatefulWidget {
  final Source source;
  final VodGroup group;

  const SeriesDetailPage({
    super.key,
    required this.source,
    required this.group,
  });

  @override
  State<SeriesDetailPage> createState() => _SeriesDetailPageState();
}

class _SeriesDetailPageState extends State<SeriesDetailPage> {
  final Map<String, List<_Ep>> _seasons = {};
  final Map<String, int> _saved = {};
  late VodVariant _variant = widget.group.variants.first;
  _Info _info = _Info();
  _Resume? _resume;
  String _season = '';
  bool _fav = false;
  bool _loading = true;
  String? _error;

  String _urlOf(_Ep e) => _mediaUrl(widget.source, 'series', e.id, e.ext);

  int _sp(_Ep e) => _saved[_urlOf(e)] ?? 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<String> _sortedSeasons() => _seasons.keys.toList()
    ..sort(
      (a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0),
    );

  Future<Map<String, int>> _computeSaved() async {
    final m = <String, int>{};
    for (final list in _seasons.values) {
      for (final e in list) {
        m[_urlOf(e)] = await VodStore.savedPos(_urlOf(e));
      }
    }
    return m;
  }

  Future<_Resume?> _findResume() async {
    final recents = await VodStore.recents();
    for (final r in recents) {
      for (final k in _sortedSeasons()) {
        final list = _seasons[k] ?? <_Ep>[];
        final idx = list.indexWhere((e) => _urlOf(e) == r.url);
        if (idx >= 0) return _Resume(k, idx, r.posMs);
      }
    }
    return null;
  }

  Future<void> _load() async {
    try {
      final d = await _getJson(
        _apiUrl(
          widget.source,
          'get_series_info',
          '&series_id=${_variant.id}',
        ),
      );

      if (d is! Map) throw 'Unexpected reply from server';

      _info = _parseInfo(d['info']);

      List<_Ep> eps(dynamic l) => [
            if (l is List)
              for (final x in l)
                _Ep(
                  '${x['id']}',
                  '${x['title'] ?? 'Episode'}',
                  '${x['episode_num'] ?? ''}',
                  '${x['container_extension'] ?? 'mp4'}',
                )
          ];

      final e = d['episodes'];
      if (e is Map) {
        e.forEach((k, v) => _seasons['$k'] = eps(v));
      } else if (e is List) {
        for (var i = 0; i < e.length; i++) {
          _seasons['${i + 1}'] = eps(e[i]);
        }
      }

      _seasons.removeWhere((k, v) => v.isEmpty);
      final keys = _sortedSeasons();
      if (keys.isNotEmpty) _season = keys.first;

      final favs = await VodStore.favs(widget.source);
      _fav = favs.any((x) => x.key == widget.group.key);
      final m = await _computeSaved();
      _saved
        ..clear()
        ..addAll(m);
      _resume = await _findResume();
    } catch (e) {
      _error = '$e';
    }

    if (mounted) setState(() => _loading = false);
  }

  void _switchVariant(VodVariant v) {
    if (v == _variant) return;
    setState(() {
      _variant = v;
      _loading = true;
      _error = null;
      _seasons.clear();
      _saved.clear();
      _season = '';
      _resume = null;
      _info = _Info();
    });
    _load();
  }

  Future<void> _toggleFav() async {
    final added = await VodStore.toggleFav(widget.source, widget.group);
    if (mounted) setState(() => _fav = added);
  }

  Future<void> _play(List<_Ep> list, int i, int startMs) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VodPlayerPage(
          items: [
            for (final e in list)
              VodEntry(
                '${widget.group.name} · S$_season E${e.number}',
                _urlOf(e),
              )
          ],
          index: i,
          poster: widget.group.poster,
          kind: 'series',
          startMs: startMs,
        ),
      ),
    );
    final m = await _computeSaved();
    final r = await _findResume();
    if (!mounted) return;
    setState(() {
      _saved
        ..clear()
        ..addAll(m);
      _resume = r;
    });
  }

  String _resumeLabel() {
    final r = _resume;
    if (r == null) return '';
    final list = _seasons[r.season];
    final ep =
        (list != null && r.index < list.length) ? list[r.index].number : '';
    final label = ep.isEmpty ? '${r.index + 1}' : ep;
    return 'Continue · S${r.season} E$label · ${vodFmt(r.posMs)}';
  }

  @override
  Widget build(BuildContext context) {
    final seasons = _sortedSeasons();
    final list = _seasons[_season] ?? <_Ep>[];
    final g = widget.group;

    return Scaffold(
      appBar: AppBar(
        title: Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: Icon(_fav ? Icons.star : Icons.star_border),
            color: Colors.amber,
            onPressed: _toggleFav,
          ),
        ],
      ),
      body: ListView(
        children: [
          _InfoPanel(poster: g.poster, title: g.name, info: _info),
          if (g.variants.length > 1)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Text('Quality:'),
                    ),
                  ),
                  for (final v in g.variants)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(v.quality.isEmpty ? 'Default' : v.quality),
                        selected: v == _variant,
                        onSelected: (_) => _switchVariant(v),
                      ),
                    ),
                ],
              ),
            ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent),
              ),
            )
          else ...[
            if (_resume != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    autofocus: true,
                    onPressed: () {
                      final r = _resume!;
                      setState(() => _season = r.season);
                      _play(_seasons[r.season] ?? <_Ep>[], r.index, r.posMs);
                    },
                    icon: const Icon(Icons.play_arrow),
                    label: Text(_resumeLabel()),
                  ),
                ),
              ),
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final k in seasons)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text('Season $k'),
                        selected: _season == k,
                        onSelected: (_) => setState(() => _season = k),
                      ),
                    ),
                ],
              ),
            ),
            for (var i = 0; i < list.length; i++)
              ListTile(
                leading: CircleAvatar(
                  child: Text(
                    list[i].number.isEmpty ? '${i + 1}' : list[i].number,
                  ),
                ),
                title: Text(
                  list[i].title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: _sp(list[i]) > 10000
                    ? Text('Stopped at ${vodFmt(_sp(list[i]))}')
                    : null,
                trailing: _sp(list[i]) > 10000
                    ? TextButton(
                        onPressed: () => _play(list, i, 0),
                        child: const Text('Start over'),
                      )
                    : null,
                onTap: () =>
                    _play(list, i, _sp(list[i]) > 10000 ? _sp(list[i]) : 0),
              ),
            const SizedBox(height: 24),
          ],
        ],
      ),
    );
  }
}

/// Player for movies and episodes: seek bar, resume, auto-next.
class VodPlayerPage extends StatefulWidget {
  final List<VodEntry> items;
  final int index;
  final String poster;
  final String kind;
  final int? startMs;

  const VodPlayerPage({
    super.key,
    required this.items,
    required this.index,
    this.poster = '',
    this.kind = 'movie',
    this.startMs,
  });

  @override
  State<VodPlayerPage> createState() => _VodPlayerPageState();
}

class _VodPlayerPageState extends State<VodPlayerPage> {
  late int _i = widget.index;
  VideoPlayerController? _c;
  bool _overlay = true;
  bool _advanced = false;
  bool _first = true;
  String? _err;
  Timer? _hide;
  Timer? _saver;

  VodEntry get _e => widget.items[_i];
  String get _posKey => 'pos:${_e.url}';

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    _saver = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _savePos(),
    );
    _open();
  }

  @override
  void dispose() {
    _hide?.cancel();
    _saver?.cancel();
    _savePos(notify: true);
    _c?.dispose();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _savePos({bool notify = false}) {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;

    final p = c.value.position.inMilliseconds;
    final d = c.value.duration.inMilliseconds;
    final e = _e;
    final done = d > 0 && p > d - 15000;

    SharedPreferences.getInstance()
        .then((x) => x.setInt('pos:${e.url}', done ? 0 : p));

    if (done) {
      VodStore.removeRecent(e.url);
    } else if (p > 10000) {
      VodStore.upsertRecent(
        VodRecent(
          url: e.url,
          title: e.title,
          poster: widget.poster,
          kind: widget.kind,
          posMs: p,
          durMs: d,
          ts: DateTime.now().millisecondsSinceEpoch,
          index: _i,
          items: [
            for (final it in widget.items) [it.title, it.url]
          ],
        ),
        notify: notify,
      );
    }
  }

  Future<void> _open() async {
    final old = _c;
    final first = _first;
    _first = false;
    final c = VideoPlayerController.networkUrl(Uri.parse(_e.url));
    _advanced = false;

    setState(() {
      _c = c;
      _err = null;
    });

    _showOverlay();
    await old?.dispose();

    try {
      await c.initialize();
      if (!mounted || _c != c) return;

      final prefs = await SharedPreferences.getInstance();
      final saved = (first && widget.startMs != null)
          ? widget.startMs!
          : (prefs.getInt(_posKey) ?? 0);
      final dur = c.value.duration.inMilliseconds;

      if (saved > 10000 && saved < dur - 15000) {
        await c.seekTo(Duration(milliseconds: saved));
      }

      if (!mounted || _c != c) return;

      c.addListener(_tick);
      await c.play();

      if (mounted) setState(() {});
    } catch (_) {
      if (mounted && _c == c) {
        setState(() => _err = 'Cannot play this video');
      }
    }
  }

  void _tick() {
    if (!mounted) return;

    final v = _c?.value;
    if (v == null) return;

    if (v.hasError) {
      setState(() => _err = 'Playback error');
      return;
    }

    if (v.isInitialized &&
        v.duration.inMilliseconds > 0 &&
        !_advanced &&
        v.position.inMilliseconds >= v.duration.inMilliseconds - 500 &&
        _i < widget.items.length - 1) {
      _advanced = true;
      _go(1);
      return;
    }

    setState(() {});
  }

  void _go(int d) {
    final j = _i + d;
    if (j < 0 || j >= widget.items.length) return;

    _savePos();
    _i = j;
    _open();
  }

  void _seek(int ms) {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;

    final dur = c.value.duration.inMilliseconds;
    final t = (c.value.position.inMilliseconds + ms).clamp(0, dur).toInt();

    c.seekTo(Duration(milliseconds: t));
    _showOverlay();
  }

  void _togglePlay() {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;

    c.value.isPlaying ? c.pause() : c.play();
    _showOverlay();
  }

  void _showOverlay() {
    if (!mounted) return;

    setState(() => _overlay = true);
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _overlay = false);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;

    final k = e.logicalKey;
    final down = e is KeyDownEvent;

    if (k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.mediaFastForward) {
      _seek(10000);
    } else if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.mediaRewind) {
      _seek(-10000);
    } else if (down &&
        (k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.numpadEnter ||
            k == LogicalKeyboardKey.space ||
            k == LogicalKeyboardKey.mediaPlayPause)) {
      _togglePlay();
    } else if (down &&
        (k == LogicalKeyboardKey.channelUp ||
            k == LogicalKeyboardKey.mediaTrackNext)) {
      _go(1);
    } else if (down &&
        (k == LogicalKeyboardKey.channelDown ||
            k == LogicalKeyboardKey.mediaTrackPrevious)) {
      _go(-1);
    } else if (k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.arrowDown) {
      _showOverlay();
    } else {
      return KeyEventResult.ignored;
    }

    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final v = c?.value;
    final ready = c != null && c.value.isInitialized && _err == null;
    final loading = _err == null &&
        (c == null || !c.value.isInitialized || c.value.isBuffering);
    final dur = v?.duration.inMilliseconds ?? 0;
    final pos = (v?.position.inMilliseconds ?? 0).clamp(0, dur).toInt();
    final playing = v?.isPlaying ?? false;

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () =>
              _overlay ? setState(() => _overlay = false) : _showOverlay(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (ready)
                Center(
                  child: AspectRatio(
                    aspectRatio: c!.value.aspectRatio,
                    child: VideoPlayer(c),
                  ),
                ),
              if (loading) const Center(child: CircularProgressIndicator()),
              if (_err != null)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_err!, style: const TextStyle(fontSize: 18)),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _open,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              if (_overlay) ...[
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    color: Colors.black54,
                    padding: const EdgeInsets.fromLTRB(4, 28, 4, 8),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back),
                          onPressed: () => Navigator.pop(context),
                        ),
                        Expanded(
                          child: Text(
                            _e.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 18),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    color: Colors.black54,
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Text(vodFmt(pos)),
                            Expanded(
                              child: Slider(
                                value: pos.toDouble(),
                                max: dur > 0 ? dur.toDouble() : 1,
                                onChanged: dur > 0
                                    ? (x) {
                                        c!.seekTo(
                                          Duration(milliseconds: x.toInt()),
                                        );
                                        _showOverlay();
                                      }
                                    : null,
                              ),
                            ),
                            Text(vodFmt(dur)),
                          ],
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              iconSize: 32,
                              icon: const Icon(Icons.skip_previous),
                              onPressed: _i > 0 ? () => _go(-1) : null,
                            ),
                            IconButton(
                              iconSize: 32,
                              icon: const Icon(Icons.replay_10),
                              onPressed: () => _seek(-10000),
                            ),
                            IconButton(
                              iconSize: 48,
                              icon: Icon(
                                playing
                                    ? Icons.pause_circle
                                    : Icons.play_circle,
                              ),
                              onPressed: _togglePlay,
                            ),
                            IconButton(
                              iconSize: 32,
                              icon: const Icon(Icons.forward_10),
                              onPressed: () => _seek(10000),
                            ),
                            IconButton(
                              iconSize: 32,
                              icon: const Icon(Icons.skip_next),
                              onPressed: _i < widget.items.length - 1
                                  ? () => _go(1)
                                  : null,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
