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
  List<VodItem> _items = [];
  String _query = '';
  bool _loading = false;
  String? _error;

  bool get _isMovie => widget.kind == 'movie';

  @override
  void initState() {
    super.initState();
    if (widget.active) _sync();
  }

  @override
  void didUpdateWidget(VodBrowser old) {
    super.didUpdateWidget(old);
    if (widget.active) _sync();
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
    _items = [];
    _cat = '';
    _error = null;

    if (mounted) setState(() {});

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

    setState(() {
      _cat = id;
      _items = [];
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
        setState(() => _items = items);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _open(VodItem it) {
    final s = _src!;
    if (_isMovie) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VodPlayerPage(
            items: [
              VodEntry(
                it.name,
                _mediaUrl(s, 'movie', it.id, it.ext),
              )
            ],
            index: 0,
          ),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SeriesDetailPage(source: s, item: it),
        ),
      );
    }
  }

  Widget _placeholder() => const ColoredBox(
        color: Colors.black26,
        child: Center(child: Icon(Icons.movie, size: 40)),
      );

  Widget _tile(VodItem it) => InkWell(
        onTap: () => _open(it),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox.expand(
                  child: it.poster.isEmpty
                      ? _placeholder()
                      : Image.network(
                          it.poster,
                          fit: BoxFit.cover,
                          cacheWidth: 300,
                          errorBuilder: (_, __, ___) => _placeholder(),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              it.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final s = _src;
    final q = _query.toLowerCase();
    final shown =
        _items.where((x) => x.name.toLowerCase().contains(q)).toList();

    final width = MediaQuery.of(context).size.width;
    final wide = width >= 900;
    final panelWidth = wide ? 260.0 : (width >= 600 ? 200.0 : 130.0);
    final posterExtent = wide ? 190.0 : 140.0;

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
                for (final c in [const VodCat('', 'All'), ..._cats])
                  ListTile(
                    dense: !wide,
                    selected: _cat == c.id,
                    selectedTileColor:
                        Theme.of(context).colorScheme.secondaryContainer,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12),
                    title: Text(
                      c.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => _pick(c.id),
                  ),
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
                  child: shown.isEmpty && !_loading
                      ? const Center(child: Text('Nothing here'))
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
                          itemBuilder: (_, i) => _tile(shown[i]),
                        ),
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

class _Ep {
  final String id, title, number, ext;
  const _Ep(this.id, this.title, this.number, this.ext);
}

class SeriesDetailPage extends StatefulWidget {
  final Source source;
  final VodItem item;

  const SeriesDetailPage({
    super.key,
    required this.source,
    required this.item,
  });

  @override
  State<SeriesDetailPage> createState() => _SeriesDetailPageState();
}

class _SeriesDetailPageState extends State<SeriesDetailPage> {
  final Map<String, List<_Ep>> _seasons = {};
  String _season = '';
  String _plot = '';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<String> _sortedSeasons() => _seasons.keys.toList()
    ..sort(
      (a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0),
    );

  Future<void> _load() async {
    try {
      final d = await _getJson(
        _apiUrl(
          widget.source,
          'get_series_info',
          '&series_id=${widget.item.id}',
        ),
      );

      if (d is! Map) throw 'Unexpected reply from server';

      final info = d['info'];
      _plot = info is Map ? '${info['plot'] ?? ''}' : '';

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
    } catch (e) {
      _error = '$e';
    }

    if (mounted) setState(() => _loading = false);
  }

  void _play(List<_Ep> list, int i) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VodPlayerPage(
          items: [
            for (final e in list)
              VodEntry(
                '${widget.item.name} · S$_season E${e.number}',
                _mediaUrl(widget.source, 'series', e.id, e.ext),
              )
          ],
          index: i,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final seasons = _sortedSeasons();
    final list = _seasons[_season] ?? <_Ep>[];

    return Scaffold(
      appBar: AppBar(title: Text(widget.item.name)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ),
                )
              : ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.item.poster.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(
                                  widget.item.poster,
                                  width: 100,
                                  errorBuilder: (_, __, ___) =>
                                      const SizedBox(width: 100, height: 140),
                                ),
                              ),
                            ),
                          Expanded(
                            child: Text(
                              _plot.isEmpty ? 'No description' : _plot,
                              maxLines: 8,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
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
                                onSelected: (_) =>
                                    setState(() => _season = k),
                              ),
                            ),
                        ],
                      ),
                    ),
                    for (var i = 0; i < list.length; i++)
                      ListTile(
                        leading: CircleAvatar(
                          child: Text(
                            list[i].number.isEmpty
                                ? '${i + 1}'
                                : list[i].number,
                          ),
                        ),
                        title: Text(
                          list[i].title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _play(list, i),
                      ),
                  ],
                ),
    );
  }
}

/// Player for movies and episodes: seek bar, resume, auto-next.
class VodPlayerPage extends StatefulWidget {
  final List<VodEntry> items;
  final int index;

  const VodPlayerPage({
    super.key,
    required this.items,
    required this.index,
  });

  @override
  State<VodPlayerPage> createState() => _VodPlayerPageState();
}

class _VodPlayerPageState extends State<VodPlayerPage> {
  late int _i = widget.index;
  VideoPlayerController? _c;
  bool _overlay = true;
  bool _advanced = false;
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
    _savePos();
    _c?.dispose();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _savePos() {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;

    final p = c.value.position.inMilliseconds;
    final d = c.value.duration.inMilliseconds;
    final key = _posKey;
    final v = (d > 0 && p > d - 15000) ? 0 : p;

    SharedPreferences.getInstance().then((x) => x.setInt(key, v));
  }

  Future<void> _open() async {
    final old = _c;
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
      final saved = prefs.getInt(_posKey) ?? 0;
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
    final t =
        (c.value.position.inMilliseconds + ms).clamp(0, dur).toInt();

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

  String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');

    final h = d.inHours;
    return h > 0
        ? '$h:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}'
        : '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
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
          onTap: () => _overlay
              ? setState(() => _overlay = false)
              : _showOverlay(),
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
              if (loading)
                const Center(child: CircularProgressIndicator()),
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
                            Text(_fmt(Duration(milliseconds: pos))),
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
                            Text(_fmt(Duration(milliseconds: dur))),
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
