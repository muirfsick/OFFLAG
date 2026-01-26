import 'package:dio/dio.dart';
import 'dart:io' show Socket;
import 'package:flutter/foundation.dart';

import 'models/vpn_node.dart';

/// Текущая сессия пользователя.
///
/// Хранит минимальный набор данных, необходимых для авторизованных запросов.
/// Токен (обычно JWT) автоматически подставляется в заголовок `Authorization`
/// всеми вызовами через глобальный клиент [`dio`].
class Session {
  /// Токен авторизации (например, «сырой» JWT без префикса `Bearer`).
  static String? token;

  /// E-mail текущего пользователя (если известен).
  static String? email;
}

/// Глобальный HTTP-клиент для работы с API.
///
/// Настроен с:
/// - `baseUrl`: адрес backend-сервера;
/// - `connectTimeout` и `receiveTimeout`: жёсткие таймауты по 10 секунд;
/// - перехватчиком (`InterceptorsWrapper`), который добавляет заголовок
///   `Authorization` со значением [`Session.token`], если токен присутствует.
///
/// Сервер ожидает **«сырой» JWT без префикса `Bearer`**, поэтому заголовок
/// формируется как `Authorization: <jwt>`.
final dio = Dio(
  BaseOptions(
    baseUrl: 'https://api.lisovcoff.ru',
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
  ),
)
  ..interceptors.add(
    InterceptorsWrapper(
      /// Перехватчик исходящих запросов.
      ///
      /// Если в [`Session.token`] есть значение, добавляет заголовок
      /// `Authorization` ко всем запросам. После модификации передаёт управление
      /// следующему обработчику через `handler.next(options)`.
      onRequest: (options, handler) {
        final t = Session.token;
        if (t != null && t.isNotEmpty) {
          options.headers['Authorization'] = t;
        }
        handler.next(options);
      },
    ),
  );

/// Забираем список нод с бэка.
Future<List<VpnNode>> fetchVpnNodes() async {
  final resp = await dio.get('/vpn/nodes');
  final data = resp.data as List<dynamic>;
  return data.map((e) => VpnNode.fromJson(e as Map<String, dynamic>)).toList();
}

/// Измеряем "пинг" как минимум из нескольких TCP-подключений к host:port.
/// Возвращаем среднее значение по успешным попыткам,
/// с минимальным визуальным порогом (например, 42 мс).
Future<int?> measureTcpPing(
  String host,
  int port, {
  Duration timeout = const Duration(seconds: 2),
  bool clampForUi = true, // 👈 по умолчанию — честное значение
  int tries = 3,
}) async {
  const minVisualPingMs = 42;

  int sum = 0;
  int success = 0;

  for (var i = 0; i < tries; i++) {
    final sw = Stopwatch()..start();
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      sw.stop();
      socket.destroy();

      final ms = (sw.elapsedMicroseconds / 1000).ceil();
      if (ms > 0) {
        sum += ms;
        success++;
      }
    } catch (e) {
      debugPrint('ping $host:$port failed: $e');
    }
  }

  if (success == 0) return null;

  final avg = (sum / success).round();

  if (!clampForUi) return avg;
  return avg < minVisualPingMs ? minVisualPingMs : avg;
}



/// Берём host/port из ноды (от бэка). Может вернуть null, если данных нет.
({String host, int port})? hostPortFromNode(VpnNode node) {
  if (node.serverHost.isNotEmpty && node.serverPort > 0) {
    return (host: node.serverHost, port: node.serverPort);
  }
  if (node.baseUrl.isNotEmpty) {
    final uri = Uri.parse(node.baseUrl);
    final host = uri.host;
    final port = uri.hasPort ? uri.port : 443;
    if (host.isNotEmpty) {
      return (host: host, port: port);
    }
  }
  // нет данных — не пингуем
  return null;
}



/// Внутренний помощник: относительная нагрузка панели.
/// Если total == 0, используем просто online как метрику.
double _load(VpnNode n) {
  if (n.total > 0) {
    return n.online / n.total;
  }
  return n.online.toDouble();
}

/// Для списка нод:
/// 1) меряет TCP-пинг до каждой,
/// 2) выбирает лучшую по приоритету → нагрузке → пингу,
/// 3) возвращает лучшую и карту id → pingMs.
Future<({VpnNode? best, Map<int, int> pingsMs})> findBestNode(
  List<VpnNode> nodes, {
  Duration timeout = const Duration(seconds: 2),
  int tries = 3,
}) async {
  final Map<int, int> pings = {};
  if (nodes.isEmpty) return (best: null, pingsMs: pings);

  const int maxConcurrent = 5;
  final queue = [...nodes];

  Future<void> worker() async {
    while (true) {
      final node = queue.isNotEmpty ? queue.removeAt(0) : null;
      if (node == null) break;
      final hp = hostPortFromNode(node);
      if (hp == null) continue;
      final ping = await measureTcpPing(
        hp.host,
        hp.port,
        timeout: timeout,
        tries: tries,
      );
      if (ping != null) {
        pings[node.id] = ping;
        node.pingMs = ping;
      }
    }
  }

  final workers = <Future<void>>[];
  final n = nodes.length < maxConcurrent ? nodes.length : maxConcurrent;
  for (int i = 0; i < n; i++) {
    workers.add(worker());
  }
  await Future.wait(workers);

  final sorted = [...nodes]..sort((a, b) {
    final pr = a.priority.compareTo(b.priority);
    if (pr != 0) return pr;

    final loadCmp = _load(a).compareTo(_load(b));
    if (loadCmp != 0) return loadCmp;

    final pingA = a.pingMs ?? (1 << 30);
    final pingB = b.pingMs ?? (1 << 30);
    return pingA.compareTo(pingB);
  });

  debugPrint('--- VPN NODES ---');
  for (final n in sorted) {
    debugPrint('Node ${n.id} ${n.name}: pr=${n.priority}, online=${n.online}/${n.total}, ping=${n.pingMs}');
  }
  final bestNode = sorted.first;
  debugPrint('>>> BEST NODE: ${bestNode.id} ${bestNode.name}\n');

  return (best: bestNode, pingsMs: pings);
}

