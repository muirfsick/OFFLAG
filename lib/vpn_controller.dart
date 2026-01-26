import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_v2ray_plus/flutter_v2ray.dart';
import 'package:flutter_v2ray_plus/model/vless_status.dart';

import 'models/vpn_node.dart';
import 'xray/config_builder.dart';

/// Вспомогательная функция: находим папку, где лежит сам exe приложения.
/// На Windows в release-режиме Platform.resolvedExecutable указывает на OffLag.exe.
String _resolveExeDir() {
  try {
    final exeFile = File(Platform.resolvedExecutable);
    return exeFile.parent.path;
  } catch (_) {
    // запасной вариант — текущая директория процесса
    return Directory.current.path;
  }
}

/// Простейший join без доп. зависимостей.
String _joinPath(String dir, String name) {
  final sep = Platform.pathSeparator;
  if (dir.endsWith(sep)) {
    return '$dir$name';
  }
  return '$dir$sep$name';
}

/// Временный путь для конфига (по умолчанию — temp).
Future<String> _tempConfigPath() async {
  try {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final dir = await getTemporaryDirectory();
      return _joinPath(dir.path, 'xray-config.json');
    }
    final dir = await getApplicationSupportDirectory();
    return _joinPath(dir.path, 'xray-config.json');
  } catch (_) {
    return _joinPath(Directory.systemTemp.path, 'xray-config.json');
  }
}

/// Скрыть файл в проводнике на Windows (best-effort).
Future<void> _hideOnWindows(String path) async {
  if (!Platform.isWindows) return;
  try {
    await Process.run('attrib', ['+H', path], runInShell: true);
  } catch (_) {}
}

class VpnController {
  /// Полный путь к xray.exe (только Windows).
  final String exePath;

  /// Полный путь к config.json для xray.
  /// Если не задан, при подключении будет использован временный путь.
  final String configPath;

  /// Живой процесс xray (только Windows).
  Process? _proc;

  /// Имя TUN-интерфейса, который создаёт Xray на Windows.
  ///
  /// Важно: маршруты мы настраиваем сами (Xray TUN inbound их не трогает).
  static const String _kWindowsTunName = 'xray0';

  /// Данные для удаления маршрута при отключении.
  int? _windowsTunIfIndex;
  String? _windowsTunIp;
  bool _windowsRouteAdded = false;

  final FlutterV2ray _v2ray = FlutterV2ray();
  StreamSubscription<VlessStatus>? _v2raySub;
  bool _androidInitialized = false;
  static const List<String> _kAndroidDnsServers = ['1.1.1.1', '8.8.8.8'];

  /// Реактивный статус (true — VPN запущен).
  final ValueNotifier<bool> _status = ValueNotifier<bool>(false);
  ValueListenable<bool> get status => _status;
  bool get isRunning => _status.value;


  /// Если пути не переданы, по умолчанию ищем всё рядом с OffLag.exe:
  ///   OffLag.exe
  ///   xray.exe
  ///   wintun.dll
  /// А конфиг создаём во временном каталоге.
  VpnController({
    String? exePath,
    String? configPath,
  })  : exePath = exePath ?? _joinPath(_resolveExeDir(), 'xray.exe'),
        configPath = configPath ?? '';

  /// Грубое завершение всех процессов xray.exe в системе (только Windows).
  ///
  /// Внимание: это убьёт *любой* xray.exe в системе (в т.ч. если пользователь
  /// параллельно запустил другой клиент). Но для «моноприложения» это обычно ок.
  static Future<void> killAllXray() async {
    if (!Platform.isWindows) return;
    try {
      final res = await Process.run(
        'taskkill',
        ['/IM', 'xray.exe', '/F'],
        runInShell: true,
      );
      debugPrint('[VpnController] taskkill xray.exe: exit=${res.exitCode}');
    } catch (e, st) {
      debugPrint('[VpnController] taskkill xray.exe failed: $e\n$st');
    }
  }

  /// Универсальный connect: Windows.
  Future<bool> connect(VpnNode node) async {
    if (Platform.isWindows) {
      return _connectWindows(node);
    } else if (Platform.isAndroid) {
      return _connectAndroid(node);
    } else {
      debugPrint('[VpnController] connect(): ${Platform.operatingSystem} not supported yet');
      return false;
    }
  }

  // ---------------- Windows ----------------
  Future<bool> _connectWindows(VpnNode node) async {
    if (_proc != null) {
      debugPrint('[VpnController] already running (Windows)');
      return true;
    }

    debugPrint('[VpnController][Windows] exePath = $exePath');

    if (!File(exePath).existsSync()) {
      debugPrint('[VpnController][Windows] xray.exe not found: $exePath');
      return false;
    }

    // До включения TUN-маршрута определяем «физический» интерфейс.
    // Это нужно, чтобы исходящие соединения Xray не зацикливались в TUN.
    final outboundIf = await _getWindowsDefaultInterfaceAlias();
    final sendThroughIp = await _getWindowsDefaultLocalIPv4();
    debugPrint('[VpnController][Windows] default interface = ${outboundIf ?? '(unknown)'}');
    debugPrint('[VpnController][Windows] default local ip = ${sendThroughIp ?? '(unknown)'}');

    // Генерим config.json под выбранную ноду во временный путь (или заданный пользователем).
    late final String cfgPath;
    try {
      cfgPath = configPath.isNotEmpty ? configPath : await _tempConfigPath();

      await generateXrayConfig(
        configPath: cfgPath,
        node: node,
        tunName: _kWindowsTunName,
        outboundInterface: outboundIf,
        // sendThrough — fallback, если имя интерфейса получить не удалось.
        sendThrough: outboundIf == null ? sendThroughIp : null,
      );

      await _hideOnWindows(cfgPath);
    } catch (e, st) {
      debugPrint('[VpnController][Windows] failed to generate xray config: $e\n$st');
    }

    if (!File(cfgPath).existsSync()) {
      debugPrint('[VpnController][Windows] config not found after generate: $cfgPath');
      return false;
    }

    // Рабочую директорию ставим туда же, где лежит xray.exe.
    // Тогда Windows найдёт wintun.dll, лежащий рядом.
    final workDir = File(exePath).parent.path;

    try {
      debugPrint('[VpnController][Windows] starting xray with $cfgPath...');

      final proc = await Process.start(
        exePath,
        ['run', '-c', cfgPath],
        workingDirectory: workDir,
        mode: ProcessStartMode.normal,
      );

      _proc = proc;

      proc.stdout.transform(utf8.decoder).listen(
            (data) => debugPrint('[xray][out] $data'),
      );
      proc.stderr.transform(utf8.decoder).listen(
            (data) => debugPrint('[xray][err] $data'),
      );

      // Поднимаем route 0.0.0.0/0 -> TUN. Если не получится — считаем подключение
      // неуспешным (иначе UI скажет "VPN ON", а трафик не пойдёт).
      final routed = await _addWindowsTunDefaultRoute();
      if (!routed) {
        debugPrint('[VpnController][Windows] failed to add default route to TUN. Stopping xray.');
        try {
          proc.kill();
        } catch (_) {}
        _proc = null;
        _status.value = false;
        return false;
      }

      _status.value = true;

      proc.exitCode.then((code) async {
        debugPrint('[VpnController][Windows] xray exited with code $code');
        await _removeWindowsTunDefaultRoute();
        _proc = null;
        _status.value = false;
        // почистим временный конфиг (best-effort)
        try {
          if (configPath.isEmpty) {
            final f = File(cfgPath);
            if (await f.exists()) await f.delete();
          }
        } catch (_) {}
      });

      return true;
    } catch (e, st) {
      debugPrint('[VpnController][Windows] failed to start xray: $e\n$st');
      _proc = null;
      _status.value = false;
      return false;
    }
  }

  /// Универсальный disconnect.
  Future<void> disconnect() async {
    if (Platform.isWindows) {
      await _disconnectWindows();
      return;
    }
    if (Platform.isAndroid) {
      await _disconnectAndroid();
      return;
    }
    debugPrint('[VpnController] disconnect(): ${Platform.operatingSystem} not supported yet');
  }

  Future<void> _disconnectWindows() async {
    final proc = _proc;

    // Сначала пытаемся убрать маршрут (если он был добавлен).
    // Делать это лучше ДО остановки процесса, чтобы интерфейс ещё существовал.
    await _removeWindowsTunDefaultRoute();

    if (proc == null) {
      debugPrint('[VpnController][Windows] disconnect() but process is null, try killAllXray');
      _status.value = false;
      // На всякий случай добьём все xray по имени
      await killAllXray();
      // и почистим временный конфиг
      try {
        if (configPath.isEmpty) {
          final tmp = await _tempConfigPath();
          final f = File(tmp);
          if (await f.exists()) await f.delete();
        }
      } catch (_) {}
      return;
    }

    try {
      debugPrint('[VpnController][Windows] killing xray (proc.kill)...');
      proc.kill();
    } catch (e, st) {
      debugPrint('[VpnController][Windows] failed to kill xray: $e\n$st');
    } finally {
      _proc = null;
      _status.value = false;
      // И дополнительно дёрнем taskkill, чтобы не оставалось зомби
      await killAllXray();
      // подчистим конфиг, если использовался дефолтный путь
      try {
        if (configPath.isEmpty) {
          final tmp = await _tempConfigPath();
          final f = File(tmp);
          if (await f.exists()) await f.delete();
        }
      } catch (_) {}
    }
  }

  /// Пытаемся определить alias «физического» интерфейса, через который
  /// система ходит в интернет (например: "Wi-Fi" или "Ethernet").
  ///
  /// Используется для привязки исходящих соединений Xray к реальному интерфейсу
  /// и предотвращения loop-back в TUN.
  Future<String?> _getWindowsDefaultInterfaceAlias() async {
    if (!Platform.isWindows) return null;
    try {
      // 1) Самый надёжный вариант: посмотреть дефолтный маршрут 0.0.0.0/0.
      final cmd = "(Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object -Property RouteMetric | Select-Object -First 1 -ExpandProperty InterfaceAlias)";
      final res = await Process.run(
        'powershell',
        ['-NoProfile', '-Command', cmd],
        runInShell: true,
      );
      final out = (res.stdout ?? '').toString().trim();
      if (res.exitCode == 0 && out.isNotEmpty) return out;
    } catch (_) {
      // ignore
    }

    // 2) Fallback: определяем локальный IP «наружу» и маппим его в InterfaceAlias.
    final ip = await _getWindowsDefaultLocalIPv4();
    if (ip == null) return null;
    try {
      final cmd = "(Get-NetIPAddress -IPAddress '$ip' -AddressFamily IPv4 | Select-Object -First 1 -ExpandProperty InterfaceAlias)";
      final res = await Process.run(
        'powershell',
        ['-NoProfile', '-Command', cmd],
        runInShell: true,
      );
      final out = (res.stdout ?? '').toString().trim();
      if (res.exitCode == 0 && out.isNotEmpty) return out;
    } catch (_) {
      // ignore
    }
    return null;
  }

  /// Определяем локальный IPv4, который система использует как исходящий «по
  /// умолчанию».
  ///
  /// В первой версии я пытался сделать это через UDP-socket trick, но у
  /// RawDatagramSocket в Dart нет метода connect() — поэтому здесь только
  /// PowerShell (best-effort).
  Future<String?> _getWindowsDefaultLocalIPv4() async {
    if (!Platform.isWindows) return null;
    try {
      // Берём интерфейс, по которому идёт дефолтный маршрут 0.0.0.0/0, и
      // вытаскиваем первый валидный IPv4 на нём.
      final cmd = r"$ifIndex = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object -Property RouteMetric | Select-Object -First 1 -ExpandProperty InterfaceIndex); "
          r"(Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 | "
          r"Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } | "
          r"Select-Object -First 1 -ExpandProperty IPAddress)";

      final res = await Process.run(
        'powershell',
        ['-NoProfile', '-Command', cmd],
        runInShell: true,
      );
      final out = (res.stdout ?? '').toString().trim();
      if (res.exitCode == 0 && out.isNotEmpty) return out;
    } catch (_) {
      // ignore
    }
    return null;
  }

  Future<({int ifIndex, String ip})?> _getWindowsTunInfo() async {
    if (!Platform.isWindows) return null;
    final tunName = _kWindowsTunName;

    try {
      final ipRes = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-Command',
          "(Get-NetIPAddress -InterfaceAlias '$tunName' -AddressFamily IPv4 | Select-Object -First 1 -ExpandProperty IPAddress)",
        ],
        runInShell: true,
      );
      final ip = (ipRes.stdout ?? '').toString().trim();
      if (ipRes.exitCode != 0 || ip.isEmpty) return null;

      final idxRes = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-Command',
          "(Get-NetIPInterface -InterfaceAlias '$tunName' -AddressFamily IPv4 | Select-Object -First 1 -ExpandProperty InterfaceIndex)",
        ],
        runInShell: true,
      );
      final idxStr = (idxRes.stdout ?? '').toString().trim();
      final idx = int.tryParse(idxStr);
      if (idxRes.exitCode != 0 || idx == null) return null;

      return (ifIndex: idx, ip: ip);
    } catch (_) {
      return null;
    }
  }

  /// Добавляет дефолтный маршрут 0.0.0.0/0 через TUN-интерфейс.
  ///
  /// Важно:
  /// - требует прав администратора (как и любой системный VPN в Windows);
  /// - Xray сам маршруты не трогает, поэтому без этого трафик через TUN не пойдёт.
  Future<bool> _addWindowsTunDefaultRoute() async {
    if (!Platform.isWindows) return true;
    if (_windowsRouteAdded) return true;

    // Ждём, пока Windows назначит IP интерфейсу.
    ({int ifIndex, String ip})? info;
    for (int i = 0; i < 40; i++) {
      info = await _getWindowsTunInfo();
      if (info != null) break;
      await Future.delayed(const Duration(milliseconds: 250));
    }
    if (info == null) {
      debugPrint('[VpnController][Windows] TUN interface "${_kWindowsTunName}" not ready (no IP/index)');
      return false;
    }

    _windowsTunIfIndex = info.ifIndex;
    _windowsTunIp = info.ip;

    // На всякий случай удалим старый маршрут (если остался после краша).
    try {
      await Process.run(
        'route',
        ['delete', '0.0.0.0', 'mask', '0.0.0.0', info.ip, 'if', info.ifIndex.toString()],
        runInShell: true,
      );
    } catch (_) {
      // ignore
    }

    try {
      final res = await Process.run(
        'route',
        [
          'add',
          '0.0.0.0',
          'mask',
          '0.0.0.0',
          info.ip,
          'metric',
          '1',
          'if',
          info.ifIndex.toString(),
        ],
        runInShell: true,
      );

      debugPrint('[VpnController][Windows] route add default via TUN: exit=${res.exitCode}');
      if (res.exitCode != 0) {
        debugPrint('[VpnController][Windows] route add stdout: ${res.stdout}');
        debugPrint('[VpnController][Windows] route add stderr: ${res.stderr}');
        return false;
      }

      _windowsRouteAdded = true;
      return true;
    } catch (e, st) {
      debugPrint('[VpnController][Windows] route add failed: $e\n$st');
      return false;
    }
  }

  Future<void> _removeWindowsTunDefaultRoute() async {
    if (!Platform.isWindows) return;
    if (!_windowsRouteAdded) return;
    final ip = _windowsTunIp;
    final idx = _windowsTunIfIndex;
    _windowsRouteAdded = false;
    _windowsTunIp = null;
    _windowsTunIfIndex = null;
    if (ip == null || idx == null) return;

    try {
      final res = await Process.run(
        'route',
        ['delete', '0.0.0.0', 'mask', '0.0.0.0', ip, 'if', idx.toString()],
        runInShell: true,
      );
      debugPrint('[VpnController][Windows] route delete default via TUN: exit=${res.exitCode}');
    } catch (_) {
      // ignore
    }
  }

  // ---------------- Android ----------------
  Future<void> _ensureAndroidInitialized() async {
    if (_androidInitialized) return;
    await _v2ray.initializeVless();
    _v2raySub = _v2ray.onStatusChanged.listen((status) {
      _status.value = status.state == 'CONNECTED';
    });
    _androidInitialized = true;
  }

  Future<bool> _connectAndroid(VpnNode node) async {
    if (_status.value) return true;

    try {
      await _ensureAndroidInitialized();
      final allowed = await _v2ray.requestPermission();
      if (!allowed) return false;

      final url = _buildVlessUrl(node);
      final parsed = FlutterV2ray.parseFromURL(url);
      final config = _applyDnsOverrides(
        parsed.getFullConfiguration(),
        _kAndroidDnsServers,
      );
      final remark = parsed.remark.isNotEmpty ? parsed.remark : node.name;

      await _v2ray.startVless(
        remark: remark,
        config: config,
        bypassSubnets: const ['0.0.0.0/0', '::/0'],
        dnsServers: _kAndroidDnsServers,
      );

      return true;
    } catch (e, st) {
      debugPrint('[VpnController][Android] failed to start: $e\n$st');
      return false;
    }
  }

  String _applyDnsOverrides(String config, List<String> dnsServers) {
    try {
      final decoded = jsonDecode(config);
      if (decoded is! Map<String, dynamic>) return config;
      decoded['dns'] = {
        'servers': dnsServers,
      };
      return jsonEncode(decoded);
    } catch (_) {
      return config;
    }
  }

  Future<void> _disconnectAndroid() async {
    try {
      await _v2ray.stopVless();
    } catch (e, st) {
      debugPrint('[VpnController][Android] failed to stop: $e\n$st');
    }
  }

  String _buildVlessUrl(VpnNode node) {
    final serverHost = node.serverHost.isNotEmpty
        ? node.serverHost
        : Uri.tryParse(node.baseUrl)?.host ?? '';
    final serverPort = node.serverPort != 0 ? node.serverPort : 443;
    final uuid = node.uuid.isNotEmpty
        ? node.uuid
        : 'db31c862-ca3a-4b08-84a2-570193e69f3e';
    final publicKey = node.publicKey.isNotEmpty
        ? node.publicKey
        : '72TobKObJ8FRwoL31wFaEWIyihSiFEZYjtZCe8RT-Vg';
    final shortId = node.shortId.isNotEmpty ? node.shortId : '26';
    final remark = Uri.encodeComponent(node.name);

    return 'vless://$uuid@$serverHost:$serverPort?'
        'type=xhttp&encryption=none&security=reality&pbk=$publicKey'
        '&fp=chrome&sni=google.com&sid=$shortId&spx=%2F#$remark';
  }
}
