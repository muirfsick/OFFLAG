import 'dart:convert';
import 'dart:io';

import '../models/vpn_node.dart';
import '../storage/services_store.dart';
// Переиспользуем тот же список доменных суффиксов, что и для sing-box,
// чтобы поведение «исключённых сервисов» было одинаковым на всех платформах.
import '../singbox/config_builder.dart' show kServiceDomainSuffixes;

/// Генерирует конфиг для Xray-core (Windows TUN + VLESS + XHTTP + REALITY).
///
/// Важные моменты:
/// - inbound: `tun` (интерфейс создаётся Xray, но **маршруты в системе нужно
///   настраивать отдельно** — это делается в VpnController);
/// - outbounds:
///   - `direct` (freedom) — держим первым и используем для bypass,
///     чтобы служебные подключения Xray не зацикливались на TUN;
///   - `proxy` (vless + xhttp + reality);
///   - `block` (blackhole);
/// - routing: правила «в исключения → direct», остальное → proxy.
Future<void> generateXrayConfig({
  required String configPath,
  required VpnNode node,
  String tunName = 'xray0',
  int tunMtu = 1500,

  /// Имя физического интерфейса Windows (например: "Wi-Fi" или "Ethernet").
  /// Используется для привязки исходящих соединений (анти-loop для TUN).
  String? outboundInterface,

  /// IP адрес, с которого надо делать исходящие соединения (fallback, если не
  /// получилось определить outboundInterface).
  String? sendThrough,
}) async {
  // Какие сервисы пользователь исключил.
  final excludedServices = await ServicesStore.loadExcluded();
  final excludedDomains = excludedServices
      .expand((service) => kServiceDomainSuffixes[service] ?? const <String>[])
      .toSet()
      .toList()
    ..sort();

  // Параметры VLESS / Reality (та же логика фоллбеков, что в sing-box builder).
  final serverHost = node.serverHost.isNotEmpty
      ? node.serverHost
      : (Uri.tryParse(node.baseUrl)?.host ?? '');

  final serverPort = node.serverPort != 0 ? node.serverPort : 443;

  final uuid = node.uuid;
  final publicKey = node.publicKey;
  final shortId = node.shortId;

  if (serverHost.isEmpty || uuid.isEmpty || publicKey.isEmpty || shortId.isEmpty) {
    throw StateError('VLESS params missing for node id=${node.id}');
  }

  final sockopt = <String, dynamic>{};
  if (outboundInterface != null && outboundInterface.trim().isNotEmpty) {
    sockopt['interface'] = outboundInterface.trim();
  }

  Map<String, dynamic>? outboundStreamSockopt() {
    if (sockopt.isEmpty) return null;
    return {
      'sockopt': sockopt,
    };
  }

  final st = sendThrough?.trim();
  Map<String, dynamic>? outboundSendThrough() {
    if (st == null || st.isEmpty) return null;
    return {
      'sendThrough': st,
    };
  }

  final directOutbound = <String, dynamic>{
    'tag': 'direct',
    'protocol': 'freedom',
    'settings': {},
    if (outboundStreamSockopt() != null) 'streamSettings': outboundStreamSockopt(),
    if (outboundSendThrough() != null) ...outboundSendThrough()!,
  };

  final proxyOutbound = <String, dynamic>{
    'tag': 'proxy',
    'protocol': 'vless',
    'settings': {
      'vnext': [
        {
          'address': serverHost,
          'port': serverPort,
          'users': [
            {
              'id': uuid,
              'encryption': 'none',
              'flow': 'xtls-rprx-vision',
            }
          ]
        }
      ]
    },
    'streamSettings': {
      'network': 'xhttp',
      'security': 'reality',
      'realitySettings': {
        'fingerprint': 'chrome',
        'serverName': 'google.com',
        'publicKey': publicKey,
        'shortId': shortId,
        'spiderX': '/',
      },
      'xhttpSettings': {
        'path': '/',
        'mode': 'auto',
        'host': '',
      },
      if (outboundStreamSockopt() != null) ...outboundStreamSockopt()!,
    },
    if (outboundSendThrough() != null) ...outboundSendThrough()!,
  };

  final blockOutbound = <String, dynamic>{
    'tag': 'block',
    'protocol': 'blackhole',
    'settings': {},
  };

  // Xray routing `domain` поддерживает префиксы `domain:`/`full:`/`regexp:`.
  // В нашем UI домены задаются как suffix (пример: youtube.com), поэтому
  // используем `domain:`.
  final excludedDomainsRule = excludedDomains.isEmpty
      ? null
      : <String, dynamic>{
          'type': 'field',
          'domain': excludedDomains.map((d) => 'domain:$d').toList(),
          'outboundTag': 'direct',
        };

  final config = <String, dynamic>{
    'log': {
      // На проде обычно "warning" или "info".
      'loglevel': 'warning',
    },
    'inbounds': [
      {
        'tag': 'tun-in',
        'protocol': 'tun',
        'settings': {
          'name': tunName,
          // json tag у Xray — именно "MTU" (верхний регистр).
          'MTU': tunMtu,
          'userLevel': 0,
        },
        'sniffing': {
          'enabled': true,
          'destOverride': ['http', 'tls', 'quic'],
        },
      }
    ],
    'outbounds': [
      // Важно: direct первым.
      directOutbound,
      proxyOutbound,
      blockOutbound,
    ],
    'routing': {
      'domainStrategy': 'IPIfNonMatch',
      'rules': [
        // Локальные/приватные адреса всегда в direct.
        // Не используем geoip:private, чтобы не зависеть от geoip.dat.
        {
          'type': 'field',
          'ip': [
            '10.0.0.0/8',
            '100.64.0.0/10',
            '127.0.0.0/8',
            '169.254.0.0/16',
            '172.16.0.0/12',
            '192.168.0.0/16',
          ],
          'outboundTag': 'direct',
        },

        // Сохраняю вашу исходную логику: суффиксы su и xn--p1ai — напрямую.
        {
          'type': 'field',
          'domain': ['domain:su', 'domain:xn--p1ai'],
          'outboundTag': 'direct',
        },

        if (excludedDomainsRule != null) excludedDomainsRule,

        // Всё остальное, что пришло из TUN, — в прокси.
        {
          'type': 'field',
          'inboundTag': ['tun-in'],
          'outboundTag': 'proxy',
        },
      ],
    },
  };

  final file = File(configPath);
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(config),
    flush: true,
  );
}
