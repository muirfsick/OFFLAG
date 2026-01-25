import 'package:flutter/material.dart';
import '../theme.dart';
import 'main_tabs.dart';
import '../net.dart';
import '../storage/token_store.dart'; // 👈 добавили

/// Экран создания профиля: ввод и подтверждение никнейма.
///
/// После успешного подтверждения никнейма сохраняет токен/почту в [Session]
/// и открывает главный экран [`MainTabs`].
class AuthNamePage extends StatefulWidget {
  /// E-mail пользователя, пришедший с предыдущего шага аутентификации.
  final String email;

  const AuthNamePage({super.key, required this.email});

  @override
  State<AuthNamePage> createState() => _AuthNamePageState();
}

class _AuthNamePageState extends State<AuthNamePage> {
  final _ctrl = TextEditingController();
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    Session.email = widget.email;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Отправляет выбранный никнейм на сервер.
  ///
  /// Валидация:
  /// - длина 3–24 символа;
  /// - допустимы латиница, цифры и подчёркивание.
  ///
  /// При успехе сохраняет `token` и `email` в [Session] и [TokenStore] и
  /// выполняет переход на [`MainTabs`] с очисткой стека навигации.
  Future<void> _submit() async {
    final nickname = _ctrl.text.trim();
    if (nickname.length < 3 || nickname.length > 24) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ник: 3–24 символа')),
      );
      return;
    }
    final ok = RegExp(r'^[A-Za-z0-9_]+$').hasMatch(nickname);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Только латиница, цифры и _')),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      final res = await dio.post('/set_nickname', data: {
        'email': widget.email,
        'nickname': nickname,
        'device': 'FlutterApp',
      });

      final data = res.data is Map ? (res.data as Map) : {};
      final token = (data['token'] ?? '') as String;

      if (token.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не получен токен. Повторите ещё раз.')),
        );
        return;
      }

      // Сохраняем в Session для работы dio
      Session.token = token;
      Session.email = widget.email;

      // И ПЕРСИСТИМ токен в SharedPreferences 👇
      await TokenStore.save(token, widget.email);

      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        _slide(const MainTabs()),
            (_) => false,
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ник уже занят или ошибка')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = Ui.mainWidth(context);
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(title: const Text('Создание профиля')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        children: [
          Text('Придумайте никнейм', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            style: const TextStyle(color: kInk),
            decoration: InputDecoration(
              hintText: 'Например: Neo_Player',
              hintStyle: const TextStyle(color: Color(0xFFC5C6C8)),
              filled: true,
              fillColor: kSurface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: kBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: kBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Colors.white),
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: w,
            height: w * 0.18,
            child: ElevatedButton(
              onPressed: _loading ? null : _submit,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                child: _loading
                    ? const SizedBox(
                  key: ValueKey('pr'),
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: Colors.white,
                  ),
                )
                    : const Text('Продолжить', key: ValueKey('tx')),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Анимированный переход к [page] с лёгким fade + slide.
  PageRoute _slide(Widget page) => PageRouteBuilder(
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, a, __) => FadeTransition(
      opacity: CurvedAnimation(parent: a, curve: Curves.easeOutQuad),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, .06),
          end: Offset.zero,
        ).animate(
          CurvedAnimation(parent: a, curve: Curves.easeOutQuad),
        ),
        child: page,
      ),
    ),
  );
}
