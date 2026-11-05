
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class Channel {
  final String name, url, group, logo, streamId;
  const Channel(this.name, this.url, this.group, this.logo, {this.streamId = ''});
  String get id => url;
}

class Source {
  String name, type, url, user, pass;
  Source({
    required this.name,
    required this.type,
    required this.url,
    this.user = '',
    this.pass = '',
  });

  Map<String, dynamic> toJson() =>
      {'name': name, 'type': type, 'url': url, 'user': user, 'pass': pass};

  factory Source.fromJson(Map<String, dynamic> j) => Source(
        name: j['name'] ?? 'Playlist',
        type: j['type'] ?? 'm3u',
        url: j['url'] ?? '',
        user: j['user'] ?? '',
        pass: j['pass'] ?? '',
      );
}

class EpgItem {
  final String title;
  final DateTime start, stop;
  const EpgItem(this.title, this.start, this.stop);
}

final _adultRe = RegExp(r'(adult|xxx|porn|erotic|18\+|\+18)', caseSensitive: false);
bool isAdult(Channel c) => _adultRe.hasMatch('${c.group} ${c.name}');

List<Channel> parseM3u(String text) {
  final out = <Channel>[];
  String? name, group, logo;
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('#EXTINF')) {
      name = line.contains(',')
          ? line.substring(line.lastIndexOf(',') + 1).trim()
          : 'Channel';
      group = RegExp(r'group-title="([^"]*)"').firstMatch(line)?.group(1);
      logo = RegExp(r'tvg-logo="([^"]*)"').firstMatch(line)?.group(1);
    } else if (line.isNotEmpty && !line.startsWith('#') && name != null) {
      out.add(Channel(name, line, group ?? '', logo ?? ''));
      name = null;
    }
  }
  return out;
}

const _timeout = Duration(seconds: 30);

String _xtreamApi(Source s) {
  final base = s.url.replaceAll(RegExp(r'/+$'), '');
  return '$base/player_api.php'
      '?username=${Uri.encodeComponent(s.user)}'
      '&password=${Uri.encodeComponent(s.pass)}';
}

Future<List<Channel>> loadChannels(Source s) async {
  if (s.type == 'm3u') {
    final res = await http.get(Uri.parse(s.url)).timeout(_timeout);
    if (res.statusCode != 200) throw 'HTTP ${res.statusCode}';
    final list = parseM3u(utf8.decode(res.bodyBytes, allowMalformed: true));
    if (list.isEmpty) throw 'No channels found in this playlist';
    return list;
  }
  final base = s.url.replaceAll(RegExp(r'/+$'), '');
  final api = _xtreamApi(s);
  final cats = await http
      .get(Uri.parse('$api&action=get_live_categories'))
      .timeout(_timeout);
  final streams = await http
      .get(Uri.parse('$api&action=get_live_streams'))
      .timeout(_timeout);
  if (streams.statusCode != 200) throw 'HTTP ${streams.statusCode}';
  final catMap = <String, String>{};
  try {
    for (final c in jsonDecode(cats.body) as List) {
      catMap['${c['category_id']}'] = '${c['category_name']}';
    }
  } catch (_) {}
  final data = jsonDecode(streams.body);
  if (data is! List || data.isEmpty) throw 'Login failed or no channels';
  return [
    for (final x in data)
      Channel(
        '${x['name']}',
        '$base/live/${s.user}/${s.pass}/${x['stream_id']}.m3u8',
        catMap['${x['category_id']}'] ?? '',
        '${x['stream_icon'] ?? ''}',
        streamId: '${x['stream_id']}',
      )
  ];
}

Future<List<EpgItem>> loadEpg(Source s, Channel c) async {
  if (s.type != 'xtream' || c.streamId.isEmpty) return [];
  try {
    final res = await http
        .get(Uri.parse(
            '${_xtreamApi(s)}&action=get_short_epg&stream_id=${c.streamId}&limit=2'))
        .timeout(const Duration(seconds: 15));
    final list = (jsonDecode(res.body)['epg_listings'] as List?) ?? [];
    DateTime ts(dynamic v) =>
        DateTime.fromMillisecondsSinceEpoch(int.parse('$v') * 1000);
    return [
      for (final x in list)
        EpgItem(
          utf8.decode(base64.decode('${x['title']}'), allowMalformed: true),
          ts(x['start_timestamp']),
          ts(x['stop_timestamp']),
        )
    ];
  } catch (_) {
    return [];
  }
}

class Store {
  static Future<SharedPreferences> get _p => SharedPreferences.getInstance();

  static Future<List<Source>> sources() async {
    final s = (await _p).getString('sources');
    if (s == null) return [];
    return [for (final j in jsonDecode(s) as List) Source.fromJson(j)];
  }

  static Future<void> saveSources(List<Source> l) async => (await _p)
      .setString('sources', jsonEncode([for (final s in l) s.toJson()]));

  static Future<Set<String>> favs() async =>
      ((await _p).getStringList('favs') ?? []).toSet();

  static Future<void> saveFavs(Set<String> f) async =>
      (await _p).setStringList('favs', f.toList());

  static Future<int> active() async => (await _p).getInt('active') ?? 0;

  static Future<void> saveActive(int i) async => (await _p).setInt('active', i);

  static Future<String?> lastId() async => (await _p).getString('last');

  static Future<void> saveLast(String id) async => (await _p).setString('last', id);

  static Future<String?> pin() async => (await _p).getString('pin');

  static Future<void> savePin(String? v) async {
    final p = await _p;
    if (v == null) {
      await p.remove('pin');
    } else {
      await p.setString('pin', v);
    }
  }

  static Future<bool> adultLock() async =>
      (await _p).getBool('adult_lock') ?? false;

  static Future<void> saveAdultLock(bool v) async =>
      (await _p).setBool('adult_lock', v);
}

Future<String?> askPin(BuildContext context, String title) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        obscureText: true,
        maxLength: 4,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(hintText: '4 digits'),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('OK')),
      ],
    ),
  );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String? _pin;
  bool _lock = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _pin = await Store.pin();
    _lock = await Store.adultLock();
    if (mounted) setState(() {});
  }

  void _msg(String t) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<bool> _verify() async {
    final v = await askPin(context, 'Enter PIN');
    if (v == _pin) return true;
    if (v != null && mounted) _msg('Wrong PIN');
    return false;
  }

  Future<void> _setPin() async {
    final first = _pin == null;
    final a = await askPin(context, 'New PIN (4 digits)');
    if (a == null) return;
    if (a.length != 4) {
      if (mounted) _msg('PIN must be 4 digits');
      return;
    }
    if (!mounted) return;
    final b = await askPin(context, 'Repeat PIN');
    if (b == null) return;
    if (a != b) {
      if (mounted) _msg('PINs do not match');
      return;
    }
    await Store.savePin(a);
    if (first) await Store.saveAdultLock(true);
    await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(children: [
          if (_pin == null)
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('Set parental PIN'),
              subtitle:
                  const Text('Hides adult channels until you remove the lock'),
              onTap: _setPin,
            )
          else ...[
            SwitchListTile(
              secondary: const Icon(Icons.lock_outline),
              title: const Text('Hide adult channels'),
              subtitle: const Text('Turning this off requires the PIN'),
              value: _lock,
              onChanged: (v) async {
                if (!v && !await _verify()) return;
                await Store.saveAdultLock(v);
                await _load();
              },
            ),
            ListTile(
              leading: const Icon(Icons.pin_outlined),
              title: const Text('Change PIN'),
              onTap: () async {
                if (await _verify()) _setPin();
              },
            ),
            ListTile(
              leading: const Icon(Icons.lock_open),
              title: const Text('Remove PIN'),
              onTap: () async {
                if (await _verify()) {
                  await Store.savePin(null);
                  await Store.saveAdultLock(false);
                  await _load();
                }
              },
            ),
          ],
          const Divider(),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('MOKA IPTV'),
            subtitle:
                Text('Player only. Add your own playlist; no content is included.'),
          ),
        ]),
      );
}

class PlayerPage extends StatefulWidget {
  final List<Channel> channels;
  final int index;
  final Set<String> favs;
  final void Function(Channel) onFav;
  final Source? source;

  const PlayerPage({
    super.key,
    required this.channels,
    required this.index,
    required this.favs,
    required this.onFav,
    this.source,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late int _i = widget.index;
  VideoPlayerController? _c;
  bool _overlay = true;
  String? _err;
  List<EpgItem> _epg = [];
  Timer? _hide;

  Channel get _ch => widget.channels[_i];

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    _open();
  }

  @override
  void dispose() {
    _hide?.cancel();
    _c?.dispose();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _open() async {
    final old = _c;
    final c = VideoPlayerController.networkUrl(Uri.parse(_ch.url));
    final idx = _i;
    setState(() {
      _c = c;
      _err = null;
      _epg = [];
    });
    _showOverlay();
    Store.saveLast(_ch.id);
    final src = widget.source;
    if (src != null) {
      loadEpg(src, _ch).then((e) {
        if (mounted && _i == idx) setState(() => _epg = e);
      });
    }
    await old?.dispose();
    try {
      await c.initialize();
      if (!mounted || _c != c) return;
      c.addListener(_tick);
      await c.play();
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted && _c == c) setState(() => _err = 'Cannot play this channel');
    }
  }

  void _tick() {
    if (!mounted) return;
    if (_c?.value.hasError ?? false) {
      setState(() => _err = 'Stream error');
    } else {
      setState(() {});
    }
  }

  void _go(int d) {
    final n = widget.channels.length;
    _i = (_i + d + n) % n;
    _open();
  }

  void _togglePlay() {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    c.value.isPlaying ? c.pause() : c.play();
    _showOverlay();
  }

  void _showOverlay() {
    setState(() => _overlay = true);
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _overlay = false);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.channelUp) {
      _go(1);
    } else if (k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.channelDown) {
      _go(-1);
    } else if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.mediaPlayPause) {
      _togglePlay();
    } else if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight) {
      _showOverlay();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  String _t(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final ready = c != null && c.value.isInitialized && _err == null;
    final loading = _err == null &&
        (c == null || !c.value.isInitialized || c.value.isBuffering);
    final isFav = widget.favs.contains(_ch.id);

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () =>
              _overlay ? setState(() => _overlay = false) : _showOverlay(),
          onVerticalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (v < -200) _go(1);
            if (v > 200) _go(-1);
          },
          child: Stack(fit: StackFit.expand, children: [
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
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_err!, style: const TextStyle(fontSize: 18)),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _open, child: const Text('Retry')),
                ]),
              ),
            if (_overlay) ...[
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black54,
                  padding: const EdgeInsets.fromLTRB(4, 28, 4, 8),
                  child: Row(children: [
                    IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => Navigator.pop(context)),
                    Expanded(
                      child: Text(_ch.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 18)),
                    ),
                    IconButton(
                      icon: Icon(isFav ? Icons.star : Icons.star_border),
                      color: Colors.amber,
                      onPressed: () {
                        widget.onFav(_ch);
                        setState(() {});
                      },
                    ),
                  ]),
                ),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black54,
                  padding:
                      const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (_epg.isNotEmpty)
                      Text(
                        'Now: ${_epg[0].title}  (${_t(_epg[0].start)}–${_t(_epg[0].stop)})',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (_epg.length > 1)
                      Text(
                        'Next: ${_epg[1].title}  (${_t(_epg[1].start)})',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      IconButton(
                          iconSize: 36,
                          icon: const Icon(Icons.skip_previous),
                          onPressed: () => _go(-1)),
                      IconButton(
                        iconSize: 44,
                        icon: Icon((c?.value.isPlaying ?? false)
                            ? Icons.pause_circle
                            : Icons.play_circle),
                        onPressed: _togglePlay,
                      ),
                      IconButton(
                          iconSize: 36,
                          icon: const Icon(Icons.skip_next),
                          onPressed: () => _go(1)),
                    ]),
                  ]),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

// مهم: سيبنا اتجاه الشاشة تلقائي حسب الجهاز، من غير فرض portrait أو landscape.
void main() => runApp(const MokaApp());

class MokaApp extends StatelessWidget {
  const MokaApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'MOKA IPTV',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFC8742B), brightness: Brightness.dark),
        ),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _favKey = '★ Favorites';
  List<Source> _sources = [];
  int _active = 0;
  List<Channel> _channels = [];
  Set<String> _favs = {};
  String _group = 'All';
  String _query = '';
  String? _lastId;
  bool _hideAdult = false;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _sources = await Store.sources();
    _favs = await Store.favs();
    _active = await Store.active();
    _lastId = await Store.lastId();
    _hideAdult = await Store.adultLock();
    if (_active >= _sources.length) _active = 0;
    if (mounted) setState(() {});
    if (_sources.isNotEmpty) _load();
  }

  Future<void> _load() async {
    if (_sources.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await loadChannels(_sources[_active]);
      if (!mounted) return;
      setState(() {
        _channels = list;
        _group = 'All';
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _select(int i) async {
    _active = i;
    await Store.saveActive(i);
    _load();
  }

  void _toggleFav(Channel c) {
    setState(() {
      if (!_favs.remove(c.id)) _favs.add(c.id);
    });
    Store.saveFavs(_favs);
  }

  Future<void> _play(List<Channel> list, int i) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          channels: list,
          index: i,
          favs: _favs,
          onFav: _toggleFav,
          source: _sources[_active],
        ),
      ),
    );
    _lastId = await Store.lastId();
    if (mounted) setState(() {});
  }

  Future<void> _openSettings() async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const SettingsPage()));
    _hideAdult = await Store.adultLock();
    _group = 'All';
    if (mounted) setState(() {});
  }

  // نافذة إضافة الاشتراك: حجم أصغر مع الحفاظ على اتجاه الشاشة.
  Future<void> _addSource() async {
    final name = TextEditingController();
    final url = TextEditingController();
    final user = TextEditingController();
    final pass = TextEditingController();
    String type = 'm3u';

    final s = await showDialog<Source>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          scrollable: true,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 28,
            vertical: 18,
          ),
          titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          contentPadding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          actionsPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          title: const Text(
            'Add playlist',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          content: SizedBox(
            width: 260,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<String>(
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: WidgetStatePropertyAll(
                      TextStyle(fontSize: 12),
                    ),
                  ),
                  segments: const [
                    ButtonSegment(
                      value: 'm3u',
                      label: Text('M3U'),
                    ),
                    ButtonSegment(
                      value: 'xtream',
                      label: Text('Xtream'),
                    ),
                  ],
                  selected: {type},
                  onSelectionChanged: (v) => setD(() => type = v.first),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: name,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 9,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: url,
                  keyboardType: TextInputType.url,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    labelText: type == 'm3u'
                        ? 'Playlist URL'
                        : 'Server URL (http://host:port)',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 9,
                    ),
                  ),
                ),
                if (type == 'xtream') ...[
                  const SizedBox(height: 6),
                  TextField(
                    controller: user,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 9,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: pass,
                    obscureText: true,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 9,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(fontSize: 12)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              onPressed: () {
                if (url.text.trim().isEmpty) return;
                Navigator.pop(
                  ctx,
                  Source(
                    name: name.text.trim().isEmpty
                        ? 'Playlist'
                        : name.text.trim(),
                    type: type,
                    url: url.text.trim(),
                    user: user.text.trim(),
                    pass: pass.text.trim(),
                  ),
                );
              },
              child: const Text('Add', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );

    if (s == null) return;
    _sources.add(s);
    _active = _sources.length - 1;
    await Store.saveSources(_sources);
    await Store.saveActive(_active);
    _load();
  }

  void _manage() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setM) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < _sources.length; i++)
              ListTile(
                leading: Icon(i == _active
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off),
                title: Text(_sources[i].name),
                subtitle: Text(_sources[i].type.toUpperCase()),
                onTap: () {
                  Navigator.pop(ctx);
                  _select(i);
                },
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    final wasActive = i == _active;
                    _sources.removeAt(i);
                    if (i < _active) _active--;
                    if (_active >= _sources.length) _active = 0;
                    await Store.saveSources(_sources);
                    await Store.saveActive(_active);
                    setM(() {});
                    if (_sources.isEmpty) {
                      setState(() => _channels = []);
                    } else if (wasActive) {
                      _load();
                    } else {
                      setState(() {});
                    }
                  },
                ),
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Add playlist'),
              onTap: () {
                Navigator.pop(ctx);
                _addSource();
              },
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible =
        _hideAdult ? _channels.where((c) => !isAdult(c)).toList() : _channels;
    final groups = <String>{
      for (final c in visible)
        if (c.group.isNotEmpty) c.group
    }.toList()
      ..sort();
    final q = _query.toLowerCase();
    final shown = visible.where((c) {
      if (_group == _favKey && !_favs.contains(c.id)) return false;
      if (_group != 'All' && _group != _favKey && c.group != _group) {
        return false;
      }
      return c.name.toLowerCase().contains(q);
    }).toList();
    final lastIdx =
        _lastId == null ? -1 : visible.indexWhere((c) => c.id == _lastId);

    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('MOKA IPTV',
              style: TextStyle(fontWeight: FontWeight.bold)),
          if (_sources.isNotEmpty)
            Text(_sources[_active].name,
                style: Theme.of(context).textTheme.labelSmall),
        ]),
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _sources.isEmpty ? null : _load),
          IconButton(icon: const Icon(Icons.playlist_play), onPressed: _manage),
          IconButton(icon: const Icon(Icons.settings), onPressed: _openSettings),
        ],
      ),
      floatingActionButton: lastIdx >= 0
          ? FloatingActionButton.extended(
              onPressed: () => _play(visible, lastIdx),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Continue watching'),
            )
          : null,
      body: _sources.isEmpty
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.coffee, size: 72),
                const SizedBox(height: 8),
                Text('MOKA IPTV',
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 4),
                const Text('Add your playlist to start watching'),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _addSource,
                  icon: const Icon(Icons.add),
                  label: const Text('Add playlist'),
                ),
              ]),
            )
          : Column(children: [
              if (_loading) const LinearProgressIndicator(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.redAccent)),
                ),
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final g in ['All', _favKey, ...groups])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(g),
                          selected: _group == g,
                          onSelected: (_) => setState(() => _group = g),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: TextField(
                  decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search channels'),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              Expanded(
                child: shown.isEmpty && !_loading
                    ? const Center(child: Text('No channels'))
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 80),
                        itemCount: shown.length,
                        itemBuilder: (_, i) {
                          final c = shown[i];
                          return ListTile(
                            leading: SizedBox(
                              width: 44,
                              child: c.logo.isEmpty
                                  ? const Icon(Icons.tv)
                                  : Image.network(c.logo,
                                      errorBuilder: (_, __, ___) =>
                                          const Icon(Icons.tv)),
                            ),
                            title: Text(c.name,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: c.group.isEmpty
                                ? null
                                : Text(c.group, maxLines: 1),
                            trailing: IconButton(
                              icon: Icon(_favs.contains(c.id)
                                  ? Icons.star
                                  : Icons.star_border),
                              color: Colors.amber,
                              onPressed: () => _toggleFav(c),
                            ),
                            onTap: () => _play(shown, i),
                          );
                        },
                      ),
              ),
            ]),
    );
  }
}
