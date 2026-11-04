
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'main.dart' hide main;

class MokaAccountPage extends StatefulWidget {
  const MokaAccountPage({super.key});

  @override
  State<MokaAccountPage> createState() => _MokaAccountPageState();
}

class _MokaAccountPageState extends State<MokaAccountPage> {
  Source? source;
  Map<String, dynamic> info = {};
  bool loading = true;
  String error = '';

  @override
  void initState() {
    super.initState();
    loadAccount();
  }

  Future<void> loadAccount() async {
    setState(() {
      loading = true;
      error = '';
    });

    try {
      final sources = await Store.sources();
      final active = await Store.active();

      if (sources.isEmpty || active >= sources.length) {
        throw Exception('لا يوجد حساب مسجل');
      }

      source = sources[active];

      var base = source!.url.trim();
      if (!base.startsWith('http')) base = 'http://$base';
      if (!base.endsWith('/')) base += '/';

      final uri = Uri.parse(
        '${base}player_api.php',
      ).replace(queryParameters: {
        'username': source!.user,
        'password': source!.pass,
      });

      final response = await http.get(uri).timeout(
        const Duration(seconds: 15),
      );

      final data = jsonDecode(response.body);
      if (data is! Map || data['user_info'] == null) {
        throw Exception('بيانات الاشتراك غير متاحة');
      }

      if (!mounted) return;
      setState(() {
        info = Map<String, dynamic>.from(data['user_info']);
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.toString().replaceFirst('Exception: ', '');
        loading = false;
      });
    }
  }

  String value(String key) {
    final v = info[key];
    if (v == null || v.toString().isEmpty) return 'غير متاح';
    return v.toString();
  }

  String expiry() {
    final raw = info['exp_date']?.toString() ?? '';
    if (raw.isEmpty || raw == '0') return 'غير محدد';

    final timestamp = int.tryParse(raw);
    if (timestamp == null) return raw;

    final date = DateTime.fromMillisecondsSinceEpoch(
      timestamp * 1000,
    );

    return '${date.day}/${date.month}/${date.year}';
  }

  Future<void> logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xff20202b),
        title: const Text(
          'تسجيل الخروج',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'هل تريد حذف الحساب الحالي من التطبيق؟',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'خروج',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final sources = await Store.sources();
    final active = await Store.active();

    if (active < sources.length) {
      sources.removeAt(active);
    }

    await Store.saveSources(sources);
    await Store.saveActive(0);

    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomePage()),
      (route) => false,
    );
  }

  Widget item(String title, String data, IconData icon) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xff20202b),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.deepPurpleAccent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(color: Colors.white60)),
                const SizedBox(height: 5),
                Text(
                  data,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xff11111a),
      appBar: AppBar(
        backgroundColor: const Color(0xff191923),
        title: const Text('حسابي وإعدادات MOKA'),
        actions: [
          IconButton(
            onPressed: loadAccount,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(18),
              children: [
                const Icon(
                  Icons.account_circle,
                  size: 75,
                  color: Colors.deepPurpleAccent,
                ),
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    source?.name ?? 'حسابي',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 25),
                if (error.isNotEmpty)
                  Text(
                    error,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                item('اسم المستخدم', source?.user ?? '-', Icons.person),
                item('حالة الاشتراك', value('status'), Icons.verified_user),
                item('تاريخ انتهاء الاشتراك', expiry(), Icons.event),
                item('الاتصالات الحالية', value('active_cons'), Icons.devices),
                item('الحد الأقصى للأجهزة', value('max_connections'), Icons.tv),
                item('نوع الحساب', value('is_trial') == '1' ? 'تجريبي' : 'عادي', Icons.card_membership),
                const SizedBox(height: 15),
                const Text(
                  'الإعدادات',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  tileColor: const Color(0xff20202b),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  leading: const Icon(Icons.settings, color: Colors.white),
                  title: const Text(
                    'إعدادات التطبيق',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: const Text(
                    'إعدادات الحساب والتطبيق',
                    style: TextStyle(color: Colors.white54),
                  ),
                  onTap: () {
                    showAboutDialog(
                      context: context,
                      applicationName: 'MOKA IPTV',
                      applicationVersion: '1.0.0',
                      applicationLegalese: 'MOKA IPTV',
                    );
                  },
                ),
                const SizedBox(height: 22),
                SizedBox(
                  height: 52,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: logout,
                    icon: const Icon(Icons.logout),
                    label: const Text('تسجيل الخروج'),
                  ),
                ),
              ],
            ),
    );
  }
}
