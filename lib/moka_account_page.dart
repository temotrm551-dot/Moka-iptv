
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'main.dart' hide main;

class MokaAccountPage extends StatefulWidget {
  final VoidCallback onLogout;

  const MokaAccountPage({
    super.key,
    required this.onLogout,
  });

  @override
  State<MokaAccountPage> createState() => _MokaAccountPageState();
}

class _MokaAccountPageState extends State<MokaAccountPage> {
  Source? source;
  Map<String, dynamic>? info;
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    loadAccount();
  }

  Future<void> loadAccount() async {
    try {
      final sources = await Store.sources();
      final index = await Store.active();

      if (sources.isEmpty || index < 0 || index >= sources.length) {
        if (mounted) {
          setState(() {
            loading = false;
            error = 'لا يوجد اشتراك مسجل';
          });
        }
        return;
      }

      source = sources[index];

      if (source!.user.isEmpty || source!.pass.isEmpty) {
        throw Exception('بيانات الاشتراك غير مكتملة');
      }

      final uri = Uri.parse(source!.url.trim());
      final apiUri = uri.replace(
        path: '/player_api.php',
        queryParameters: {
          'username': source!.user,
          'password': source!.pass,
        },
      );

      final response = await http
          .get(apiUri)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception('تعذر الاتصال بالسيرفر');
      }

      final data = jsonDecode(response.body);

      if (data is! Map || data['user_info'] is! Map) {
        throw Exception('بيانات الاشتراك غير صالحة');
      }

      if (mounted) {
        setState(() {
          info = Map<String, dynamic>.from(data['user_info']);
          loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString().replaceFirst('Exception: ', '');
          loading = false;
        });
      }
    }
  }

  String expiryDate() {
    final value = info?['exp_date']?.toString() ?? '';
    if (value.isEmpty || value == '0') return 'غير محدد';

    final timestamp = int.tryParse(value);
    if (timestamp == null) return 'غير محدد';

    final date = DateTime.fromMillisecondsSinceEpoch(
      timestamp * 1000,
    );

    return '${date.day}/${date.month}/${date.year}';
  }

  Future<void> logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تسجيل الخروج'),
        content: const Text('هل تريد حذف الاشتراك الحالي من التطبيق؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('خروج'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final sources = await Store.sources();
    final index = await Store.active();

    if (index >= 0 && index < sources.length) {
      sources.removeAt(index);
    }

    await Store.saveSources(sources);
    await Store.saveActive(0);

    if (!mounted) return;
    widget.onLogout();
  }

  Widget detail(String title, String value, IconData icon) {
    return Card(
      child: ListTile(
        leading: Icon(icon, color: const Color(0xFFC8742B)),
        title: Text(title),
        subtitle: Text(
          value.isEmpty ? 'غير متاح' : value,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const orange = Color(0xFFC8742B);

    return Scaffold(
      appBar: AppBar(
        title: const Text('حسابي'),
        centerTitle: true,
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const CircleAvatar(
                  radius: 38,
                  backgroundColor: orange,
                  child: Icon(Icons.person, size: 42, color: Colors.white),
                ),
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    source?.name ?? 'MOKA IPTV',
                    style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 22),

                if (error != null) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        error!,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {
                      setState(() {
                        loading = true;
                        error = null;
                      });
                      loadAccount();
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('إعادة المحاولة'),
                  ),
                ] else ...[
                  detail(
                    'اسم المستخدم',
                    info?['username']?.toString() ?? source?.user ?? '',
                    Icons.person_outline,
                  ),
                  detail(
                    'حالة الاشتراك',
                    info?['status']?.toString() ?? 'غير معروف',
                    Icons.verified_user_outlined,
                  ),
                  detail(
                    'تاريخ الانتهاء',
                    expiryDate(),
                    Icons.calendar_month,
                  ),
                  detail(
                    'الأجهزة المتصلة',
                    '${info?['active_cons'] ?? 0} / ${info?['max_connections'] ?? 0}',
                    Icons.devices,
                  ),
                  detail(
                    'نوع الاشتراك',
                    info?['is_trial']?.toString() == '1'
                        ? 'تجريبي'
                        : 'اشتراك عادي',
                    Icons.card_membership,
                  ),
                ],

                const SizedBox(height: 18),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.settings, color: orange),
                    title: const Text('الإعدادات'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SettingsPage(),
                        ),
                      );
                    },
                  ),
                ),
                Card(
                  child: ListTile(
                    leading: const Icon(
                      Icons.logout,
                      color: Colors.red,
                    ),
                    title: const Text(
                      'تسجيل الخروج',
                      style: TextStyle(color: Colors.red),
                    ),
                    onTap: logout,
                  ),
                ),
              ],
            ),
    );
  }
}
