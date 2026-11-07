import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show FontFeature, ImageFilter;
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
  final int catOrder; // position of the category in the server's own list
  const MediaItem({required this.id, required this.name, required this.category,
    required this.poster, required this.url, required this.type, this.catOrder = 9999});
}

class SeriesItem {
  final String id, name, category, poster, plot;
  final int catOrder;
  const SeriesItem({required this.id, required this.name, required this.category,
    required this.poster, this.plot = '', this.catOrder = 9999});
}

class SeriesDetails {
  final List<Episode> episodes;
  final String plot, genre, releaseDate, director, backdrop;
  final double rating; // out of 5
  const SeriesDetails({required this.episodes, this.plot = '', this.genre = '',
    this.releaseDate = '', this.director = '', this.backdrop = '', this.rating = 0});
}

class Episode {
  final String id, name, url, thumb;
  final int season, number, durationSecs;
  const Episode({required this.id, required this.name, required this.url,
    required this.season, required this.number, this.thumb = '', this.durationSecs = 0});
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
  final catPos = <String, int>{};
  if (r[0] is List) {
    var n = 0;
    for (final c in r[0]) { cats['${c['category_id']}'] = '${c['category_name']}'; catPos['${c['category_id']}'] = n++; }
  }
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
      poster: '${x['stream_icon'] ?? ''}', url: _movieUrl(s, x), type: 'movie',
      catOrder: catPos['${x['category_id']}'] ?? 9999)];
}

Future<List<SeriesItem>> loadSeries(Source s) async {
  if (s.type != 'xtream') return [];
  final r = await Future.wait([
    _getJson('${_api(s)}&action=get_series_categories'),
    _getJson('${_api(s)}&action=get_series'),
  ]);
  final cats = <String, String>{};
  final catPos = <String, int>{};
  if (r[0] is List) {
    var n = 0;
    for (final c in r[0]) { cats['${c['category_id']}'] = '${c['category_name']}'; catPos['${c['category_id']}'] = n++; }
  }
  if (r[1] is! List) throw 'Invalid series response';
  final rawSeries = List<dynamic>.from(r[1]);
  int seriesKey(dynamic x) {
    if (x is! Map) return 0;
    for (final k in ['last_modified', 'added']) {
      final n = int.tryParse('${x[k] ?? ''}');
      if (n != null && n > 0) return n > 99999999999 ? n ~/ 1000 : n;
    }
    return 0;
  }
  int seriesId(dynamic x) => int.tryParse('${x is Map ? x['series_id'] ?? 0 : 0}') ?? 0;
  rawSeries.sort((a, b) {
    final d = seriesKey(b).compareTo(seriesKey(a));
    return d != 0 ? d : seriesId(b).compareTo(seriesId(a));
  });
  return [for (final x in rawSeries)
    SeriesItem(id: '${x['series_id']}', name: '${x['name'] ?? 'Series'}',
      category: cats['${x['category_id']}'] ?? 'Other',
      poster: '${x['cover'] ?? ''}', plot: '${x['plot'] ?? ''}',
      catOrder: catPos['${x['category_id']}'] ?? 9999)];
}

Future<SeriesDetails> loadSeriesDetails(Source s, String id) async {
  final d = await _getJson('${_api(s)}&action=get_series_info&series_id=$id');
  String str(dynamic v) { final t = '${v ?? ''}'.trim(); return t == 'null' ? '' : t; }
  final out = <Episode>[];
  final seasons = d is Map ? d['episodes'] : null;
  if (seasons is Map) {
    for (final entry in seasons.entries) {
      final season = int.tryParse('${entry.key}') ?? 1;
      if (entry.value is! List) continue;
      for (final x in entry.value) {
        final Map xi = x is Map && x['info'] is Map ? x['info'] as Map : const {};
        out.add(Episode(id: '${x['id']}', name: '${x['title'] ?? 'Episode ${x['episode_num'] ?? ''}'}',
          url: _episodeUrl(s, x), season: season,
          number: int.tryParse('${x['episode_num']}') ?? 0,
          thumb: str(xi['movie_image']),
          durationSecs: int.tryParse(str(xi['duration_secs'])) ?? 0));
      }
    }
  }
  out.sort((a,b) => a.season != b.season ? a.season.compareTo(b.season) : a.number.compareTo(b.number));
  final Map info = d is Map && d['info'] is Map ? d['info'] as Map : const {};
  final bd = info['backdrop_path'];
  final backdrop = bd is List ? (bd.isNotEmpty ? str(bd.first) : '') : str(bd);
  var rating = double.tryParse(str(info['rating_5based'])) ?? 0;
  if (rating <= 0) rating = (double.tryParse(str(info['rating'])) ?? 0) / 2;
  return SeriesDetails(episodes: out, plot: str(info['plot']), genre: str(info['genre']),
    releaseDate: str(info['releaseDate'] ?? info['release_date']),
    director: str(info['director']), backdrop: backdrop, rating: rating);
}

Future<List<Episode>> loadEpisodes(Source s, String id) async =>
    (await loadSeriesDetails(s, id)).episodes;

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

// ================= PRAYER TIMES & MATCHES =================

String _p2(int n) => n.toString().padLeft(2, '0');
String _s(dynamic v) => v == null ? '' : '$v';

Future<Map<String, DateTime>> loadPrayerTimes(String city, String country, DateTime day) async {
  final qs = <String, String>{'city': city, 'country': country};
  if (country.trim().toLowerCase() == 'egypt') qs['method'] = '5';
  final uri = Uri.https('api.aladhan.com',
    '/v1/timingsByCity/${_p2(day.day)}-${_p2(day.month)}-${day.year}', qs);
  final r = await http.get(uri).timeout(const Duration(seconds: 12));
  if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
  final j = jsonDecode(r.body);
  final Map t = j['data']['timings'];
  final out = <String, DateTime>{};
  for (final k in const ['Fajr', 'Dhuhr', 'Asr', 'Maghrib', 'Isha']) {
    final s = '${t[k]}'.trim();
    final h = int.parse(s.substring(0, 2));
    final m = int.parse(s.substring(3, 5));
    out[k] = DateTime(day.year, day.month, day.day, h, m);
  }
  return out;
}

class MatchItem {
  final String league, home, away, homeLogo, awayLogo, homeScore, awayScore, state, detail;
  final DateTime time;
  const MatchItem({required this.league, required this.home, required this.away,
    required this.homeLogo, required this.awayLogo, required this.homeScore,
    required this.awayScore, required this.state, required this.detail, required this.time});
}

const _matchLeagues = <String, String>{
  'egy.1': 'Egyptian League',
  'eng.1': 'Premier League',
  'esp.1': 'La Liga',
  'ita.1': 'Serie A',
  'ger.1': 'Bundesliga',
  'fra.1': 'Ligue 1',
  'uefa.champions': 'Champions League',
  'uefa.europa': 'Europa League',
  'caf.champions': 'CAF Champions League',
  'ksa.1': 'Saudi Pro League',
};

Future<List<MatchItem>> loadMatches(DateTime now) async {
  String ymd(DateTime d) => '${d.year}${_p2(d.month)}${_p2(d.day)}';
  final range = '${ymd(now.subtract(const Duration(days: 1)))}-${ymd(now.add(const Duration(days: 1)))}';
  var failed = 0;
  final lists = await Future.wait(_matchLeagues.entries.map((e) async {
    final out = <MatchItem>[];
    try {
      final uri = Uri.parse('https://site.api.espn.com/apis/site/v2/sports/soccer/${e.key}/scoreboard?dates=$range');
      final r = await http.get(uri).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) { failed++; return out; }
      final j = jsonDecode(r.body);
      final events = j is Map ? j['events'] : null;
      if (events is List) {
        for (final ev in events) {
          try {
            final comp = (ev['competitions'] as List).first;
            final cs = comp['competitors'] as List;
            final home = cs.firstWhere((c) => c['homeAway'] == 'home', orElse: () => cs[0]);
            final away = cs.firstWhere((c) => c['homeAway'] == 'away', orElse: () => cs[1]);
            final type = ev['status']?['type'];
            final t = DateTime.parse('${ev['date']}').toLocal();
            if (t.year != now.year || t.month != now.month || t.day != now.day) continue;
            out.add(MatchItem(
              league: e.value,
              home: _s(home['team']?['shortDisplayName'] ?? home['team']?['displayName']),
              away: _s(away['team']?['shortDisplayName'] ?? away['team']?['displayName']),
              homeLogo: _s(home['team']?['logo']), awayLogo: _s(away['team']?['logo']),
              homeScore: _s(home['score']), awayScore: _s(away['score']),
              state: _s(type?['state']), detail: _s(type?['shortDetail']), time: t));
          } catch (_) {}
        }
      }
    } catch (_) { failed++; }
    return out;
  }));
  if (failed == _matchLeagues.length) throw 'matches unavailable';
  final all = <MatchItem>[for (final l in lists) ...l];
  all.sort((a, b) => a.time.compareTo(b.time));
  return all;
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
  static Future<List<String>> watchingSeries() async =>
      List<String>.from((await p).getStringList('watching_series') ?? const <String>[]);
  static Future<void> saveWatchingSeries(List<String> v) async =>
      (await p).setStringList('watching_series', v);
  static Future<String?> lastEpisode(String seriesId) async => (await p).getString('last_ep_$seriesId');
  static Future<void> saveLastEpisode(String seriesId, String epId) async =>
      (await p).setString('last_ep_$seriesId', epId);
  static Future<String> prayerCity() async => (await p).getString('prayer_city') ?? 'Cairo';
  static Future<String> prayerCountry() async => (await p).getString('prayer_country') ?? 'Egypt';
  static Future<void> savePrayerPlace(String city, String country) async {
    final x = await p;
    await x.setString('prayer_city', city);
    await x.setString('prayer_country', country);
  }
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
    await prefs.remove('watching_series');
    for (final key in prefs.getKeys().where((k) => k.startsWith('last_ep_')).toList()) {
      await prefs.remove(key);
    }
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

class PlayItem {
  final String id, name, url;
  const PlayItem(this.id, this.name, this.url);
}

class QualityOption {
  final String label, url;
  const QualityOption(this.label, this.url);
}

class MediaPlayerPage extends StatefulWidget {
  final String name, url, id;
  final List<PlayItem> playlist;
  final int index;
  final List<QualityOption> qualities;
  final String? seriesId;
  const MediaPlayerPage({super.key, required this.name, required this.url, required this.id,
    this.playlist = const <PlayItem>[], this.index = 0,
    this.qualities = const <QualityOption>[], this.seriesId});
  @override
  State<MediaPlayerPage> createState() => _MediaPlayerPageState();
}

class _MediaPlayerPageState extends State<MediaPlayerPage> {
  static const _brand = Color(0xFFC8742B);
  static const _fitNames = ['Fit', 'Fill', 'Stretch', '16:9'];
  static const _panel = Color(0xFF1A1411);

  VideoPlayerController? _c;
  Timer? _timer;
  Timer? _controlsTimer;
  bool _controlsVisible = true;
  bool _loading = true;
  bool _advancing = false;
  bool _recorded = false;
  bool _muted = false;
  String? _error;
  double? _drag; // seek position (ms) while the user drags the bar
  late String _name = widget.name;
  late String _id = widget.id;
  late String _url = widget.url;
  late int _index = widget.index;
  String _qLabel = '';
  double _speed = 1.0;
  int _fit = 0;
  ClosedCaptionFile? _subs;
  String _subName = 'Off';
  Duration _subOffset = Duration.zero;

  bool get _hasNext => widget.playlist.isNotEmpty && _index < widget.playlist.length - 1;
  bool get _hasPrev => widget.playlist.isNotEmpty && _index > 0;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    if (widget.qualities.isNotEmpty) {
      _qLabel = widget.qualities.firstWhere((q) => q.url == widget.url,
        orElse: () => widget.qualities.first).label;
    }
    _open(_url);
  }

  Future<void> _open(String url, {Duration? startAt}) async {
    final old = _c;
    old?.removeListener(_changed);
    _timer?.cancel();
    if (old != null) {
      _c = null;
      if (mounted) setState(() { _loading = true; _error = null; });
      await WidgetsBinding.instance.endOfFrame;
      await old.dispose();
      if (!mounted) return;
    }
    final c = VideoPlayerController.networkUrl(Uri.parse(url));
    _c = c;
    try {
      await c.initialize();
      if (!mounted || _c != c) return;
      Duration? start = startAt;
      if (start == null) {
        final saved = await Store.progress(_id);
        if (saved > 0 && saved < c.value.duration.inMilliseconds - 10000) {
          start = Duration(milliseconds: saved);
        }
      }
      if (start != null && start > Duration.zero) await c.seekTo(start);
      await c.setPlaybackSpeed(_speed);
      await c.setVolume(_muted ? 0.0 : 1.0);
      if (_subs != null) {
        await c.setClosedCaptionFile(Future<ClosedCaptionFile>.value(_subs!));
        await c.setCaptionOffset(_subOffset);
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
    if (_controlsVisible) { _scheduleControlsHide(); }
    else { _controlsTimer?.cancel(); }
  }

  void _changed() {
    if (!mounted) return;
    final c = _c;
    if (c == null) return;
    if (c.value.hasError) {
      setState(() => _error = 'Video playback error');
      return;
    }
    final d = c.value.duration;
    if (!_advancing && _hasNext && d.inMilliseconds > 0 &&
        c.value.position >= d - const Duration(milliseconds: 600)) {
      _advancing = true;
      _goTo(_index + 1).whenComplete(() => _advancing = false);
    }
    setState(() {});
  }

  Future<void> _save() async {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    final ms = c.value.position.inMilliseconds;
    await Store.saveProgress(_id, ms);
    final sid = widget.seriesId;
    if (sid != null && ms > 5000 && !_recorded) {
      _recorded = true;
      await Store.saveLastEpisode(sid, _id.replaceFirst('episode_', ''));
      final l = await Store.watchingSeries();
      l.remove(sid);
      l.insert(0, sid);
      await Store.saveWatchingSeries(l);
    }
  }

  Future<void> _goTo(int i) async {
    if (i < 0 || i >= widget.playlist.length) return;
    await _save();
    final it = widget.playlist[i];
    if (!mounted) return;
    setState(() { _index = i; _name = it.name; _id = it.id; _url = it.url; _recorded = false; });
    await _open(it.url);
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

  Future<void> _toggleMute() async {
    _muted = !_muted;
    await _c?.setVolume(_muted ? 0.0 : 1.0);
    if (mounted) setState(() {});
    _scheduleControlsHide();
  }

  void _toast(String t) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(duration: const Duration(milliseconds: 900), content: Text(t)));
  }

  void _cycleFit() {
    setState(() => _fit = (_fit + 1) % _fitNames.length);
    _toast('Aspect ratio: ${_fitNames[_fit]}');
    _scheduleControlsHide();
  }

  Future<void> _setSpeed(double s) async {
    _speed = s;
    await _c?.setPlaybackSpeed(s);
    if (mounted) setState(() {});
  }

  Future<void> _switchQuality(QualityOption q) async {
    if (q.label == _qLabel) return;
    final pos = _c?.value.position ?? Duration.zero;
    _qLabel = q.label;
    _url = q.url;
    await _open(q.url, startAt: pos);
  }

  Future<void> _applySubs(ClosedCaptionFile file, String name) async {
    _subs = file;
    _subName = name;
    await _c?.setClosedCaptionFile(Future<ClosedCaptionFile>.value(file));
    await _c?.setCaptionOffset(_subOffset);
    if (mounted) setState(() {});
  }

  Future<void> _clearSubs() async {
    _subs = null;
    _subName = 'Off';
    _subOffset = Duration.zero;
    await _c?.setClosedCaptionFile(null);
    if (mounted) setState(() {});
  }

  Future<void> _shiftSubs(int ms) async {
    _subOffset += Duration(milliseconds: ms);
    await _c?.setCaptionOffset(_subOffset);
    if (mounted) setState(() {});
  }

  Widget _lbl(String t) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 6),
    child: Text(t, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold,
      color: Colors.white70, letterSpacing: .4)));

  Future<void> _openSettings() async {
    _controlsTimer?.cancel();
    await showDialog<void>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
      final h = MediaQuery.of(ctx).size.height;
      return Dialog(
        backgroundColor: _panel,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 520, maxHeight: h * .9),
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(18, 10, 12, 16), children: [
            Row(children: [
              const Icon(Icons.settings_rounded, size: 20),
              const SizedBox(width: 8),
              const Expanded(child: Text('Player settings',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
              IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
            ]),
            _lbl('QUALITY'),
            if (widget.qualities.isEmpty)
              const Text('Only one quality is available for this title',
                style: TextStyle(fontSize: 12.5, color: Colors.white54))
            else Wrap(spacing: 8, runSpacing: 6, children: [
              for (final q in widget.qualities) ChoiceChip(
                label: Text(q.label), selected: q.label == _qLabel,
                onSelected: (_) async { Navigator.pop(ctx); await _switchQuality(q); }),
            ]),
            _lbl('PLAYBACK SPEED'),
            Wrap(spacing: 8, runSpacing: 6, children: [
              for (final s in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]) ChoiceChip(
                label: Text('${s}x'), selected: _speed == s,
                onSelected: (_) async { await _setSpeed(s); setDlg(() {}); }),
            ]),
            _lbl('ASPECT RATIO'),
            Wrap(spacing: 8, runSpacing: 6, children: [
              for (var i = 0; i < _fitNames.length; i++) ChoiceChip(
                label: Text(_fitNames[i]), selected: _fit == i,
                onSelected: (_) { setState(() => _fit = i); setDlg(() {}); }),
            ]),
            _lbl('SUBTITLES'),
            Row(children: [
              Expanded(child: Text(_subName, style: const TextStyle(fontSize: 13.5))),
              OutlinedButton.icon(
                onPressed: () { Navigator.pop(ctx); _subtitleDialog(); },
                icon: const Icon(Icons.closed_caption_rounded, size: 18),
                label: const Text('Subtitles')),
            ]),
          ])),
      );
    }));
    _scheduleControlsHide();
  }

  Future<void> _subtitleDialog() async {
    _controlsTimer?.cancel();
    final ctl = TextEditingController();
    String? err;
    var busy = false;
    await showDialog<void>(context: context, builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDlg) => AlertDialog(
        backgroundColor: _panel,
        title: const Text('Subtitles'),
        content: SizedBox(width: 440, child: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Current: $_subName'),
            const SizedBox(height: 10),
            TextField(controller: ctl, decoration: InputDecoration(
              labelText: 'Link to a subtitle file (.srt or .vtt)', isDense: true, errorText: err)),
            const SizedBox(height: 8),
            const Text('Subtitles that are built into the video file can’t be switched in this player. '
              'Paste a direct link to an .srt or .vtt file and press Load.',
              style: TextStyle(fontSize: 12, color: Colors.white54)),
            if (_subs != null) Padding(padding: const EdgeInsets.only(top: 10), child: Row(children: [
              Text('Delay: ${(_subOffset.inMilliseconds / 1000).toStringAsFixed(1)}s'),
              const Spacer(),
              IconButton(onPressed: () async { await _shiftSubs(-500); setDlg(() {}); },
                icon: const Icon(Icons.remove_circle_outline)),
              IconButton(onPressed: () async { await _shiftSubs(500); setDlg(() {}); },
                icon: const Icon(Icons.add_circle_outline)),
            ])),
          ]))),
        actions: [
          if (_subs != null) TextButton(
            onPressed: () async { await _clearSubs(); if (ctx.mounted) Navigator.pop(ctx); },
            child: const Text('Turn off')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          FilledButton(
            onPressed: busy ? null : () async {
              final url = ctl.text.trim();
              if (url.isEmpty) { setDlg(() => err = 'Paste a link first'); return; }
              setDlg(() { busy = true; err = null; });
              try {
                final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
                if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
                final text = utf8.decode(r.bodyBytes, allowMalformed: true);
                final ClosedCaptionFile file = text.trimLeft().startsWith('WEBVTT')
                    ? WebVTTCaptionFile(text) : SubRipCaptionFile(text);
                await _applySubs(file, 'Custom file');
                if (ctx.mounted) Navigator.pop(ctx);
              } catch (_) {
                setDlg(() { busy = false; err = 'Could not load this subtitle file'; });
              }
            },
            child: Text(busy ? 'Loading…' : 'Load')),
        ])));
    _scheduleControlsHide();
  }

  Future<void> _episodesDialog() async {
    _controlsTimer?.cancel();
    final scroll = ScrollController(initialScrollOffset: math.max(0, _index - 2) * 48.0);
    await showDialog<void>(context: context, builder: (ctx) {
      final h = MediaQuery.of(ctx).size.height;
      return Dialog(
        backgroundColor: _panel,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 440, maxHeight: h * .9),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(padding: const EdgeInsets.fromLTRB(18, 10, 8, 4), child: Row(children: [
              const Expanded(child: Text('Episodes',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
              IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
            ])),
            Flexible(child: ListView.builder(
              controller: scroll, shrinkWrap: true, itemCount: widget.playlist.length,
              itemBuilder: (_, i) {
                final it = widget.playlist[i];
                final cur = i == _index;
                return ListTile(
                  dense: true, selected: cur, selectedColor: _brand,
                  leading: Icon(cur ? Icons.play_arrow_rounded : Icons.circle_outlined, size: 20),
                  title: Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () { Navigator.pop(ctx); if (!cur) _goTo(i); });
              })),
          ])),
      );
    });
    _scheduleControlsHide();
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

  Duration _buffered(VideoPlayerController c) {
    final r = c.value.buffered;
    return r.isEmpty ? Duration.zero : r.last.end;
  }

  Widget _roundBtn(IconData icon, double size, VoidCallback? onTap, {String? tip}) =>
    IconButton(tooltip: tip, iconSize: size, onPressed: onTap,
      icon: Icon(icon, color: onTap == null ? Colors.white24 : Colors.white));

  Widget _video(VideoPlayerController c) {
    final sz = c.value.size;
    final ratio = c.value.aspectRatio > 0 ? c.value.aspectRatio : 16 / 9;
    final hasSize = sz.width > 0 && sz.height > 0;
    if (_fit == 1 && hasSize) {
      return SizedBox.expand(child: FittedBox(fit: BoxFit.cover, clipBehavior: Clip.hardEdge,
        child: SizedBox(width: sz.width, height: sz.height, child: VideoPlayer(c))));
    }
    if (_fit == 2 && hasSize) {
      return SizedBox.expand(child: FittedBox(fit: BoxFit.fill,
        child: SizedBox(width: sz.width, height: sz.height, child: VideoPlayer(c))));
    }
    if (_fit == 3) {
      return Center(child: AspectRatio(aspectRatio: 16 / 9, child: VideoPlayer(c)));
    }
    return Center(child: AspectRatio(aspectRatio: ratio, child: VideoPlayer(c)));
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final ready = c != null && c.value.isInitialized;
    const brand = _brand;
    return Scaffold(
      backgroundColor: Colors.black,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!, style: const TextStyle(color: Colors.white)),
                  const SizedBox(height: 12),
                  FilledButton.icon(onPressed: () => _open(_url),
                    icon: const Icon(Icons.refresh), label: const Text('Retry')),
                ]))
              : !ready
                  ? const Center(child: CircularProgressIndicator())
                  : LayoutBuilder(builder: (context, bounds) {
                      final vc = c!;
                      final total = vc.value.duration.inMilliseconds;
                      final pos = vc.value.position.inMilliseconds;
                      final maxV = total > 0 ? total.toDouble() : 1.0;
                      final shown = (_drag ?? pos.toDouble()).clamp(0.0, maxV).toDouble();
                      final buf = _buffered(vc).inMilliseconds.clamp(0, total > 0 ? total : 1).toDouble();
                      final playing = vc.value.isPlaying;
                      final info = <String>[
                        if (_speed != 1.0) '${_speed}x',
                        if (_qLabel.isNotEmpty) _qLabel,
                      ].join('  •  ');
                      return Stack(fit: StackFit.expand, children: [
                        _video(vc),
                        Positioned.fill(child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTap: _toggleControls,
                          child: const SizedBox.expand())),
                        if (_subs != null) Positioned(left: 60, right: 60,
                          bottom: _controlsVisible ? 124 : 28,
                          child: IgnorePointer(child: Center(child: ClosedCaption(
                            text: vc.value.caption.text,
                            textStyle: const TextStyle(fontSize: 18, color: Colors.white,
                              fontWeight: FontWeight.w600))))),
                        Positioned.fill(child: AnimatedOpacity(
                          opacity: _controlsVisible ? 1 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: IgnorePointer(ignoring: !_controlsVisible, child: Stack(children: [
                            // ---- top bar ----
                            Positioned(top: 0, left: 0, right: 0, child: Container(
                              decoration: BoxDecoration(gradient: LinearGradient(
                                begin: Alignment.topCenter, end: Alignment.bottomCenter,
                                colors: [Colors.black.withOpacity(.85), Colors.transparent])),
                              child: SafeArea(bottom: false, child: Padding(
                                padding: const EdgeInsets.fromLTRB(4, 2, 8, 14),
                                child: Row(children: [
                                  IconButton(tooltip: 'Back',
                                    onPressed: () => Navigator.maybePop(context),
                                    icon: const Icon(Icons.arrow_back, color: Colors.white)),
                                  Expanded(child: Text(_name, maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white,
                                      fontSize: 17, fontWeight: FontWeight.w600))),
                                  IconButton(tooltip: 'Mute', onPressed: _toggleMute,
                                    icon: Icon(_muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                                      color: Colors.white)),
                                  IconButton(tooltip: 'Subtitles', onPressed: _subtitleDialog,
                                    icon: Icon(Icons.closed_caption_rounded,
                                      color: _subs != null ? brand : Colors.white)),
                                  IconButton(tooltip: 'Aspect ratio', onPressed: _cycleFit,
                                    icon: const Icon(Icons.aspect_ratio_rounded, color: Colors.white)),
                                  IconButton(tooltip: 'Settings', onPressed: _openSettings,
                                    icon: const Icon(Icons.settings_rounded, color: Colors.white)),
                                ]))))),
                            // ---- bottom controls ----
                            Positioned(bottom: 0, left: 0, right: 0, child: Container(
                              decoration: BoxDecoration(gradient: LinearGradient(
                                begin: Alignment.bottomCenter, end: Alignment.topCenter,
                                colors: [Colors.black.withOpacity(.92), Colors.transparent])),
                              child: SafeArea(top: false, child: Padding(
                                padding: const EdgeInsets.fromLTRB(16, 22, 16, 4),
                                child: Column(mainAxisSize: MainAxisSize.min, children: [
                                  Row(children: [
                                    Text(_time(Duration(milliseconds: shown.round())),
                                      style: const TextStyle(color: Colors.white, fontSize: 12,
                                        fontFeatures: [FontFeature.tabularFigures()])),
                                    Expanded(child: SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        trackHeight: 3.5,
                                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 15),
                                        activeTrackColor: brand,
                                        inactiveTrackColor: Colors.white24,
                                        secondaryActiveTrackColor: Colors.white38,
                                        thumbColor: brand,
                                        overlayColor: brand.withOpacity(.25)),
                                      child: Slider(
                                        min: 0, max: maxV, value: shown,
                                        secondaryTrackValue: buf,
                                        onChangeStart: (_) => _controlsTimer?.cancel(),
                                        onChanged: total > 0 ? (v) => setState(() => _drag = v) : null,
                                        onChangeEnd: (v) async {
                                          await vc.seekTo(Duration(milliseconds: v.round()));
                                          if (mounted) setState(() => _drag = null);
                                          _scheduleControlsHide();
                                        }))),
                                    Text(_time(vc.value.duration),
                                      style: const TextStyle(color: Colors.white70, fontSize: 12,
                                        fontFeatures: [FontFeature.tabularFigures()])),
                                  ]),
                                  Row(children: [
                                    Expanded(child: Align(alignment: Alignment.centerLeft,
                                      child: widget.playlist.length > 1
                                        ? TextButton.icon(onPressed: _episodesDialog,
                                            icon: const Icon(Icons.format_list_bulleted_rounded, size: 20),
                                            label: const Text('Episodes'),
                                            style: TextButton.styleFrom(foregroundColor: Colors.white))
                                        : const SizedBox.shrink())),
                                    _roundBtn(Icons.skip_previous_rounded, 34,
                                      _hasPrev ? () => _goTo(_index - 1) : null, tip: 'Previous'),
                                    _roundBtn(Icons.replay_10, 32, () { _seekBy(-10); _scheduleControlsHide(); },
                                      tip: '-10s'),
                                    const SizedBox(width: 8),
                                    Container(
                                      decoration: const BoxDecoration(color: brand, shape: BoxShape.circle),
                                      child: IconButton(iconSize: 36, onPressed: _togglePlayback,
                                        tooltip: playing ? 'Pause' : 'Play',
                                        icon: Icon(playing ? Icons.pause : Icons.play_arrow,
                                          color: Colors.white))),
                                    const SizedBox(width: 8),
                                    _roundBtn(Icons.forward_10, 32, () { _seekBy(10); _scheduleControlsHide(); },
                                      tip: '+10s'),
                                    _roundBtn(Icons.skip_next_rounded, 34,
                                      _hasNext ? () => _goTo(_index + 1) : null, tip: 'Next'),
                                    Expanded(child: Align(alignment: Alignment.centerRight,
                                      child: info.isEmpty ? const SizedBox.shrink()
                                        : InkWell(onTap: _openSettings, borderRadius: BorderRadius.circular(20),
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                              decoration: BoxDecoration(color: Colors.white12,
                                                borderRadius: BorderRadius.circular(20)),
                                              child: Text(info, style: const TextStyle(
                                                color: Colors.white, fontSize: 12)))))),
                                  ]),
                                ]))))),
                          ])),
                        )),
                      ]);
                    }),
    );
  }
}

// ================= BROWSE LAYOUT (Movies + Series) =================

class _CatEntry {
  final String key, label;
  final int count;
  const _CatEntry(this.key, this.label, this.count);
}

class _BrowseLayout extends StatefulWidget {
  final List<_CatEntry> entries;
  final String selected, hint;
  final ValueChanged<String> onSelect, onQuery;
  final Widget? menu;
  final Widget body;
  const _BrowseLayout({required this.entries, required this.selected,
    required this.hint, required this.onSelect, required this.onQuery,
    required this.body, this.menu});
  @override
  State<_BrowseLayout> createState() => _BrowseLayoutState();
}

class _BrowseLayoutState extends State<_BrowseLayout> {
  static const _brand = Color(0xFFC8742B);
  bool _searching = false;
  final _ctl = TextEditingController();

  @override
  void dispose() { _ctl.dispose(); super.dispose(); }

  String get _title {
    for (final e in widget.entries) { if (e.key == widget.selected) return e.label; }
    return '';
  }
  void _closeSearch() {
    _ctl.clear();
    widget.onQuery('');
    setState(() => _searching = false);
  }

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 190,
        decoration: BoxDecoration(color: Colors.black26, border: Border(
          right: BorderSide(color: Theme.of(context).dividerColor))),
        child: ListView.builder(
          itemCount: widget.entries.length,
          itemBuilder: (_, i) {
            final e = widget.entries[i];
            final sel = e.key == widget.selected;
            return InkWell(
              onTap: () => widget.onSelect(e.key),
              child: Container(
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: sel ? _brand : null,
                  border: const Border(bottom: BorderSide(color: Colors.white10))),
                child: Row(children: [
                  Expanded(child: Text(e.label, maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13,
                      fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                      color: sel ? Colors.white : null))),
                  const SizedBox(width: 6),
                  Text('${e.count}', style: TextStyle(fontSize: 12,
                    color: sel ? Colors.white : Colors.white60)),
                ]),
              ),
            );
          }),
      ),
      Expanded(child: Column(children: [
        SizedBox(height: 44, child: Row(children: [
          const SizedBox(width: 12),
          Expanded(child: _searching
            ? TextField(controller: _ctl, autofocus: true,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(hintText: widget.hint,
                  border: InputBorder.none, isDense: true),
                onChanged: widget.onQuery)
            : Center(child: Text(_title, maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)))),
          IconButton(
            tooltip: 'Search',
            onPressed: _searching ? _closeSearch : () => setState(() => _searching = true),
            icon: Icon(_searching ? Icons.close : Icons.search)),
          if (widget.menu != null) widget.menu!,
        ])),
        Expanded(child: widget.body),
      ])),
    ],
  );
}

SliverGridDelegate _posterGrid() => const SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 130, childAspectRatio: .66,
  crossAxisSpacing: 8, mainAxisSpacing: 8);

class _PosterCard extends StatelessWidget {
  final String name, poster;
  final IconData fallback;
  final bool fav;
  final VoidCallback onTap, onFav;
  const _PosterCard({required this.name, required this.poster,
    required this.fav, required this.onTap, required this.onFav,
    this.fallback = Icons.movie});
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    onLongPress: () {
      onFav();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          duration: const Duration(seconds: 1),
          content: Text(fav ? 'Removed from favourites' : 'Added to favourites')));
    },
    borderRadius: BorderRadius.circular(8),
    child: ClipRRect(borderRadius: BorderRadius.circular(8),
      child: Stack(fit: StackFit.expand, children: [
        Poster(poster, fallback: fallback),
        Positioned(left: 0, right: 0, bottom: 0, child: Container(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 5),
          decoration: const BoxDecoration(gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black87])),
          child: Text(name, maxLines: 2, textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)))),
        if (fav) Positioned(top: 5, right: 5, child: Container(
          padding: const EdgeInsets.all(3),
          decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
          child: const Icon(Icons.star, size: 13, color: Colors.amber))),
      ])),
  );
}

// ================= MOVIES GRID =================

class MediaGridPage extends StatefulWidget {
  final String title;
  final List<MediaItem> items;
  final Set<String> favorites;
  final Map<String, int> progress;
  final Widget? menu;
  final Future<void> Function(MediaItem) onPlay;
  final void Function(MediaItem) onFavorite;
  const MediaGridPage({super.key, required this.title, required this.items,
    required this.favorites, required this.onPlay, required this.onFavorite,
    this.progress = const {}, this.menu});
  @override
  State<MediaGridPage> createState() => _MediaGridPageState();
}
class _MediaGridPageState extends State<MediaGridPage> {
  String _sel = '__all', _query = '';
  bool _isFav(MediaItem x) =>
      widget.favorites.contains('movie_${x.id}') || widget.favorites.contains(x.id);
  bool _inProgress(MediaItem x) => (widget.progress['movie_${x.id}'] ?? 0) > 0;

  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    for (final x in widget.items) {
      if (x.category.isNotEmpty) counts[x.category] = (counts[x.category] ?? 0) + 1;
    }
    final order = <String, int>{for (final x in widget.items) x.category: x.catOrder};
    final cats = counts.keys.toList()..sort((a, b) {
      final d = (order[a] ?? 9999).compareTo(order[b] ?? 9999);
      return d != 0 ? d : a.compareTo(b);
    });
    Iterable<MediaItem> base;
    if (_sel == '__all') { base = widget.items; }
    else if (_sel == '__fav') { base = widget.items.where(_isFav); }
    else if (_sel == '__continue') { base = widget.items.where(_inProgress); }
    else if (_sel == '__recent') { base = widget.items.take(30); }
    else { base = widget.items.where((x) => x.category == _sel); }
    final q = _query.toLowerCase();
    final list = base.where((x) => x.name.toLowerCase().contains(q)).toList();
    return _BrowseLayout(
      entries: [
        _CatEntry('__all', 'ALL', widget.items.length),
        _CatEntry('__fav', 'FAVOURITES', widget.items.where(_isFav).length),
        _CatEntry('__continue', 'CONTINUE WATCHING', widget.items.where(_inProgress).length),
        _CatEntry('__recent', 'RECENTLY ADDED', math.min(30, widget.items.length)),
        for (final c in cats) _CatEntry(c, c, counts[c] ?? 0),
      ],
      selected: _sel, hint: 'Search movies', menu: widget.menu,
      onSelect: (v) => setState(() => _sel = v),
      onQuery: (v) => setState(() => _query = v),
      body: list.isEmpty
        ? const Center(child: Text('No movies here yet'))
        : GridView.builder(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
            gridDelegate: _posterGrid(),
            itemCount: list.length, itemBuilder: (_, i) {
              final x = list[i];
              return _PosterCard(name: x.name, poster: x.poster, fav: _isFav(x),
                onTap: () => widget.onPlay(x),
                onFav: () { widget.onFavorite(x); setState(() {}); });
            }),
    );
  }
}

// ================= SERIES BROWSER =================

class SeriesBrowserPage extends StatefulWidget {
  final List<SeriesItem> items;
  final Source source;
  final Set<String> favorites;
  final Widget? menu;
  final int watchTick;
  final void Function(String) onFavorite;
  const SeriesBrowserPage({super.key, required this.items, required this.source,
    required this.favorites, required this.onFavorite, this.menu, this.watchTick = 0});
  @override
  State<SeriesBrowserPage> createState() => _SeriesBrowserPageState();
}
class _SeriesBrowserPageState extends State<SeriesBrowserPage> {
  String _sel = '__all', _query = '';
  List<String> _watching = [];
  @override
  void initState() { super.initState(); _loadWatching(); }
  @override
  void didUpdateWidget(covariant SeriesBrowserPage old) {
    super.didUpdateWidget(old);
    if (old.watchTick != widget.watchTick) _loadWatching();
  }
  Future<void> _loadWatching() async {
    final v = await Store.watchingSeries();
    if (mounted) setState(() => _watching = v);
  }
  bool _isFav(SeriesItem x) => widget.favorites.contains('series_${x.id}');

  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    for (final x in widget.items) {
      if (x.category.isNotEmpty) counts[x.category] = (counts[x.category] ?? 0) + 1;
    }
    final order = <String, int>{for (final x in widget.items) x.category: x.catOrder};
    final cats = counts.keys.toList()..sort((a, b) {
      final d = (order[a] ?? 9999).compareTo(order[b] ?? 9999);
      return d != 0 ? d : a.compareTo(b);
    });
    final byId = <String, SeriesItem>{for (final x in widget.items) x.id: x};
    final continueList = <SeriesItem>[
      for (final id in _watching) if (byId[id] != null) byId[id]!];
    Iterable<SeriesItem> base;
    if (_sel == '__all') { base = widget.items; }
    else if (_sel == '__fav') { base = widget.items.where(_isFav); }
    else if (_sel == '__continue') { base = continueList; }
    else if (_sel == '__recent') { base = widget.items.take(30); }
    else { base = widget.items.where((x) => x.category == _sel); }
    final q = _query.toLowerCase();
    final list = base.where((x) => x.name.toLowerCase().contains(q)).toList();
    return _BrowseLayout(
      entries: [
        _CatEntry('__all', 'ALL', widget.items.length),
        _CatEntry('__fav', 'FAVOURITES', widget.items.where(_isFav).length),
        _CatEntry('__continue', 'CONTINUE WATCHING', continueList.length),
        _CatEntry('__recent', 'RECENTLY ADDED', math.min(30, widget.items.length)),
        for (final c in cats) _CatEntry(c, c, counts[c] ?? 0),
      ],
      selected: _sel, hint: 'Search series', menu: widget.menu,
      onSelect: (v) => setState(() => _sel = v),
      onQuery: (v) => setState(() => _query = v),
      body: list.isEmpty
        ? const Center(child: Text('No series here yet'))
        : GridView.builder(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
            gridDelegate: _posterGrid(),
            itemCount: list.length, itemBuilder: (_, i) {
              final item = list[i];
              return _PosterCard(name: item.name, poster: item.poster,
                fallback: Icons.tv, fav: _isFav(item),
                onTap: () async {
                  await Navigator.push(context, MaterialPageRoute(
                    builder: (_) => SeriesDetailsPage(series: item, source: widget.source,
                      favorites: widget.favorites, onFavorite: widget.onFavorite)));
                  await _loadWatching();
                },
                onFav: () { widget.onFavorite(item.id); setState(() {}); });
            }),
    );
  }
}

String _fmtMs(int ms) {
  String two(int n) => n.toString().padLeft(2, '0');
  final d = Duration(milliseconds: ms);
  return '${two(d.inHours)}:${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}';
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
  static const _brand = Color(0xFFC8742B);
  SeriesDetails? _d;
  bool _loading = true;
  String? _error;
  int? _season;
  Map<String, int> _prog = {};
  String? _lastEp;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final d = await loadSeriesDetails(widget.source, widget.series.id);
      final prefs = await Store.p;
      final prog = <String, int>{
        for (final e in d.episodes) e.id: prefs.getInt('progress_episode_${e.id}') ?? 0};
      final last = await Store.lastEpisode(widget.series.id);
      int? season;
      for (final e in d.episodes) { if (e.id == last) season = e.season; }
      season ??= d.episodes.isEmpty ? null : d.episodes.first.season;
      if (mounted) setState(() { _d = d; _prog = prog; _lastEp = last; _season = season; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = '$e'; _loading = false; });
    }
  }

  List<Episode> get _episodes => _d?.episodes ?? const <Episode>[];
  List<int> get _seasons => _episodes.map((e) => e.season).toSet().toList()..sort();
  Episode? get _target {
    final eps = _episodes;
    if (eps.isEmpty) return null;
    for (final e in eps) { if (e.id == _lastEp) return e; }
    return eps.first;
  }

  Future<void> _reloadProgress() async {
    final prefs = await Store.p;
    final prog = <String, int>{
      for (final e in _episodes) e.id: prefs.getInt('progress_episode_${e.id}') ?? 0};
    final last = await Store.lastEpisode(widget.series.id);
    if (mounted) setState(() { _prog = prog; _lastEp = last; });
  }

  Future<void> _play(Episode ep) async {
    final list = _episodes.where((e) => e.season == ep.season).toList();
    final idx = math.max(0, list.indexWhere((e) => e.id == ep.id));
    await Navigator.push(context, MaterialPageRoute(builder: (_) => MediaPlayerPage(
      name: ep.name, url: ep.url, id: 'episode_${ep.id}', seriesId: widget.series.id,
      playlist: [for (final e in list) PlayItem('episode_${e.id}', e.name, e.url)],
      index: idx)));
    await _reloadProgress();
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  Widget _chip(String t, {IconData? icon}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(20)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      if (icon != null) ...[Icon(icon, size: 13, color: Colors.amber), const SizedBox(width: 3)],
      Text(t, style: const TextStyle(fontSize: 11.5)),
    ]));

  Widget _backdrop() {
    final url = (_d?.backdrop.isNotEmpty ?? false) ? _d!.backdrop : widget.series.poster;
    return Stack(fit: StackFit.expand, children: [
      if (url.isNotEmpty) ClipRect(child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Image.network(url, fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const SizedBox.shrink()))),
      Container(decoration: BoxDecoration(gradient: LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [Colors.black.withOpacity(.55), Colors.black.withOpacity(.93)]))),
    ]);
  }

  Widget _episodeTile(Episode ep) {
    final ms = _prog[ep.id] ?? 0;
    final isLast = _lastEp == ep.id;
    final frac = (ep.durationSecs > 0 && ms > 0)
        ? (ms / (ep.durationSecs * 1000)).clamp(0.0, 1.0).toDouble() : 0.0;
    final parts = <String>[
      'S${_two(ep.season)}E${_two(ep.number)}',
      if (ep.durationSecs > 0) '${(ep.durationSecs / 60).round()} min',
      if (ms > 0) 'Resume ${_fmtMs(ms)}',
    ];
    Widget thumbFallback() => Container(color: Colors.white10,
      child: const Center(child: Icon(Icons.tv, color: Colors.white38)));
    return InkWell(
      onTap: () => _play(ep),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.07),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: isLast ? _brand : Colors.transparent)),
        child: Row(children: [
          SizedBox(width: 128, height: 72, child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(fit: StackFit.expand, children: [
              ep.thumb.isEmpty ? thumbFallback()
                : Image.network(ep.thumb, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => thumbFallback()),
              Container(color: Colors.black26),
              const Center(child: Icon(Icons.play_circle_fill, size: 30, color: Colors.white70)),
              if (frac > 0) Positioned(left: 0, right: 0, bottom: 0, child: LinearProgressIndicator(
                value: frac, minHeight: 3, color: _brand, backgroundColor: Colors.black54)),
            ]))),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ep.name, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text(parts.join('  •  '), maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: isLast ? Colors.amber : Colors.white60)),
          ])),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final seasons = _seasons;
    final visible = _season == null
        ? _episodes : _episodes.where((e) => e.season == _season).toList();
    final fav = widget.favorites.contains('series_${widget.series.id}');
    final plot = (_d?.plot.isNotEmpty ?? false) ? _d!.plot : widget.series.plot;
    final t = _target;
    final tMs = t == null ? 0 : (_prog[t.id] ?? 0);
    final playLabel = t == null ? 'Play'
        : '${tMs > 0 ? 'Resume' : 'Play'} – S${t.season}:E${t.number}';
    final meta = <Widget>[
      if ((_d?.releaseDate ?? '').isNotEmpty) _chip(_d!.releaseDate, icon: Icons.calendar_today),
      if ((_d?.genre ?? '').isNotEmpty) _chip(_d!.genre),
      if ((_d?.rating ?? 0) > 0) _chip(_d!.rating.toStringAsFixed(1), icon: Icons.star),
    ];

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 16, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconButton(tooltip: 'Back', onPressed: () => Navigator.maybePop(context),
            icon: const Icon(Icons.arrow_back)),
          Expanded(child: Text(widget.series.name, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold))),
        ]),
        const SizedBox(height: 4),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(width: 8),
          Container(
            width: 128,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(8),
              boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 14, offset: Offset(0, 6))]),
            child: AspectRatio(aspectRatio: 2 / 3,
              child: Poster(widget.series.poster, fallback: Icons.tv))),
          const SizedBox(width: 16),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (meta.isNotEmpty) Wrap(spacing: 6, runSpacing: 6, children: meta),
            if ((_d?.director ?? '').isNotEmpty) Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Directed by: ${_d!.director}', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.white60))),
            if (plot.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(plot, maxLines: 3, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, height: 1.4, color: Colors.white70)),
              if (plot.length > 130) InkWell(
                onTap: () => showDialog<void>(context: context, builder: (_) => AlertDialog(
                  title: Text(widget.series.name),
                  content: SingleChildScrollView(child: Text(plot)),
                  actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))])),
                child: const Padding(padding: EdgeInsets.symmetric(vertical: 3),
                  child: Text('Read more', style: TextStyle(
                    color: _brand, fontSize: 12.5, fontWeight: FontWeight.bold)))),
            ],
            const SizedBox(height: 12),
            Row(children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: _brand,
                  foregroundColor: Colors.white, minimumSize: const Size(0, 42)),
                onPressed: t == null ? null : () => _play(t),
                icon: const Icon(Icons.play_arrow), label: Text(playLabel)),
              if (seasons.isNotEmpty) ...[
                const SizedBox(width: 10),
                PopupMenuButton<int>(
                  onSelected: (v) => setState(() => _season = v),
                  itemBuilder: (_) => [for (final n in seasons)
                    PopupMenuItem<int>(value: n, child: Text('Season $n'))],
                  child: Container(
                    height: 42, padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(color: Colors.white10,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white24)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('Season ${_season ?? seasons.first}'),
                      const SizedBox(width: 6),
                      const Icon(Icons.keyboard_arrow_down),
                    ]))),
              ],
              const SizedBox(width: 10),
              IconButton(
                tooltip: fav ? 'Remove from favourites' : 'Add to favourites',
                style: IconButton.styleFrom(backgroundColor: Colors.white10),
                onPressed: () { widget.onFavorite(widget.series.id); setState(() {}); },
                icon: Icon(fav ? Icons.favorite : Icons.favorite_border,
                  color: fav ? Colors.redAccent : Colors.white)),
            ]),
          ])),
        ]),
      ]),
    );

    return Scaffold(
      backgroundColor: const Color(0xFF110D0B),
      body: Stack(children: [
        Positioned.fill(child: _backdrop()),
        SafeArea(child: CustomScrollView(slivers: [
          SliverToBoxAdapter(child: header),
          SliverToBoxAdapter(child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text('Episodes (${visible.length})',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)))),
          if (_loading)
            const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(30),
              child: Center(child: CircularProgressIndicator())))
          else if (_error != null)
            SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(20),
              child: Center(child: Text(_error!))))
          else if (visible.isEmpty)
            const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(20),
              child: Center(child: Text('No episodes found'))))
          else
            SliverList(delegate: SliverChildBuilderDelegate(
              (context, i) => _episodeTile(visible[i]), childCount: visible.length)),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
        ])),
      ]),
    );
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

// ---------- shared helpers for the home screen ----------

const _gradHome = <Color>[Color(0xFFC8742B), Color(0xFFF2A65A)];
const _gradLive = <Color>[Color(0xFF1E88E5), Color(0xFF00C6FF)];
const _gradMovies = <Color>[Color(0xFF8E2DE2), Color(0xFFFF4E9B)];
const _gradSeries = <Color>[Color(0xFFFF512F), Color(0xFFF9A825)];

String _baseTitle(String n) =>
    n.replaceAll(RegExp(r'\s*\((?:SD|HD|FHD|UHD|4K)\)', caseSensitive: false), '').trim();

String _qualityOf(String n) {
  final m = RegExp(r'\((SD|HD|FHD|UHD|4K)\)', caseSensitive: false).firstMatch(n);
  return m == null ? 'Default' : m.group(1)!.toUpperCase();
}

BoxDecoration _cardDeco() => BoxDecoration(
  color: Colors.white.withOpacity(.06),
  borderRadius: BorderRadius.circular(16),
  border: Border.all(color: Colors.white10));

String _t12(DateTime d, {bool ampm = true}) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final s = '$h:${_p2(d.minute)}';
  return ampm ? '$s ${d.hour < 12 ? 'AM' : 'PM'}' : s;
}

class _Feat {
  final String kind, title, poster, sub, plot, favKey;
  final MediaItem? movie;
  final SeriesItem? series;
  const _Feat({required this.kind, required this.title, required this.poster,
    required this.sub, required this.plot, required this.favKey, this.movie, this.series});
}

class _NavItem {
  final IconData icon;
  final String label;
  final List<Color> colors;
  const _NavItem(this.icon, this.label, this.colors);
}

class _BottomNav extends StatelessWidget {
  final int index;
  final ValueChanged<int> onTap;
  const _BottomNav({required this.index, required this.onTap});
  static const _items = <_NavItem>[
    _NavItem(Icons.home_rounded, 'Home', _gradHome),
    _NavItem(Icons.live_tv_rounded, 'Live TV', _gradLive),
    _NavItem(Icons.movie_filter_rounded, 'Movies', _gradMovies),
    _NavItem(Icons.video_library_rounded, 'Series', _gradSeries),
  ];
  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(color: Color(0xFF15100D),
      border: Border(top: BorderSide(color: Colors.white10))),
    child: SafeArea(top: false, child: SizedBox(height: 56, child: Row(children: [
      for (var i = 0; i < _items.length; i++) Expanded(child: InkWell(
        onTap: () => onTap(i),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: index == i ? 50 : 34, height: 26,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
              gradient: index == i ? LinearGradient(colors: _items[i].colors) : null,
              boxShadow: index == i ? [BoxShadow(
                color: _items[i].colors.first.withOpacity(.45), blurRadius: 10, offset: const Offset(0, 3))] : null),
            child: Icon(_items[i].icon, size: 19,
              color: index == i ? Colors.white : Colors.white54)),
          const SizedBox(height: 3),
          Text(_items[i].label, style: TextStyle(fontSize: 10.5,
            fontWeight: index == i ? FontWeight.bold : FontWeight.normal,
            color: index == i ? Colors.white : Colors.white54)),
        ]))),
    ]))));
}

class _ClockText extends StatefulWidget {
  const _ClockText();
  @override
  State<_ClockText> createState() => _ClockTextState();
}
class _ClockTextState extends State<_ClockText> {
  Timer? _t;
  DateTime _now = DateTime.now();
  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }
  @override
  void dispose() { _t?.cancel(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
      Text('${_p2(_now.hour)}:${_p2(_now.minute)}',
        style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700, height: 1.05)),
      Text('${days[_now.weekday - 1]}, ${_now.day} ${months[_now.month - 1]}',
        style: const TextStyle(fontSize: 11, color: Colors.white60)),
    ]);
  }
}

class _HeroBanner extends StatefulWidget {
  final List<_Feat> items;
  final Set<String> favorites;
  final void Function(_Feat) onPlay, onFav;
  const _HeroBanner({required this.items, required this.favorites,
    required this.onPlay, required this.onFav});
  @override
  State<_HeroBanner> createState() => _HeroBannerState();
}
class _HeroBannerState extends State<_HeroBanner> {
  int _i = 0;
  Timer? _t;
  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 8), (_) {
      if (mounted && widget.items.length > 1) setState(() => _i = (_i + 1) % widget.items.length);
    });
  }
  @override
  void dispose() { _t?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    final f = widget.items[_i % widget.items.length];
    final fav = widget.favorites.contains(f.favKey);
    return SizedBox(height: 214, child: ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 500),
        child: KeyedSubtree(key: ValueKey(f.favKey), child: Stack(fit: StackFit.expand, children: [
          ClipRect(child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
            child: Image.network(f.poster, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(color: const Color(0xFF2A1B12))))),
          Container(decoration: BoxDecoration(gradient: LinearGradient(
            begin: Alignment.centerLeft, end: Alignment.centerRight,
            colors: [Colors.black.withOpacity(.88), Colors.black.withOpacity(.45)]))),
          Padding(padding: const EdgeInsets.fromLTRB(22, 14, 22, 18), child: Row(children: [
            Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: const Color(0xFFC8742B),
                      borderRadius: BorderRadius.circular(6)),
                    child: Text(f.kind, style: const TextStyle(
                      fontSize: 10.5, fontWeight: FontWeight.bold, letterSpacing: .6))),
                  const SizedBox(width: 8),
                  Expanded(child: Text(f.sub, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.white70))),
                ]),
                const SizedBox(height: 8),
                Text(f.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, height: 1.12)),
                if (f.plot.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(f.plot, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, height: 1.35, color: Colors.white70)),
                ],
                const SizedBox(height: 12),
                Row(children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC8742B),
                      foregroundColor: Colors.white, minimumSize: const Size(0, 40)),
                    onPressed: () => widget.onPlay(f),
                    icon: const Icon(Icons.play_arrow_rounded), label: const Text('Play Now')),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white38), minimumSize: const Size(0, 40)),
                    onPressed: () => widget.onFav(f),
                    icon: Icon(fav ? Icons.favorite : Icons.favorite_border, size: 18,
                      color: fav ? Colors.redAccent : Colors.white),
                    label: const Text('My List')),
                ]),
              ])),
            const SizedBox(width: 16),
            SizedBox(width: 112, child: Container(
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(10),
                boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 14, offset: Offset(0, 6))]),
              child: AspectRatio(aspectRatio: 2 / 3, child: Poster(f.poster)))),
          ])),
          Positioned(left: 22, bottom: 6, child: Row(children: [
            for (var d = 0; d < widget.items.length; d++) AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              margin: const EdgeInsets.only(right: 5), height: 5,
              width: d == _i % widget.items.length ? 18 : 5,
              decoration: BoxDecoration(
                color: d == _i % widget.items.length ? const Color(0xFFC8742B) : Colors.white38,
                borderRadius: BorderRadius.circular(3))),
          ])),
        ])),
      )));
  }
}

class _QuickTile extends StatelessWidget {
  final String label, countText;
  final IconData icon;
  final List<Color> colors;
  final VoidCallback onTap;
  const _QuickTile({required this.label, required this.countText, required this.icon,
    required this.colors, required this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap, borderRadius: BorderRadius.circular(16),
    child: Container(
      height: 74, padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
        boxShadow: [BoxShadow(color: colors.first.withOpacity(.35), blurRadius: 14, offset: const Offset(0, 6))]),
      child: Row(children: [
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(color: Colors.white.withOpacity(.22), borderRadius: BorderRadius.circular(13)),
          child: Icon(icon, size: 26, color: Colors.white)),
        const SizedBox(width: 12),
        Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            Text(countText, style: const TextStyle(fontSize: 11.5, color: Colors.white70)),
          ])),
        const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: Colors.white70),
      ])));
}

class _ContinueCard extends StatelessWidget {
  final String title, subtitle, poster;
  final VoidCallback onTap;
  const _ContinueCard({required this.title, required this.subtitle,
    required this.poster, required this.onTap});
  @override
  Widget build(BuildContext context) => SizedBox(width: 196, child: InkWell(
    onTap: onTap, borderRadius: BorderRadius.circular(14),
    child: ClipRRect(borderRadius: BorderRadius.circular(14), child: Stack(fit: StackFit.expand, children: [
      poster.isEmpty ? Container(color: Colors.white10)
        : Image.network(poster, fit: BoxFit.cover, alignment: const Alignment(0, -.5),
            errorBuilder: (_, __, ___) => Container(color: Colors.white10)),
      Container(decoration: BoxDecoration(gradient: LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [Colors.black.withOpacity(.1), Colors.black.withOpacity(.88)]))),
      const Center(child: Icon(Icons.play_circle_fill_rounded, size: 40, color: Colors.white70)),
      Positioned(left: 10, right: 10, bottom: 8, child: Column(
        mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Colors.white70)),
        ])),
    ]))));
}

class _PrayerCard extends StatefulWidget {
  const _PrayerCard();
  @override
  State<_PrayerCard> createState() => _PrayerCardState();
}
class _PrayerCardState extends State<_PrayerCard> {
  static const _names = ['Fajr', 'Dhuhr', 'Asr', 'Maghrib', 'Isha'];
  static const _ar = {'Fajr': 'الفجر', 'Dhuhr': 'الظهر', 'Asr': 'العصر', 'Maghrib': 'المغرب', 'Isha': 'العشاء'};
  Map<String, DateTime>? _t;
  String _city = 'Cairo', _country = 'Egypt';
  bool _failed = false;
  int _loadedDay = -1;
  DateTime _now = DateTime.now();
  Timer? _tick;

  @override
  void initState() { super.initState(); _boot(); }
  @override
  void dispose() { _tick?.cancel(); super.dispose(); }

  Future<void> _boot() async {
    _city = await Store.prayerCity();
    _country = await Store.prayerCountry();
    await _load();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
      if (_now.day != _loadedDay) _load();
    });
  }

  Future<void> _load() async {
    try {
      final t = await loadPrayerTimes(_city, _country, DateTime.now());
      _loadedDay = DateTime.now().day;
      if (mounted) setState(() { _t = t; _failed = false; });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _editPlace() async {
    final city = TextEditingController(text: _city);
    final country = TextEditingController(text: _country);
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Prayer times location'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: city, decoration: const InputDecoration(labelText: 'City (English)')),
        const SizedBox(height: 8),
        TextField(controller: country, decoration: const InputDecoration(labelText: 'Country (English)')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
      ]));
    if (ok != true) return;
    final c = city.text.trim(), k = country.text.trim();
    if (c.isEmpty || k.isEmpty) return;
    _city = c; _country = k;
    await Store.savePrayerPlace(c, k);
    if (mounted) setState(() { _t = null; _failed = false; });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    String? next;
    if (t != null) {
      for (final n in _names) { if (t[n]!.isAfter(_now)) { next = n; break; } }
    }
    Widget body;
    if (t == null) {
      body = Expanded(child: Center(child: _failed
        ? TextButton.icon(onPressed: _load, icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Couldn’t load — tap to retry'))
        : const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))));
    } else {
      final nextName = next ?? 'Fajr';
      final nextTime = next != null ? t[nextName]! : t['Fajr']!.add(const Duration(days: 1));
      final diff = nextTime.difference(_now);
      final left = diff.inHours > 0
          ? '${diff.inHours}h ${diff.inMinutes.remainder(60)}m' : '${math.max(1, diff.inMinutes)}m';
      body = Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Next • $nextName  ${_ar[nextName]}',
              style: const TextStyle(fontSize: 11.5, color: Colors.white70)),
            Text(_t12(nextTime), style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w800, height: 1.1)),
          ]),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(color: const Color(0xFFC8742B).withOpacity(.25),
              borderRadius: BorderRadius.circular(20)),
            child: Text('in $left', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
              color: Color(0xFFFFC27A)))),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          for (final n in _names) Expanded(child: Container(
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: n == next ? Colors.white.withOpacity(.12) : null,
              borderRadius: BorderRadius.circular(8)),
            child: Column(children: [
              Text(n, style: TextStyle(fontSize: 9.5,
                color: n == next ? const Color(0xFFFFC27A) : Colors.white54)),
              Text(_t12(t[n]!, ampm: false), style: TextStyle(fontSize: 12,
                fontWeight: FontWeight.w700, color: n == next ? Colors.white : Colors.white70)),
            ]))),
        ]),
      ]));
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10), decoration: _cardDeco(),
      child: Column(children: [
        Row(children: [
          const Icon(Icons.nights_stay_rounded, size: 17, color: Color(0xFFFFC27A)),
          const SizedBox(width: 6),
          const Text('Prayer times', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
          const Spacer(),
          InkWell(onTap: _editPlace, borderRadius: BorderRadius.circular(8), child: Padding(
            padding: const EdgeInsets.all(2),
            child: Row(children: [
              Text(_city, style: const TextStyle(fontSize: 11, color: Colors.white60)),
              const SizedBox(width: 3),
              const Icon(Icons.edit_location_alt_rounded, size: 14, color: Colors.white54),
            ]))),
        ]),
        body,
      ]));
  }
}

class _MatchesCard extends StatefulWidget {
  const _MatchesCard();
  @override
  State<_MatchesCard> createState() => _MatchesCardState();
}
class _MatchesCardState extends State<_MatchesCard> {
  List<MatchItem>? _m;
  bool _failed = false;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _load();
    _t = Timer.periodic(const Duration(minutes: 5), (_) => _load());
  }
  @override
  void dispose() { _t?.cancel(); super.dispose(); }

  Future<void> _load() async {
    try {
      final m = await loadMatches(DateTime.now());
      if (mounted) setState(() { _m = m; _failed = false; });
    } catch (_) {
      if (mounted && _m == null) setState(() => _failed = true);
    }
  }

  Widget _logo(String url) => SizedBox(width: 30, height: 30, child: url.isEmpty
    ? const Icon(Icons.shield_outlined, size: 24, color: Colors.white38)
    : Image.network(url, fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => const Icon(Icons.shield_outlined, size: 24, color: Colors.white38)));

  Widget _tile(MatchItem x) {
    final live = x.state == 'in';
    final done = x.state == 'post';
    final center = (live || done) ? '${x.homeScore} - ${x.awayScore}'
        : '${_p2(x.time.hour)}:${_p2(x.time.minute)}';
    return Container(
      width: 178, margin: const EdgeInsets.only(right: 10),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(color: Colors.white.withOpacity(.07), borderRadius: BorderRadius.circular(12),
        border: Border.all(color: live ? Colors.redAccent.withOpacity(.7) : Colors.transparent)),
      child: Column(children: [
        Text(x.league, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10, color: Colors.white54)),
        const SizedBox(height: 5),
        Row(children: [
          Expanded(child: Column(children: [
            _logo(x.homeLogo),
            const SizedBox(height: 2),
            Text(x.home, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600)),
          ])),
          Column(mainAxisSize: MainAxisSize.min, children: [
            Text(center, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(live ? 'LIVE ${x.detail}' : (done ? 'FT' : 'Kick-off'),
              style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold,
                color: live ? Colors.redAccent : Colors.white54)),
          ]),
          Expanded(child: Column(children: [
            _logo(x.awayLogo),
            const SizedBox(height: 2),
            Text(x.away, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600)),
          ])),
        ]),
      ]));
  }

  @override
  Widget build(BuildContext context) {
    final m = _m;
    Widget body;
    if (m == null) {
      body = Center(child: _failed
        ? TextButton.icon(onPressed: () { setState(() => _failed = false); _load(); },
            icon: const Icon(Icons.refresh, size: 18), label: const Text('Couldn’t load matches — tap to retry'))
        : const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)));
    } else if (m.isEmpty) {
      body = const Center(child: Text('No major matches today', style: TextStyle(color: Colors.white60)));
    } else {
      body = ListView.builder(scrollDirection: Axis.horizontal, itemCount: m.length,
        itemBuilder: (_, i) => _tile(m[i]));
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 8), decoration: _cardDeco(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.sports_soccer_rounded, size: 17, color: Color(0xFF7CE0A0)),
          const SizedBox(width: 6),
          const Text('Matches today', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
          const Spacer(),
          if (m != null && m.isNotEmpty) Padding(padding: const EdgeInsets.only(right: 8),
            child: Text('${m.length}', style: const TextStyle(fontSize: 11, color: Colors.white60))),
        ]),
        const SizedBox(height: 6),
        Expanded(child: body),
      ]));
  }
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
  List<SeriesItem> _watching = [];
  Map<String, int> _seriesMs = {};
  int _watchTick = 0;
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
    final ids = await Store.watchingSeries();
    final byId = <String, SeriesItem>{for (final s in _series) s.id: s};
    final watching = <SeriesItem>[];
    final ms = <String, int>{};
    for (final id in ids) {
      final s = byId[id];
      if (s == null) continue;
      watching.add(s);
      final ep = await Store.lastEpisode(id);
      ms[id] = ep == null ? 0 : await Store.progress('episode_$ep');
    }
    if (mounted) setState(() { _progress = values; _watching = watching; _seriesMs = ms; _watchTick++; });
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
  List<QualityOption> _qualitiesFor(MediaItem m) {
    final base = _baseTitle(m.name).toLowerCase();
    final seen = <String>{};
    final out = <QualityOption>[];
    for (final x in _movies) {
      if (_baseTitle(x.name).toLowerCase() != base) continue;
      final label = _qualityOf(x.name);
      if (seen.add(label)) out.add(QualityOption(label, x.url));
    }
    if (out.length < 2) return const <QualityOption>[];
    const rank = {'SD': 0, 'Default': 1, 'HD': 2, 'FHD': 3, 'UHD': 4, '4K': 5};
    out.sort((a, b) => (rank[a.label] ?? 1).compareTo(rank[b.label] ?? 1));
    return out;
  }
  Future<void> _playMovie(MediaItem m) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => MediaPlayerPage(
      name: m.name, url: m.url, id: 'movie_${m.id}', qualities: _qualitiesFor(m))));
    await _refreshProgress();
  }
  Future<void> _openSeries(SeriesItem s) async {
    final src = _source;
    if (src == null) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => SeriesDetailsPage(
      series: s, source: src, favorites: _mediaFavs, onFavorite: _toggleSeriesFav)));
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

  List<_Feat> _featured() {
    final out = <_Feat>[];
    final seen = <String>{};
    final s = _series.take(40).toList();
    final m = _movies.take(40).toList();
    var si = 0, mi = 0;
    while (out.length < 6 && (si < s.length || mi < m.length)) {
      if (si < s.length) {
        final x = s[si++];
        if (x.poster.isNotEmpty && seen.add(_baseTitle(x.name).toLowerCase())) {
          out.add(_Feat(kind: 'SERIES', title: _baseTitle(x.name), poster: x.poster,
            sub: x.category, plot: x.plot, favKey: 'series_${x.id}', series: x));
        }
      }
      if (out.length < 6 && mi < m.length) {
        final x = m[mi++];
        if (x.poster.isNotEmpty && seen.add(_baseTitle(x.name).toLowerCase())) {
          out.add(_Feat(kind: 'MOVIE', title: _baseTitle(x.name), poster: x.poster,
            sub: x.category, plot: '', favKey: 'movie_${x.id}', movie: x));
        }
      }
    }
    return out;
  }

  List<MediaItem> _latestMovies() {
    final seen = <String>{};
    final out = <MediaItem>[];
    for (final x in _movies) {
      if (out.length >= 20) break;
      if (seen.add(_baseTitle(x.name).toLowerCase())) out.add(x);
    }
    return out;
  }

  List<SeriesItem> _latestSeries() {
    final seen = <String>{};
    final out = <SeriesItem>[];
    for (final x in _series) {
      if (out.length >= 20) break;
      if (seen.add(_baseTitle(x.name).toLowerCase())) out.add(x);
    }
    return out;
  }

  Widget _sectionTitle(String t, {String? trailing}) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 8),
    child: Row(children: [
      Container(width: 4, height: 18, decoration: BoxDecoration(
        color: const Color(0xFFC8742B), borderRadius: BorderRadius.circular(2))),
      const SizedBox(width: 8),
      Expanded(child: Text(t, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
      if (trailing != null) Text(trailing, style: const TextStyle(fontSize: 12, color: Colors.white54)),
    ]));

  Widget _posterRow<T>(List<T> items, Widget Function(T) card) => SizedBox(
    height: 176,
    child: ListView.separated(
      scrollDirection: Axis.horizontal, itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(width: 10),
      itemBuilder: (_, i) => SizedBox(width: 118, child: card(items[i]))));

  void _heroPlay(_Feat f) {
    if (f.movie != null) { _playMovie(f.movie!); }
    else if (f.series != null) { _openSeries(f.series!); }
  }
  void _heroFav(_Feat f) {
    if (f.movie != null) { _toggleMovieFav(f.movie!); }
    else if (f.series != null) { _toggleSeriesFav(f.series!.id); }
  }

  Widget _homeBody() {
    final latestSeries = _latestSeries();
    final latestMovies = _latestMovies();
    final recentMovies = _movies.where((m) => (_progress['movie_${m.id}'] ?? 0) > 0).toList()
      ..sort((a, b) => (_progress['movie_${b.id}'] ?? 0).compareTo(_progress['movie_${a.id}'] ?? 0));
    final cont = <Widget>[
      for (final s in _watching) _ContinueCard(
        title: _baseTitle(s.name),
        subtitle: (_seriesMs[s.id] ?? 0) > 0 ? 'Series • Resume ${_fmtMs(_seriesMs[s.id] ?? 0)}' : 'Series • Continue',
        poster: s.poster, onTap: () => _openSeries(s)),
      for (final m in recentMovies) _ContinueCard(
        title: _baseTitle(m.name),
        subtitle: 'Movie • Resume ${_fmtMs(_progress['movie_${m.id}'] ?? 0)}',
        poster: m.poster, onTap: () => _playMovie(m)),
    ];
    return ListView(padding: const EdgeInsets.fromLTRB(16, 6, 16, 20), children: [
      Row(children: [
        ShaderMask(
          shaderCallback: (r) => const LinearGradient(
            colors: [Color(0xFFFFD29A), Color(0xFFC8742B)]).createShader(r),
          child: const Text('MOKA IPTV', style: TextStyle(fontSize: 23,
            fontWeight: FontWeight.w900, letterSpacing: 1.3, color: Colors.white))),
        if (_source != null) Padding(padding: const EdgeInsets.only(left: 10, top: 4),
          child: Text(_source!.name, style: const TextStyle(fontSize: 11.5, color: Colors.white54))),
        const Spacer(),
        const _ClockText(),
        const SizedBox(width: 4),
        _menuButton(),
      ]),
      const SizedBox(height: 8),
      _HeroBanner(items: _featured(), favorites: _mediaFavs, onPlay: _heroPlay, onFav: _heroFav),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: _QuickTile(label: 'Live TV', countText: '${_channels.length} channels',
          icon: Icons.live_tv_rounded, colors: _gradLive, onTap: () => setState(() => _tab = 1))),
        const SizedBox(width: 10),
        Expanded(child: _QuickTile(label: 'Movies', countText: '${_movies.length} titles',
          icon: Icons.movie_filter_rounded, colors: _gradMovies, onTap: () => setState(() => _tab = 2))),
        const SizedBox(width: 10),
        Expanded(child: _QuickTile(label: 'Series', countText: '${_series.length} shows',
          icon: Icons.video_library_rounded, colors: _gradSeries, onTap: () => setState(() => _tab = 3))),
      ]),
      const SizedBox(height: 14),
      const SizedBox(height: 158, child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(flex: 4, child: _PrayerCard()),
        SizedBox(width: 12),
        Expanded(flex: 6, child: _MatchesCard()),
      ])),
      if (cont.isNotEmpty) ...[
        _sectionTitle('Continue Watching', trailing: '${cont.length}'),
        SizedBox(height: 112, child: ListView.separated(
          scrollDirection: Axis.horizontal, itemCount: cont.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (_, i) => cont[i])),
      ],
      if (latestSeries.isNotEmpty) ...[
        _sectionTitle('Latest Series'),
        _posterRow<SeriesItem>(latestSeries, (s) => _PosterCard(
          name: s.name, poster: s.poster, fallback: Icons.tv,
          fav: _mediaFavs.contains('series_${s.id}'),
          onTap: () => _openSeries(s), onFav: () => _toggleSeriesFav(s.id))),
      ],
      if (latestMovies.isNotEmpty) ...[
        _sectionTitle('Latest Movies'),
        _posterRow<MediaItem>(latestMovies, (m) => _PosterCard(
          name: m.name, poster: m.poster,
          fav: _mediaFavs.contains('movie_${m.id}'),
          onTap: () => _playMovie(m), onFav: () => _toggleMovieFav(m))),
      ],
    ]);
  }

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

  Widget _menuButton() => PopupMenuButton<String>(
    icon: const Icon(Icons.more_vert),
    onSelected: (v) {
      if (v == 'account') { _openAccount(); }
      else if (v == 'settings') { _openSettings(); }
      else if (v == 'refresh') { if (!_loading && _source != null) _connect(_source!); }
      else if (v == 'logout') { _logout(); }
    },
    itemBuilder: (_) => const [
      PopupMenuItem(value: 'refresh', child: Text('Refresh')),
      PopupMenuItem(value: 'account', child: Text('Account')),
      PopupMenuItem(value: 'settings', child: Text('Settings')),
      PopupMenuItem(value: 'logout', child: Text('Logout')),
    ]);

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_source == null) return LoginPage(onLogin: _login);
    final pages = <Widget>[
      _homeBody(),
      _liveBody(),
      MediaGridPage(title: 'Movies', items: _movies, favorites: _mediaFavs,
        progress: _progress, menu: _menuButton(),
        onFavorite: _toggleMovieFav, onPlay: _playMovie),
      SeriesBrowserPage(items: _series, source: _source!, favorites: _mediaFavs,
        menu: _menuButton(), watchTick: _watchTick, onFavorite: _toggleSeriesFav),
    ];
    return Scaffold(
      appBar: _tab != 1 ? null : AppBar(toolbarHeight: 46, title: const Text('MOKA IPTV', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 19)),
        actions: [
          IconButton(tooltip: 'Account details', onPressed: _openAccount, icon: const Icon(Icons.account_circle)),
          IconButton(tooltip: 'Settings', onPressed: _openSettings, icon: const Icon(Icons.settings)),
          IconButton(tooltip: 'Logout', onPressed: _logout, icon: const Icon(Icons.logout)),
          IconButton(tooltip: 'Refresh', onPressed: _loading ? null : () => _connect(_source!), icon: const Icon(Icons.refresh)),
        ]),
      body: SafeArea(bottom: false, child: Column(children: [
        if (_loading) const LinearProgressIndicator(),
        if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
        Expanded(child: IndexedStack(index: _tab, children: pages)),
      ])),
      bottomNavigationBar: _BottomNav(index: _tab, onTap: (i) => setState(() => _tab = i)),
    );
  }
}
