import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ================= MODELS =================

class Source {
  final String name, type, url, user, pass;
  const Source({required this.name, required this.type, required this.url,
    this.user = '', this.pass = ''});
  Map<String, dynamic> toJson() => {
    'name': name, 'type': type, 'url': url, 'user': user, 'pass': pass
  };
  factory Source.fromJson(Map<String, dynamic> j) => Source(
    name: '${j['name'] ?? 'Playlist'}', type: '${j['type'] ?? 'm3u'}',
    url: '${j['url'] ?? ''}', user: '${j['user'] ?? ''}',
    pass: '${j['pass'] ?? ''}');
}

class Channel {
  final String name, url, group, logo, streamId;
  const Channel(this.name, this.url, this.group, this.logo, {this.streamId = ''});
  String get id => url;
}

class MediaItem {
  final String id, name, category, poster, url, type;
  const MediaItem({required this.id, required this.name, required this.category,
    required this.poster, required this.url, required this.type});
}

class SeriesItem {
  final String id, name, category, poster, plot;
  const SeriesItem({required this.id, required this.name, required this.category,
    required this.poster, this.plot = ''});
}

class Episode {
  final String id, name, url;
  final int season, number;
  const Episode({required this.id, required this.name, required this.url,
    required this.season, required this.number});
}

class EpgItem {
  final String title;
  final DateTime start, stop;
  const EpgItem(this.title, this.start, this.stop);
}

class AccountInfo {
  final String username, status, expiry, created, maxConnections;
  final bool trial;
  const AccountInfo({required this.username, required this.status,
    required this.expiry, required this.created, required this.maxConnections,
    required this.trial});
}

// ================= API HELPERS =================

const _timeout = Duration(seconds: 35);
String _base(Source s) => s.url.trim().replaceAll(RegExp(r'/+$'), '');
String _api(Source s) => '${_base(s)}/player_api.php?username=${Uri.encodeComponent(s.user)}&password=${Uri.encodeComponent(s.pass)}';

String _streamExt(dynamic x) {
  final e = '${x ?? 'mp4'}'.trim().replaceAll('.', '');
  return e.isEmpty ? 'mp4' : e;
}
String _movieUrl(Source s, dynamic x) =>
    '${_base(s)}/movie/${Uri.encodeComponent(s.user)}/${Uri.encodeComponent(s.pass)}/${x['stream_id']}.${_streamExt(x['container_extension'])}';
String _episodeUrl(Source s, dynamic x) =>
    '${_base(s)}/series/${Uri.encodeComponent(s.user)}/${Uri.encodeComponent(s.pass)}/${x['id']}.${_streamExt(x['container_extension'])}';

Future<dynamic> _getJson(String url) async {
  final r = await http.get(Uri.parse(url)).timeout(_timeout);
  if (r.statusCode != 200) throw 'Server error: HTTP ${r.statusCode}';
  return jsonDecode(utf8.decode(r.bodyBytes, allowMalformed: true));
}

DateTime? _dateFrom(dynamic value) {
  final n = int.tryParse('${value ?? ''}');
  if (n == null || n <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(n * 1000);
}
String _dateText(DateTime? d) {
  if (d == null) return 'Not provided';
  return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

Future<AccountInfo?> loadAccount(Source s) async {
  if (s.type != 'xtream') return null;
  final data = await _getJson(_api(s));
  if (data is! Map) throw 'Invalid account response';
  final info = data['user_info'];
  if (info is! Map) throw 'Account information is unavailable';
  final status = '${info['status'] ?? 'Unknown'}';
  return AccountInfo(
    username: '${info['username'] ?? s.user}',
    status: status,
    expiry: _dateText(_dateFrom(info['exp_date'])),
    created: _dateText(_dateFrom(info['created_at'])),
    maxConnections: '${info['max_connections'] ?? 'Unknown'}',
    trial: '${info['is_trial'] ?? '0'}' == '1',
  );
}

final _adultRe = RegExp(r'(adult|xxx|porn|erotic|18\+|\+18)', caseSensitive: false);
bool _isAdult(Channel c) => _adultRe.hasMatch('${c.group} ${c.name}');

List<Channel> _parseM3u(String text) {
  final out = <Channel>[];
  String? name, group, logo;
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('#EXTINF')) {
      name = line.contains(',') ? line.substring(line.lastIndexOf(',') + 1).trim() : 'Channel';
      group = RegExp(r'group-title="([^"]*)"').firstMatch(line)?.group(1) ?? '';
      logo = RegExp(r'tvg-logo="([^"]*)"').firstMatch(line)?.group(1) ?? '';
    } else if (line.isNotEmpty && !line.startsWith('#') && name != null) {
      out.add(Channel(name, line, group ?? '', logo ?? ''));
      name = null;
    }
  }
  return out;
}

Future<List<Channel>> loadChannels(Source s) async {
  if (s.type == 'm3u') {
    final r = await http.get(Uri.parse(s.url)).timeout(_timeout);
    if (r.statusCode != 200) throw 'Playlist HTTP ${r.statusCode}';
    final list = _parseM3u(utf8.decode(r.bodyBytes, allowMalformed: true));
    if (list.isEmpty) throw 'No channels found in playlist';
    return list;
  }
  final results = await Future.wait([
    _getJson('${_api(s)}&action=get_live_categories'),
    _getJson('${_api(s)}&action=get_live_streams'),
  ]);
  final cats = <String, String>{};
  if (results[0] is List) {
    for (final c in results[0]) { cats['${c['category_id']}'] = '${c['category_name']}'; }
  }
  final data = results[1];
  if (data is! List || data.isEmpty) throw 'Login failed or no live channels';
  return [for (final x in data)
    Channel('${x['name'] ?? 'Channel'}',
      '${_base(s)}/live/${s.user}/${s.pass}/${x['stream_id']}.${_streamExt(x['container_extension'] ?? 'm3u8')}',
      cats['${x['category_id']}'] ?? 'Other', '${x['stream_icon'] ?? ''}',
      streamId: '${x['stream_id']}')];
}

Future<List<MediaItem>> loadMovies(Source s) async {
  if (s.type != 'xtream') return [];
  final r = await Future.wait([
    _getJson('${_api(s)}&action=get_vod_categories'),
    _getJson('${_api(s)}&action=get_vod_streams'),
  ]);
  final cats = <String, String>{};
  if (r[0] is List) for (final c in r[0]) { cats['${c['category_id']}'] = '${c['category_name']}'; }
  if (r[1] is! List) throw 'Invalid movies response';
  // Normalize provider dates to Unix seconds so seconds and milliseconds
  // are never mixed. When no date exists, use stream_id as a fallback.
  final rawMovies = List<dynamic>.from(r[1]);
  int? movieAddedAt(dynamic x) {
    if (x is! Map) return null;
    for (final key in ['added', 'last_modified']) {
      final raw = x[key];
      if (raw == null || '$raw'.trim().isEmpty || '$raw' == '0') continue;
      final numeric = int.tryParse('$raw');
      if (numeric != null) return numeric > 99999999999 ? numeric ~/ 1000 : numeric;
      final parsed = DateTime.tryParse('$raw');
      if (parsed != null) return parsed.millisecondsSinceEpoch ~/ 1000;
    }
    return null;
  }
  int movieSortKey(dynamic x) => movieAddedAt(x) ??
      (int.tryParse('${(x is Map ? x['stream_id'] : 0) ?? 0}') ?? 0);
  rawMovies.sort((a, b) {
    final byDate = movieSortKey(b).compareTo(movieSortKey(a));
    if (byDate != 0) return byDate;
    // Keep a deterministic newest-first fallback when dates are identical.
    final aId = int.tryParse('${a is Map ? a['stream_id'] ?? 0 : 0}') ?? 0;
    final bId = int.tryParse('${b is Map ? b['stream_id'] ?? 0 : 0}') ?? 0;
    return bId.compareTo(aId);
  });
  return [for (final x in rawMovies)
    MediaItem(id: '${x['stream_id']}', name: '${x['name'] ?? 'Movie'}',
      category: cats['${x['category_id']}'] ?? 'Other',
      poster: '${x['stream_icon'] ?? ''}', url: _movieUrl(s, x), type: 'movie')];
}

Future<List<SeriesItem>> loadSeries(Source s) async {
  if (s.type != 'xtream') return [];
  final r = await Future.wait([
    _getJson('${_api(s)}&action=get_series_categories'),
    _getJson('${_api(s)}&action=get_series'),
  ]);
  final cats = <String, String>{};
  if (r[0] is List) for (final c in r[0]) { cats['${c['category_id']}'] = '${c['category_name']}'; }
  if (r[1] is! List) throw 'Invalid series response';
  return [for (final x in r[1])
    SeriesItem(id: '${x['series_id']}', name: '${x['name'] ?? 'Series'}',
      category: cats['${x['category_id']}'] ?? 'Other',
      poster: '${x['cover'] ?? ''}', plot: '${x['plot'] ?? ''}')];
}

Future<List<Episode>> loadEpisodes(Source s, String id) async {
  final d = await _getJson('${_api(s)}&action=get_series_info&series_id=$id');
  final out = <Episode>[];
  final seasons = d is Map ? d['episodes'] : null;
  if (seasons is Map) {
    for (final entry in seasons.entries) {
      final season = int.tryParse('${entry.key}') ?? 1;
      if (entry.value is! List) continue;
      for (final x in entry.value) {
        out.add(Episode(id: '${x['id']}', name: '${x['title'] ?? 'Episode ${x['episode_num'] ?? ''}'}',
          url: _episodeUrl(s, x), season: season,
          number: int.tryParse('${x['episode_num']}') ?? 0));
      }
    }
  }
  out.sort((a,b) => a.season != b.season ? a.season.compareTo(b.season) : a.number.compareTo(b.number));
  return out;
}

Future<List<EpgItem>> loadEpg(Source s, Channel c) async {
  if (s.type != 'xtream' || c.streamId.isEmpty) return [];
  try {
    final d = await _getJson('${_api(s)}&action=get_short_epg&stream_id=${c.streamId}&limit=2');
    final list = d is Map ? (d['epg_listings'] as List? ?? []) : [];
    DateTime ts(dynamic v) => DateTime.fromMillisecondsSinceEpoch((int.tryParse('$v') ?? 0) * 1000);
    return [for (final x in list) EpgItem(
      utf8.decode(base64.decode('${x['title']}'), allowMalformed: true),
      ts(x['start_timestamp']), ts(x['stop_timestamp']))];
  } catch (_) { return []; }
}

// ================= LOCAL STORAGE =================

class Store {
  static Future<SharedPreferences> get p => SharedPreferences.getInstance();
  static Future<List<Source>> sources() async {
    final raw = (await p).getString('sources');
    if (raw == null || raw.isEmpty) return [];
    try { return [for (final x in jsonDecode(raw)) Source.fromJson(x)]; } catch (_) { return []; }
  }
  static Future<void> saveSources(List<Source> v) async =>
      (await p).setString('sources', jsonEncode([for (final s in v) s.toJson()]));
  static Future<int> active() async => (await p).getInt('active') ?? 0;
  static Future<void> saveActive(int v) async => (await p).setInt('active', v);
  static Future<Set<String>> favs() async => ((await p).getStringList('favs') ?? []).toSet();
  static Future<void> saveFavs(Set<String> v) async => (await p).setStringList('favs', v.toList());
  static Future<Set<String>> mediaFavs() async => ((await p).getStringList('media_favs') ?? []).toSet();
  static Future<void> saveMediaFavs(Set<String> v) async => (await p).setStringList('media_favs', v.toList());
  static Future<int> progress(String id) async => (await p).getInt('progress_$id') ?? 0;
  static Future<void> saveProgress(String id, int ms) async => (await p).setInt('progress_$id', ms);
  static Future<String?> lastId() async => (await p).getString('last');
  static Future<void> saveLast(String id) async => (await p).setString('last', id);
  static Future<String?> pin() async => (await p).getString('pin');
  static Future<void> savePin(String? v) async {
    final prefs = await p;
    if (v == null) { await prefs.remove('pin'); } else { await prefs.setString('pin', v); }
  }
  static Future<bool> adultLock() async => (await p).getBool('adult_lock') ?? false;
  static Future<void> saveAdultLock(bool v) async => (await p).setBool('adult_lock', v);
  static Future<void> logout() async {
    final prefs = await p;
    await prefs.remove('sources');
    await prefs.remove('active');
    await prefs.remove('last');
    // Remove account-specific viewing progress; keep parental controls and favorites.
    for (final key in prefs.getKeys().where((k) => k.startsWith('progress_')).toList()) {
      await prefs.remove(key);
    }
  }
}

// ================= COMMON UI =================

void _message(BuildContext c, String message) {
  ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(message)));
}

Future<String?> _askPin(BuildContext context, String title) {
  final c = TextEditingController();
  return showDialog<String>(context: context, builder: (ctx) => AlertDialog(
    title: Text(title),
    content: TextField(controller: c, autofocus: true, obscureText: true,
      maxLength: 4, keyboardType: TextInputType.number,
      decoration: const InputDecoration(hintText: '4 digits')),
    actions: [
      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('OK')),
    ],
  ));
}

class Poster extends StatelessWidget {
  final String url;
  final IconData fallback;
  const Poster(this.url, {super.key, this.fallback = Icons.movie});
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: url.isEmpty
      ? Container(color: Colors.white10, child: Icon(fallback, size: 42))
      : Image.network(url, fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(color: Colors.white10, child: Icon(fallback, size: 42))),
  );
}

// ================= LOGIN =================

class LoginPage extends StatefulWidget {
  final Future<void> Function(Source) onLogin;
  const LoginPage({super.key, required this.onLogin});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _name = TextEditingController(text: 'My Playlist');
  final _server = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  String _type = 'xtream';
  bool _busy = false, _hidePass = true;

  @override
  void dispose() {
    _name.dispose(); _server.dispose(); _user.dispose(); _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_server.text.trim().isEmpty) { _message(context, 'Enter server URL'); return; }
    if (_type == 'xtream' && (_user.text.trim().isEmpty || _pass.text.isEmpty)) {
      _message(context, 'Enter username and password'); return;
    }
    final s = Source(name: _name.text.trim().isEmpty ? 'My Playlist' : _name.text.trim(),
      type: _type, url: _server.text.trim(), user: _user.text.trim(), pass: _pass.text);
    setState(() => _busy = true);
    try {
      await widget.onLogin(s);
    } catch (e) {
      if (mounted) _message(context, '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(child: SingleChildScrollView(
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 650),
        child: Card(margin: const EdgeInsets.all(10), child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.live_tv, size: 34, color: Color(0xFFC8742B)),
            const SizedBox(height: 2),
            const Text('MOKA IPTV', style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'xtream', label: Text('Xtream')),
                ButtonSegment(value: 'm3u', label: Text('M3U')),
              ],
              selected: {_type}, onSelectionChanged: (v) => setState(() => _type = v.first)),
            const SizedBox(height: 6),
            TextField(controller: _name, decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10), labelText: 'Playlist name', prefixIcon: Icon(Icons.label))),
            const SizedBox(height: 6),
            TextField(controller: _server, keyboardType: TextInputType.url,
              decoration: InputDecoration(isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), labelText: _type == 'xtream' ? 'Server URL' : 'M3U playlist URL', prefixIcon: const Icon(Icons.link))),
            if (_type == 'xtream') ...[
              const SizedBox(height: 6),
              TextField(controller: _user, decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10), labelText: 'Username', prefixIcon: Icon(Icons.person))),
              const SizedBox(height: 6),
              TextField(controller: _pass, obscureText: _hidePass,
                decoration: InputDecoration(isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), labelText: 'Password', prefixIcon: const Icon(Icons.lock),
                  suffixIcon: IconButton(icon: Icon(_hidePass ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _hidePass = !_hidePass)))),
            ],
            const SizedBox(height: 9),
            SizedBox(width: double.infinity, child: FilledButton.icon(
              onPressed: _busy ? null : _submit,
              icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.login),
              label: Text(_busy ? 'Connecting...' : 'Login'))),
          ]),
        )),
      ),
    )),
  );
}

// ================= SETTINGS & ACCOUNT =================

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}
class _SettingsPageState extends State<SettingsPage> {
  String? _pin;
  bool _lock = false;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    _pin = await Store.pin(); _lock = await Store.adultLock();
    if (mounted) setState(() {});
  }
  Future<bool> _verify() async {
    final v = await _askPin(context, 'Enter PIN');
    if (v == _pin) return true;
    if (v != null && mounted) _message(context, 'Wrong PIN');
    return false;
  }
  Future<void> _setPin() async {
    final a = await _askPin(context, 'New PIN (4 digits)');
    if (a == null) return;
    if (a.length != 4) { _message(context, 'PIN must be 4 digits'); return; }
    if (!mounted) return;
    final b = await _askPin(context, 'Repeat PIN');
    if (b == null) return;
    if (a != b) { _message(context, 'PINs do not match'); return; }
    await Store.savePin(a);
    await Store.saveAdultLock(true);
    await _load();
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: ListView(children: [
      if (_pin == null)
        ListTile(leading: const Icon(Icons.lock), title: const Text('Set parental PIN'),
          subtitle: const Text('Hide adult channels'), onTap: _setPin)
      else ...[
        SwitchListTile(title: const Text('Hide adult channels'), value: _lock,
          secondary: const Icon(Icons.visibility_off),
          onChanged: (v) async { if (!v && !await _verify()) return; await Store.saveAdultLock(v); await _load(); }),
        ListTile(title: const Text('Change PIN'), leading: const Icon(Icons.pin),
          onTap: () async { if (await _verify()) await _setPin(); }),
        ListTile(title: const Text('Remove PIN'), leading: const Icon(Icons.lock_open),
          onTap: () async { if (await _verify()) { await Store.savePin(null); await Store.saveAdultLock(false); await _load(); } }),
      ],
      const Divider(),
      const ListTile(leading: Icon(Icons.info_outline), title: Text('MOKA IPTV'),
        subtitle: Text('Your personal IPTV player')),
    ]),
  );
}

class AccountPage extends StatefulWidget {
  final Source source;
  const AccountPage({super.key, required this.source});
  @override
  State<AccountPage> createState() => _AccountPageState();
}
class _AccountPageState extends State<AccountPage> {
  AccountInfo? _info;
  bool _loading = true;
  String? _error;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try { _info = await loadAccount(widget.source); }
    catch (e) { _error = '$e'; }
    if (mounted) setState(() => _loading = false);
  }
  Widget _line(String title, String value, IconData icon) => ListTile(
    leading: Icon(icon), title: Text(title), trailing: Text(value, style: const TextStyle(fontWeight: FontWeight.w600)));
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Account & Subscription'),
      actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))]),
    body: _loading ? const Center(child: CircularProgressIndicator())
      : _error != null ? Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(_error!, textAlign: TextAlign.center)))
      : _info == null ? const Center(child: Text('Account details are available for Xtream subscriptions only'))
      : ListView(padding: const EdgeInsets.all(12), children: [
        const SizedBox(height: 10),
        const Icon(Icons.account_circle, size: 76, color: Color(0xFFC8742B)),
        const SizedBox(height: 10),
        Center(child: Text(_info!.username, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold))),
        const SizedBox(height: 18),
        Card(child: Column(children: [
          _line('Account status', _info!.status, Icons.verified_user),
          _line('Expiry date', _info!.expiry, Icons.event),
          _line('Created at', _info!.created, Icons.calendar_month),
          _line('Max connections', _info!.maxConnections, Icons.devices),
          _line('Trial account', _info!.trial ? 'Yes' : 'No', Icons.hourglass_empty),
        ])),
        const Padding(padding: EdgeInsets.all(8), child: Text('Subscription details are supplied by your IPTV provider.')),
      ]),
  );
}

// ================= VIDEO PLAYERS =================

class LivePlayerPage extends StatefulWidget {
  final List<Channel> channels;
  final int index;
  final Set<String> favorites;
  final void Function(Channel) onFavorite;
  final Source source;
  const LivePlayerPage({super.key, required this.channels, required this.index,
    required this.favorites, required this.onFavorite, required this.source});
  @override
  State<LivePlayerPage> createState() => _LivePlayerPageState();
}
class _LivePlayerPageState extends State<LivePlayerPage> {
  late int _index = widget.index;
  VideoPlayerController? _controller;
  Timer? _hideTimer;
  bool _overlay = true;
  String? _error;
  List<EpgItem> _epg = [];
  Channel get _channel => widget.channels[_index];

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    _open();
  }
  @override
  void dispose() {
    _hideTimer?.cancel(); _controller?.dispose(); WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }
  Future<void> _open() async {
    final old = _controller;
    final c = VideoPlayerController.networkUrl(Uri.parse(_channel.url));
    final current = _index;
    setState(() { _controller = c; _error = null; _epg = []; });
    _showOverlay();
    Store.saveLast(_channel.id);
    loadEpg(widget.source, _channel).then((v) {
      if (mounted && _index == current) setState(() => _epg = v);
    });
    await old?.dispose();
    try {
      await c.initialize();
      if (!mounted || _controller != c) return;
      c.addListener(_tick);
      await c.play();
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted && _controller == c) setState(() => _error = 'Cannot play this channel');
    }
  }
  void _tick() {
    if (!mounted) return;
    if (_controller?.value.hasError ?? false) setState(() => _error = 'Stream error');
    else setState(() {});
  }
  void _change(int d) { _index = (_index + d + widget.channels.length) % widget.channels.length; _open(); }
  void _toggle() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    c.value.isPlaying ? c.pause() : c.play(); _showOverlay();
  }
  void _showOverlay() {
    if (!mounted) return;
    setState(() => _overlay = true);
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () { if (mounted) setState(() => _overlay = false); });
  }
  KeyEventResult _key(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.channelUp) _change(1);
    else if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.channelDown) _change(-1);
    else if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.mediaPlayPause) _toggle();
    else if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) _showOverlay();
    else return KeyEventResult.ignored;
    return KeyEventResult.handled;
  }
  String _clock(DateTime d) => '${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final ready = c != null && c.value.isInitialized && _error == null;
    final fav = widget.favorites.contains(_channel.id);
    return Focus(autofocus: true, onKeyEvent: _key, child: Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _overlay ? setState(() => _overlay = false) : _showOverlay(),
        onVerticalDragEnd: (d) { final v = d.primaryVelocity ?? 0; if (v < -200) _change(1); if (v > 200) _change(-1); },
        child: Stack(fit: StackFit.expand, children: [
          if (ready) Center(child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c))),
          if (_error == null && !ready) const Center(child: CircularProgressIndicator()),
          if (_error != null) Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!), const SizedBox(height: 12), FilledButton(onPressed: _open, child: const Text('Retry'))])),
          if (_overlay) ...[
            Positioned(top: 0, left: 0, right: 0, child: Container(color: Colors.black54,
              padding: const EdgeInsets.fromLTRB(4, 26, 4, 6), child: Row(children: [
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back)),
                Expanded(child: Text(_channel.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                IconButton(onPressed: () { widget.onFavorite(_channel); setState(() {}); },
                  icon: Icon(fav ? Icons.star : Icons.star_border), color: Colors.amber),
              ]))),
            Positioned(bottom: 0, left: 0, right: 0, child: Container(color: Colors.black54,
              padding: const EdgeInsets.all(10), child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (_epg.isNotEmpty) Text('Now: ${_epg[0].title} (${_clock(_epg[0].start)}–${_clock(_epg[0].stop)})', maxLines: 1, overflow: TextOverflow.ellipsis),
                if (_epg.length > 1) Text('Next: ${_epg[1].title} (${_clock(_epg[1].start)})', maxLines: 1, overflow: TextOverflow.ellipsis),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  IconButton(iconSize: 36, onPressed: () => _change(-1), icon: const Icon(Icons.skip_previous)),
                  IconButton(iconSize: 46, onPressed: _toggle, icon: Icon((c?.value.isPlaying ?? false) ? Icons.pause_circle : Icons.play_circle)),
                  IconButton(iconSize: 36, onPressed: () => _change(1), icon: const Icon(Icons.skip_next)),
                ]),
              ]))),
          ],
        ]),
      ),
    ));
  }
}

class MediaPlayerPage extends StatefulWidget {
  final String name, url, id;
  const MediaPlayerPage({super.key, required this.name, required this.url, required this.id});
  @override
  State<MediaPlayerPage> createState() => _MediaPlayerPageState();
}

class _MediaPlayerPageState extends State<MediaPlayerPage> {
  VideoPlayerController? _c;
  Timer? _timer;
  Timer? _controlsTimer;
  bool _controlsVisible = true;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    _start();
  }

  Future<void> _start() async {
    final c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _c = c;
    try {
      await c.initialize();
      if (!mounted || _c != c) return;
      final saved = await Store.progress(widget.id);
      if (saved > 0 && saved < c.value.duration.inMilliseconds - 10000) {
        await c.seekTo(Duration(milliseconds: saved));
      }
      await c.play();
      _scheduleControlsHide();
      c.addListener(_changed);
      _timer = Timer.periodic(const Duration(seconds: 5), (_) => _save());
      if (mounted) setState(() => _loading = false);
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = 'Unable to play this video'; });
    }
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      final c = _c;
      if (c != null && c.value.isPlaying) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleControlsHide();
    else _controlsTimer?.cancel();
  }

  void _changed() {
    if (!mounted) return;
    final c = _c;
    if (c != null && c.value.hasError) {
      setState(() => _error = 'Video playback error');
    } else {
      setState(() {});
    }
  }

  Future<void> _save() async {
    final c = _c;
    if (c != null && c.value.isInitialized) {
      await Store.saveProgress(widget.id, c.value.position.inMilliseconds);
    }
  }

  String _time(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.inHours)}:${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}';
  }

  Future<void> _seekBy(int seconds) async {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    final target = c.value.position + Duration(seconds: seconds);
    final duration = c.value.duration;
    await c.seekTo(target < Duration.zero ? Duration.zero : (target > duration ? duration : target));
  }

  Future<void> _seekFromCircularDrag(Offset local, Size size) async {
    final c = _c;
    if (c == null || !c.value.isInitialized || c.value.duration.inMilliseconds <= 0) return;
    final dx = local.dx - size.width / 2;
    final dy = local.dy - size.height / 2;
    var angle = math.atan2(dy, dx) + math.pi / 2;
    if (angle < 0) angle += 2 * math.pi;
    final fraction = (angle / (2 * math.pi)).clamp(0.0, 1.0);
    final targetMs = (c.value.duration.inMilliseconds * fraction).round();
    await c.seekTo(Duration(milliseconds: targetMs));
  }

  Future<void> _togglePlayback() async {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      await c.pause();
      _controlsTimer?.cancel();
    } else {
      await c.play();
      _controlsVisible = true;
      _scheduleControlsHide();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controlsTimer?.cancel();
    _save();
    _c?.removeListener(_changed);
    _c?.dispose();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final ready = c != null && c.value.isInitialized;
    return Scaffold(
      backgroundColor: Colors.black,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!, style: const TextStyle(color: Colors.white)),
                  const SizedBox(height: 12),
                  FilledButton.icon(onPressed: () {
                    setState(() { _loading = true; _error = null; });
                    _c?.removeListener(_changed);
                    _c?.dispose();
                    _start();
                  }, icon: const Icon(Icons.refresh), label: const Text('Retry')),
                ]))
              : !ready
                  ? const Center(child: CircularProgressIndicator())
                  : LayoutBuilder(builder: (context, bounds) {
                      final compact = bounds.maxHeight < 430 || bounds.maxWidth < 700;
                      final ratio = c.value.aspectRatio > 0 ? c.value.aspectRatio : 16 / 9;
                      return Stack(fit: StackFit.expand, children: [
                        // Keep the video fitted inside the available screen area.
                        Center(child: AspectRatio(
                          aspectRatio: ratio,
                          child: VideoPlayer(c),
                        )),
                        Positioned.fill(child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTap: _toggleControls,
                          child: const SizedBox.expand(),
                        )),
                        if (_controlsVisible) Positioned(
                          top: 0, left: 0, right: 0,
                          child: SafeArea(bottom: false, child: Container(
                            color: Colors.black.withOpacity(.72),
                            padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 18, vertical: 2),
                            child: Row(children: [
                              IconButton(
                                tooltip: 'Back',
                                onPressed: () => Navigator.maybePop(context),
                                icon: const Icon(Icons.arrow_back, color: Colors.white),
                              ),
                              Expanded(child: Text(widget.name, maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: Colors.white, fontSize: compact ? 14 : 19))),
                            ]),
                          )),
                        ),
                        // Solid, always-visible playback panel for phones and TVs.
                        if (_controlsVisible) Positioned(
                          left: 0, right: 0, bottom: 0,
                          child: SafeArea(top: false, child: Container(
                            color: Colors.black.withOpacity(.88),
                            padding: EdgeInsets.fromLTRB(compact ? 8 : 30, compact ? 5 : 10,
                              compact ? 8 : 30, compact ? 2 : 8),
                            child: Center(child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 1200),
                              child: Column(mainAxisSize: MainAxisSize.min, children: [
                                Row(children: [
                                  Text(_time(c.value.position),
                                    style: TextStyle(color: Colors.white, fontSize: compact ? 10 : 14)),
                                  const Spacer(),
                                  IconButton(
                                    tooltip: 'رجوع 10 ثواني',
                                    visualDensity: VisualDensity.compact,
                                    iconSize: compact ? 30 : 42,
                                    onPressed: () => _seekBy(-10),
                                    icon: const Icon(Icons.replay_10, color: Colors.white),
                                  ),
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onPanDown: (details) => _seekFromCircularDrag(
                                      details.localPosition, Size(compact ? 54 : 68, compact ? 54 : 68)),
                                    onPanUpdate: (details) => _seekFromCircularDrag(
                                      details.localPosition, Size(compact ? 54 : 68, compact ? 54 : 68)),
                                    child: SizedBox(
                                      width: compact ? 54 : 68,
                                      height: compact ? 54 : 68,
                                      child: Stack(alignment: Alignment.center, children: [
                                        SizedBox.expand(child: CircularProgressIndicator(
                                          value: c.value.duration.inMilliseconds > 0
                                              ? (c.value.position.inMilliseconds / c.value.duration.inMilliseconds).clamp(0.0, 1.0)
                                              : 0,
                                          strokeWidth: compact ? 3 : 4,
                                          backgroundColor: Colors.white30,
                                          valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFC8742B)),
                                        )),
                                        IconButton(
                                          tooltip: c.value.isPlaying ? 'إيقاف مؤقت' : 'تشغيل',
                                          visualDensity: VisualDensity.compact,
                                          iconSize: compact ? 38 : 50,
                                          onPressed: _togglePlayback,
                                          icon: Icon(c.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                                            color: Colors.white),
                                        ),
                                      ]),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'تقديم 10 ثواني',
                                    visualDensity: VisualDensity.compact,
                                    iconSize: compact ? 30 : 42,
                                    onPressed: () => _seekBy(10),
                                    icon: const Icon(Icons.forward_10, color: Colors.white),
                                  ),
                                  const Spacer(),
                                  Text(_time(c.value.duration),
                                    style: TextStyle(color: Colors.white, fontSize: compact ? 10 : 14)),
                                ]),
                              ]),
                            )),
                          )),
                        ),
                      ]);
                    }),
    );
  }
}

// ================= MOVIES GRID =================

class MediaGridPage extends StatefulWidget {
  final String title;
  final List<MediaItem> items;
  final Set<String> favorites;
  final Future<void> Function(MediaItem) onPlay;
  final void Function(MediaItem) onFavorite;
  const MediaGridPage({super.key, required this.title, required this.items,
    required this.favorites, required this.onPlay, required this.onFavorite});
  @override
  State<MediaGridPage> createState() => _MediaGridPageState();
}
class _MediaGridPageState extends State<MediaGridPage> {
  String _category = 'All', _query = '';
  bool _onlyFav = false;
  @override
  Widget build(BuildContext context) {
    final cats = <String>{for (final x in widget.items) if (x.category.isNotEmpty) x.category}.toList()..sort();
    final list = widget.items.where((x) =>
      (!_onlyFav || widget.favorites.contains('movie_${x.id}') || widget.favorites.contains(x.id)) &&
      (_category == 'All' || x.category == _category) &&
      x.name.toLowerCase().contains(_query.toLowerCase())).toList();
    return Column(children: [
      Align(alignment: Alignment.centerRight, child: IconButton(tooltip: 'Favorites only', onPressed: () => setState(() => _onlyFav = !_onlyFav),
        icon: Icon(_onlyFav ? Icons.star : Icons.star_border), color: Colors.amber)),
      Expanded(child: Row(children: [
      Container(width: 190, decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface,
        border: Border(right: BorderSide(color: Theme.of(context).dividerColor))),
        child: ListView(padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          children: [for (final cat in ['All', ...cats]) Padding(padding: const EdgeInsets.only(bottom: 6),
            child: ChoiceChip(label: SizedBox(width: double.infinity, child: Text(cat, maxLines: 1, overflow: TextOverflow.ellipsis)),
              selected: _category == cat, onSelected: (_) => setState(() => _category = cat))) ])),
      Expanded(child: Column(children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search movies', isDense: true),
            onChanged: (v) => setState(() => _query = v))),
        Expanded(child: list.isEmpty ? const Center(child: Text('No movies found'))
          : LayoutBuilder(builder: (context, box) {
            final count = (box.maxWidth / 145).floor().clamp(3, 9).toInt();
            return GridView.builder(padding: const EdgeInsets.all(10),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: count,
                childAspectRatio: .68, crossAxisSpacing: 10, mainAxisSpacing: 10),
              itemCount: list.length, itemBuilder: (_, i) {
                final x = list[i];
                final fav = widget.favorites.contains('movie_${x.id}') || widget.favorites.contains(x.id);
                return InkWell(onTap: () => widget.onPlay(x), child: Column(children: [
                  Expanded(child: Stack(fit: StackFit.expand, children: [
                    Poster(x.poster),
                    Positioned(top: 2, right: 2, child: IconButton(
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(backgroundColor: Colors.black54),
                      onPressed: () { widget.onFavorite(x); setState(() {}); },
                      icon: Icon(fav ? Icons.star : Icons.star_border, color: Colors.amber))),
                  ])),
                  const SizedBox(height: 5),
                  Text(x.name, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12)),
                ]));
              });
          })),
      ])),
    ])),
    ]);
  }
}

class SeriesBrowserPage extends StatefulWidget {
  final List<SeriesItem> items;
  final Source source;
  final Set<String> favorites;
  final void Function(String) onFavorite;
  const SeriesBrowserPage({super.key, required this.items, required this.source,
    required this.favorites, required this.onFavorite});
  @override
  State<SeriesBrowserPage> createState() => _SeriesBrowserPageState();
}
class _SeriesBrowserPageState extends State<SeriesBrowserPage> {
  String _category = 'All', _query = '';
  bool _onlyFav = false;
  @override
  Widget build(BuildContext context) {
    final cats = <String>{for (final x in widget.items) if (x.category.isNotEmpty) x.category}.toList()..sort();
    final list = widget.items.where((x) =>
      (!_onlyFav || widget.favorites.contains('series_${x.id}')) &&
      (_category == 'All' || x.category == _category) &&
      x.name.toLowerCase().contains(_query.toLowerCase())).toList();
    return Column(children: [
      Align(alignment: Alignment.centerRight, child: IconButton(tooltip: 'Favorites only', onPressed: () => setState(() => _onlyFav = !_onlyFav),
        icon: Icon(_onlyFav ? Icons.star : Icons.star_border), color: Colors.amber)),
      Expanded(child: Row(children: [
      Container(width: 190, decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface,
        border: Border(right: BorderSide(color: Theme.of(context).dividerColor))),
        child: ListView(padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          children: [for (final cat in ['All', ...cats]) Padding(padding: const EdgeInsets.only(bottom: 6),
            child: ChoiceChip(label: SizedBox(width: double.infinity, child: Text(cat, maxLines: 1, overflow: TextOverflow.ellipsis)),
              selected: _category == cat, onSelected: (_) => setState(() => _category = cat))) ])),
      Expanded(child: Column(children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search series', isDense: true),
            onChanged: (v) => setState(() => _query = v))),
        Expanded(child: list.isEmpty ? const Center(child: Text('No series found'))
          : LayoutBuilder(builder: (context, box) {
            final count = (box.maxWidth / 145).floor().clamp(3, 9).toInt();
            return GridView.builder(padding: const EdgeInsets.all(10),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: count,
                childAspectRatio: .68, crossAxisSpacing: 10, mainAxisSpacing: 10),
              itemCount: list.length, itemBuilder: (_, i) {
                final item = list[i]; final fav = widget.favorites.contains('series_${item.id}');
                return InkWell(onTap: () => Navigator.push(context, MaterialPageRoute(
                  builder: (_) => SeriesDetailsPage(series: item, source: widget.source,
                    favorites: widget.favorites, onFavorite: widget.onFavorite))),
                  child: Column(children: [
                    Expanded(child: Stack(fit: StackFit.expand, children: [
                      Poster(item.poster, fallback: Icons.tv),
                      Positioned(top: 2, right: 2, child: IconButton(
                        visualDensity: VisualDensity.compact,
                        style: IconButton.styleFrom(backgroundColor: Colors.black54),
                        onPressed: () { widget.onFavorite(item.id); setState(() {}); },
                        icon: Icon(fav ? Icons.star : Icons.star_border, color: Colors.amber))),
                    ])),
                    const SizedBox(height: 5),
                    Text(item.name, maxLines: 2, textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                  ]));
              });
          })),
      ])),
    ])),
    ]);
  }
}

class SeriesDetailsPage extends StatefulWidget {
  final SeriesItem series;
  final Source source;
  final Set<String> favorites;
  final void Function(String) onFavorite;
  const SeriesDetailsPage({super.key, required this.series, required this.source,
    required this.favorites, required this.onFavorite});
  @override
  State<SeriesDetailsPage> createState() => _SeriesDetailsPageState();
}
class _SeriesDetailsPageState extends State<SeriesDetailsPage> {
  List<Episode> _episodes = [];
  bool _loading = true;
  String? _error;
  int? _season;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { final v = await loadEpisodes(widget.source, widget.series.id);
      if (mounted) setState(() { _episodes = v; _loading = false; });
    } catch (e) { if (mounted) setState(() { _error = '$e'; _loading = false; }); }
  }
  @override
  Widget build(BuildContext context) {
    final seasons = _episodes.map((e) => e.season).toSet().toList()..sort();
    final visible = _season == null ? _episodes : _episodes.where((e) => e.season == _season).toList();
    final fav = widget.favorites.contains('series_${widget.series.id}');

    Widget seasonPicker() => SizedBox(height: 44, child: ListView(
      scrollDirection: Axis.horizontal,
      children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: ChoiceChip(
          label: const Text('All seasons'), selected: _season == null,
          onSelected: (_) => setState(() => _season = null))),
        for (final n in seasons) Padding(padding: const EdgeInsets.symmetric(horizontal: 4),
          child: ChoiceChip(label: Text('Part / Season $n'), selected: _season == n,
            onSelected: (_) => setState(() => _season = n))),
      ],
    ));

    Widget episodeList() => Expanded(child: _loading
      ? const Center(child: CircularProgressIndicator())
      : _error != null ? Center(child: Text(_error!))
      : visible.isEmpty ? const Center(child: Text('No episodes found'))
      : ListView.builder(itemCount: visible.length, itemBuilder: (_, i) {
          final ep = visible[i];
          return ListTile(dense: true, leading: const Icon(Icons.play_circle_outline),
            title: Text(ep.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text('Part / Season ${ep.season} • Episode ${ep.number}'),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) =>
              MediaPlayerPage(name: ep.name, url: ep.url, id: 'episode_${ep.id}'))));
        }));

    return Scaffold(appBar: AppBar(title: Text(widget.series.name), actions: [
      IconButton(onPressed: () { widget.onFavorite(widget.series.id); setState(() {}); },
        icon: Icon(fav ? Icons.star : Icons.star_border), color: Colors.amber),
    ]), body: LayoutBuilder(builder: (context, constraints) {
      final landscape = constraints.maxWidth > constraints.maxHeight;
      final details = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (widget.series.poster.isNotEmpty)
          SizedBox(height: landscape ? 105 : 135, child: Padding(padding: const EdgeInsets.all(6),
            child: Poster(widget.series.poster, fallback: Icons.tv))),
        if (widget.series.plot.isNotEmpty)
          Padding(padding: const EdgeInsets.all(8), child: Text(widget.series.plot,
            maxLines: landscape ? 2 : 3, overflow: TextOverflow.ellipsis)),
      ]);
      if (landscape) {
        return Row(children: [
          SizedBox(width: (constraints.maxWidth * .34).clamp(190.0, 330.0), child: details),
          const VerticalDivider(width: 1),
          Expanded(child: Column(children: [
            if (!_loading && seasons.isNotEmpty) seasonPicker(),
            episodeList(),
          ])),
        ]);
      }
      return Column(children: [details, if (!_loading && seasons.isNotEmpty) seasonPicker(), episodeList()]);
    }));
  }

}

// ================= APP & HOME =================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight,
  ]);
  runApp(const MokaApp());
}

class MokaApp extends StatelessWidget {
  const MokaApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MOKA IPTV', debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFC8742B), brightness: Brightness.dark)),
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
  Source? _source;
  List<Channel> _channels = [];
  List<MediaItem> _movies = [];
  List<SeriesItem> _series = [];
  Set<String> _favs = {}, _mediaFavs = {};
  Map<String, int> _progress = {};
  String _group = 'All', _query = '';
  String? _lastId;
  bool _hideAdult = false, _loading = false, _ready = false;
  String? _error;
  int _tab = 0; // Home, Live TV, Movies, Series

  @override
  void initState() { super.initState(); _init(); }
  Future<void> _init() async {
    _favs = await Store.favs(); _mediaFavs = await Store.mediaFavs();
    _hideAdult = await Store.adultLock(); _lastId = await Store.lastId();
    final saved = await Store.sources();
    if (saved.isNotEmpty) {
      final i = await Store.active();
      await _connect(saved[i.clamp(0, saved.length - 1).toInt()], restore: true);
    } else if (mounted) setState(() => _ready = true);
  }

  Future<void> _refreshProgress() async {
    final values = <String, int>{};
    for (final m in _movies) {
      final value = await Store.progress('movie_${m.id}');
      if (value > 0) values['movie_${m.id}'] = value;
    }
    if (mounted) setState(() => _progress = values);
  }

  Future<void> _connect(Source source, {bool restore = false}) async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final live = await loadChannels(source);
      List<MediaItem> movies = [];
      List<SeriesItem> series = [];
      if (source.type == 'xtream') {
        movies = await loadMovies(source);
        series = await loadSeries(source);
      }
      await Store.saveSources([source]);
      await Store.saveActive(0);
      _source = source; _channels = live; _movies = movies; _series = series;
      _group = 'All'; _query = '';
      if (mounted) setState(() { _loading = false; _ready = true; _tab = 0; });
      await _refreshProgress();
    } catch (e) {
      if (mounted) setState(() { _loading = false; _ready = true; _error = '$e'; });
      if (!restore) rethrow;
    }
  }

  Future<void> _login(Source s) async { await _connect(s); }
  void _toggleChannelFav(Channel c) {
    setState(() { if (!_favs.remove(c.id)) _favs.add(c.id); });
    Store.saveFavs(_favs);
  }
  void _toggleMovieFav(MediaItem m) {
    final id = 'movie_${m.id}';
    setState(() { if (!_mediaFavs.remove(id)) _mediaFavs.add(id); });
    Store.saveMediaFavs(_mediaFavs);
  }
  void _toggleSeriesFav(String id) {
    final key = 'series_$id';
    setState(() { if (!_mediaFavs.remove(key)) _mediaFavs.add(key); });
    Store.saveMediaFavs(_mediaFavs);
  }

  Future<void> _playChannel(List<Channel> list, int index) async {
    final source = _source; if (source == null) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => LivePlayerPage(
      channels: list, index: index, favorites: _favs,
      onFavorite: _toggleChannelFav, source: source)));
    _lastId = await Store.lastId();
    if (mounted) setState(() {});
  }
  Future<void> _playMovie(MediaItem m) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) =>
      MediaPlayerPage(name: m.name, url: m.url, id: 'movie_${m.id}')));
    await _refreshProgress();
  }
  Future<void> _openAccount() async {
    final s = _source; if (s == null) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => AccountPage(source: s)));
  }
  Future<void> _openSettings() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage()));
    _hideAdult = await Store.adultLock();
    if (mounted) setState(() {});
  }
  Future<void> _logout() async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Logout'),
      content: const Text('This will remove the saved server and account login from this device. Continue?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Logout')),
      ],
    ));
    if (ok != true) return;
    await Store.logout();
    if (!mounted) return;
    setState(() {
      _source = null; _channels = []; _movies = []; _series = []; _progress = {};
      _lastId = null; _error = null; _ready = true; _tab = 0;
    });
  }

  Widget _homeBody() {
    final recent = _movies.where((m) => (_progress['movie_${m.id}'] ?? 0) > 0).toList()
      ..sort((a, b) => (_progress['movie_${b.id}'] ?? 0).compareTo(_progress['movie_${a.id}'] ?? 0));
    return ListView(padding: const EdgeInsets.all(16), children: [
      Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(colors: [Color(0xFFC8742B), Color(0xFF713D1D)])),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('MOKA IPTV', style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold)),
          const SizedBox(height: 5), Text('Welcome${_source == null ? '' : ' • ${_source!.name}'}'),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _quickButton('Live TV', Icons.live_tv, () => setState(() => _tab = 1)),
            _quickButton('Movies', Icons.movie, () => setState(() => _tab = 2)),
            _quickButton('Series', Icons.video_library, () => setState(() => _tab = 3)),
          ]),
        ])),
      const SizedBox(height: 20),
      Row(children: [const Expanded(child: Text('Continue Watching', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold))),
        Text('${recent.length} videos', style: const TextStyle(color: Colors.white60))]),
      const SizedBox(height: 10),
      if (recent.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 22),
        child: Center(child: Text('Your unfinished movies will appear here')))
      else SizedBox(height: 190, child: ListView.separated(scrollDirection: Axis.horizontal,
        itemCount: recent.length, separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          final m = recent[i];
          final position = _progress['movie_${m.id}'] ?? 0;
          return SizedBox(width: 115, child: InkWell(onTap: () => _playMovie(m), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Stack(fit: StackFit.expand, children: [Poster(m.poster),
                const Center(child: Icon(Icons.play_circle_fill, size: 38, color: Colors.white)),
                Align(alignment: Alignment.bottomCenter, child: LinearProgressIndicator(
                  value: (position / (position + 600000)).clamp(0.05, 0.95), minHeight: 4)),
              ])),
              const SizedBox(height: 6), Text(m.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            ])));
        })),
      const SizedBox(height: 18),
      Text('${_channels.length} Live channels  •  ${_movies.length} Movies  •  ${_series.length} Series',
        textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60)),
    ]);
  }

  Widget _quickButton(String label, IconData icon, VoidCallback action) =>
    FilledButton.tonal(onPressed: action, child: Row(mainAxisSize: MainAxisSize.min,
      children: [Icon(icon, size: 18), const SizedBox(width: 6), Text(label)]));

  Widget _liveBody() {
    final visible = _hideAdult ? _channels.where((c) => !_isAdult(c)).toList() : _channels;
    final groups = <String>{for (final c in visible) if (c.group.isNotEmpty) c.group}.toList()..sort();
    final q = _query.toLowerCase();
    final shown = visible.where((c) {
      if (_group == _favKey && !_favs.contains(c.id)) return false;
      if (_group != 'All' && _group != _favKey && c.group != _group) return false;
      return c.name.toLowerCase().contains(q);
    }).toList();
    return Column(children: [
      SizedBox(height: 45, child: ListView(scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [for (final g in ['All', _favKey, ...groups]) Padding(
          padding: const EdgeInsets.only(right: 7), child: ChoiceChip(label: Text(g),
            selected: _group == g, onSelected: (_) => setState(() => _group = g))) ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: TextField(
        decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search channels', isDense: true),
        onChanged: (v) => setState(() => _query = v))),
      Expanded(child: shown.isEmpty ? const Center(child: Text('No channels found'))
        : ListView.builder(itemCount: shown.length, itemBuilder: (_, i) {
          final c = shown[i];
          return ListTile(leading: SizedBox(width: 42, child: c.logo.isEmpty ? const Icon(Icons.tv)
            : Image.network(c.logo, errorBuilder: (_, __, ___) => const Icon(Icons.tv))),
            title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: c.group.isEmpty ? null : Text(c.group, maxLines: 1),
            trailing: IconButton(onPressed: () => _toggleChannelFav(c),
              icon: Icon(_favs.contains(c.id) ? Icons.star : Icons.star_border), color: Colors.amber),
            onTap: () => _playChannel(shown, i));
        })),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_source == null) return LoginPage(onLogin: _login);
    final pages = <Widget>[
      _homeBody(),
      _liveBody(),
      MediaGridPage(title: 'Movies', items: _movies, favorites: _mediaFavs,
        onFavorite: _toggleMovieFav, onPlay: _playMovie),
      SeriesBrowserPage(items: _series, source: _source!, favorites: _mediaFavs, onFavorite: _toggleSeriesFav),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('MOKA IPTV', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(tooltip: 'Account details', onPressed: _openAccount, icon: const Icon(Icons.account_circle)),
          IconButton(tooltip: 'Settings', onPressed: _openSettings, icon: const Icon(Icons.settings)),
          IconButton(tooltip: 'Logout', onPressed: _logout, icon: const Icon(Icons.logout)),
          IconButton(tooltip: 'Refresh', onPressed: _loading ? null : () => _connect(_source!), icon: const Icon(Icons.refresh)),
        ]),
      body: Column(children: [
        if (_loading) const LinearProgressIndicator(),
        if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
        Expanded(child: IndexedStack(index: _tab, children: pages)),
      ]),
      bottomNavigationBar: NavigationBar(height: 62, selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.live_tv_outlined), selectedIcon: Icon(Icons.live_tv), label: 'Live TV'),
          NavigationDestination(icon: Icon(Icons.movie_outlined), selectedIcon: Icon(Icons.movie), label: 'Movies'),
          NavigationDestination(icon: Icon(Icons.video_library_outlined), selectedIcon: Icon(Icons.video_library), label: 'Series'),
        ]),
    );
  }
}
