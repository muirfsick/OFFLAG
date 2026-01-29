import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import '../theme.dart';
import '../widgets/widgets.dart';
import '../net.dart';
import '../models/user_profile.dart';
import '../models/vpn_node.dart';
import '../vpn_controller.dart';
import 'home_screen.dart';
import 'profile_screen.dart';
import 'servers.dart';

class MainTabs extends StatefulWidget {
  const MainTabs({super.key});

  @override
  State<MainTabs> createState() => _MainTabsState();
}

class _MainTabsState extends State<MainTabs> with TickerProviderStateMixin {
  int _index = 0;
  bool _connected = false;

  late final PageController _pageCtrl = PageController(initialPage: _index);

  UserProfile? _me;
  bool _loadingMe = false;

  VpnNode? _bestNode;
  int? _bestPingMs;
  bool _loadingVpn = false;

  /// Универсальный контроллер VPN (Windows + Android).
  final VpnController _vpn = VpnController();

  Timer? _pingTimer;

  @override
  void initState() {
    super.initState();
    _fetchMe();
    _loadVpn();
    _startPingTimer();

    // Реактивно обновляем UI при изменении состояния VPN.
    _vpn.status.addListener(() {
      if (!mounted) return;
      setState(() => _connected = _vpn.isRunning);
    });
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    _pageCtrl.dispose();

    // На Windows выключаем при закрытии UI; на Android оставляем сервис работать.
    if (Platform.isWindows) {
      _vpn.disconnect();
    }

    super.dispose();
  }

  Future<void> _fetchMe() async {
    setState(() => _loadingMe = true);
    try {
      final res = await dio.get('/profile');
      final data = res.data is Map
          ? (res.data as Map<String, dynamic>)
          : <String, dynamic>{};
      setState(() => _me = UserProfile.fromMap(data));
    } catch (e, st) {
      debugPrint('GET /profile failed: $e\n$st');
    } finally {
      if (mounted) setState(() => _loadingMe = false);
    }
  }

  Future<void> _loadVpn({bool fast = false}) async {
    setState(() => _loadingVpn = true);
    try {
      final nodes = await fetchVpnNodes();
      final result = await findBestNode(
        nodes,
        timeout: fast ? const Duration(seconds: 1) : const Duration(seconds: 2),
        tries: fast ? 1 : 3,
      );
      if (!mounted) return;

      setState(() {
        _bestNode = result.best;
        _bestPingMs =
        result.best != null ? result.pingsMs[result.best!.id] : null;
      });
    } catch (_) {
      // тихо падаем
    } finally {
      if (mounted) setState(() => _loadingVpn = false);
    }
  }

  Future<void> _refreshPing() async {
    final node = _bestNode;
    if (node == null) return;

    final hp = hostPortFromNode(node);
    if (hp == null) return;
    final ping = await measureTcpPing(hp.host, hp.port);
    if (!mounted) return;
    if (ping != null) {
      setState(() {
        _bestPingMs = ping;
      });
    }
  }

  Future<void> _disconnectVpnForLogout() async {
    if (!_connected) return;
    await _vpn.disconnect();
    if (!mounted) return;
    setState(() => _connected = false);
  }

  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(minutes: 1), (_) async {
      if (!_connected) return;
      await _refreshPing();
    });
  }

  Future<void> _waitForVpnLoad() async {
    // Wait until the initial node scan finishes.
    while (_loadingVpn && mounted) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<VpnNode?> _ensureBestNode({int attempts = 3}) async {
    for (var i = 0; i < attempts && mounted; i++) {
      if (_bestNode != null) return _bestNode;

      if (_loadingVpn) {
        await _waitForVpnLoad();
      } else {
        await _loadVpn(fast: true);
      }

      if (_bestNode != null) return _bestNode;

      // Short backoff before next attempt.
      await Future.delayed(const Duration(milliseconds: 700));
    }
    return _bestNode;
  }

  VoidCallback _showFindingServerDialog() {
    final nav = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              Text('Ищем лучший сервер...', textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
    return () {
      if (nav.canPop()) nav.pop();
    };
  }

  /// Переключает VPN: запускает или останавливает подключение.
  ///
  /// Детали платформы инкапсулированы в [VpnController]:
  /// - Windows: xray.exe (TUN)
  /// - Android: VpnService + flutter_v2ray_plus
  void _toggleConnection() async {
    // Отключение
    if (_connected) {
      await _vpn.disconnect();

      if (mounted) {
        setState(() => _connected = false);
      }
      return;
    }

    // Включение — нужна текущая нода.
    _bestNode = null;
    await _loadVpn(fast: true);
    var node = _bestNode;

    if (node == null) {
      final closeDialog = _showFindingServerDialog();
      try {
        node = await _ensureBestNode(attempts: 3);
      } finally {
        if (mounted) closeDialog();
      }
    }

    if (node == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет доступных серверов')),
      );
      return;
    }

    final ok = await _vpn.connect(node);

    if (!mounted) return;

    if (ok) {
      setState(() => _connected = true);
    } else {
      setState(() => _connected = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Не удалось запустить VPN'),
        ),
      );
    }
  }

  /// Открывает экран "Серверы", позволяет выбрать ноду и подключиться к ней.
  Future<void> _openServers(BuildContext context) async {
    final selected = await Navigator.of(context).push<VpnNode>(
      MaterialPageRoute(
        builder: (_) => ServersPage(includeAll: _me?.premiumActive ?? false),
      ),
    );

    if (!mounted || selected == null) return;

    setState(() {
      _bestNode = selected;
      _bestPingMs = selected.pingMs ?? _bestPingMs;
    });

    // Если были подключены — сначала отключаемся
    if (_connected) {
      await _vpn.disconnect();
      if (!mounted) return;
      setState(() => _connected = false);
    }

    final ok = await _vpn.connect(selected);

    if (!context.mounted) return;

    if (ok) {
      setState(() => _connected = true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Не удалось подключиться к выбранному серверу'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final nodeForUi = _bestNode;
    final countryLabel = nodeForUi?.name ?? 'Netherlands';
    final countryCode = nodeForUi?.country ?? 'NL';
    final pingMs = _bestPingMs ?? 58;

    final pages = [
      HomeScreen(
        connected: _connected,
        onToggleConnection: _toggleConnection,
        me: _me,
        loadingMe: _loadingMe,
        onRefreshMe: _fetchMe,
        countryLabel: countryLabel,
        countryCode: countryCode,
        pingMs: pingMs,
        onOpenServers: _openServers,
      ),
      ProfileScreen(
        me: _me,
        loadingMe: _loadingMe,
        onRefreshMe: _fetchMe,
        onDisconnectVpn: _disconnectVpnForLogout,
      ),
    ];

    return Scaffold(
      body: SafeArea(
        child: PageView(
          controller: _pageCtrl,
          physics: const BouncingScrollPhysics(),
          onPageChanged: (i) => setState(() => _index = i),
          children: pages,
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: SizedBox(
          height: Ui.ovalH,
          child: BottomOvalNav(
            currentIndex: _index,
            onTap: (i) {
              setState(() => _index = i);
              _pageCtrl.animateToPage(
                i,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeInOut,
              );
            },
          ),
        ),
      ),
    );
  }
}
