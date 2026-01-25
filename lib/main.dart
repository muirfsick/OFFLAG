import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'net.dart';
import 'theme.dart';
import 'pages/welcome.dart';
import 'pages/main_tabs.dart';
import 'storage/token_store.dart';
import 'vpn_controller.dart'; // 👈 добавили

/// Главная функция приложения.
///
/// Выполняет предварительную инициализацию, настраивает параметры окна
/// для десктопа (фиксированный размер 460×800, центрирование, запрет ресайза),
/// затем запускает корневой виджет [`OffLagApp`].
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 👇 При старте на Windows гарантированно выключаем все xray.exe,
  // чтобы тумблер всегда отражал реальное состояние (VPN off).
  if (Platform.isWindows) {
    await VpnController.killAllXray();
  }

  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    await windowManager.ensureInitialized();

    const appSize = Size(460, 800);

    final opts = const WindowOptions(
      size: appSize,
      center: true,
      titleBarStyle: TitleBarStyle.normal,
      backgroundColor: Colors.transparent,
    );

    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.setResizable(false);
      await windowManager.setMinimumSize(appSize);
      await windowManager.setMaximumSize(appSize);
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const OffLagApp());
}

/// Корневой виджет приложения OffLag.
class OffLagApp extends StatelessWidget {
  const OffLagApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme(
      brightness: Brightness.dark,
      primary: Colors.white,
      onPrimary: Colors.black,
      secondary: Colors.white,
      onSecondary: Colors.black,
      surface: kSurface,
      onSurface: Colors.white,
      error: Colors.red.shade400,
      onError: Colors.black,
    );

    const textTheme = TextTheme(
      headlineLarge: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: kInk),
      headlineMedium: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: kInk),
      titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: kInk),
      titleMedium: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: kInk),
      bodyLarge: TextStyle(fontSize: 16, color: kInk),
      bodyMedium: TextStyle(fontSize: 15, color: kInk),
      labelLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: kInk),
    );

    return MaterialApp(
      title: 'OffLag',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: kBg,
        textTheme: textTheme,
        iconTheme: const IconThemeData(color: Colors.white),
        appBarTheme: const AppBarTheme(
          backgroundColor: kBg,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          foregroundColor: Colors.white,
          titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white),
        ),
        dividerColor: kBorder,
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Color(0xFF383838),
            foregroundColor: kInk,
            shadowColor: Colors.transparent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(44)),
            side: const BorderSide(color: kBorder),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: kInk,
            side: const BorderSide(color: kBorder, width: 1.4),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: kSurface,
          contentTextStyle: TextStyle(color: kInk, fontWeight: FontWeight.w700),
          behavior: SnackBarBehavior.floating,
        ),
      ),
      home: const _Boot(),
    );
  }
}

/// Промежуточный загрузочный экран.
class _Boot extends StatefulWidget {
  const _Boot();

  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> {
  @override
  void initState() {
    super.initState();
    _go();
  }

  /// Проверяет наличие токена в [TokenStore] и выполняет навигацию.
  Future<void> _go() async {
    final tok = await TokenStore.token;
    final mail = await TokenStore.email;

    if (!mounted) return;
    if (tok != null && tok.isNotEmpty) {
      Session.token = tok;
      Session.email = mail;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const MainTabs()),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const WelcomePage()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
