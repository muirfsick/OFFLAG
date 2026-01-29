import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'auth_name.dart';
import 'main_tabs.dart';
import '../net.dart';
import '../storage/token_store.dart';


/// Экран ввода кода подтверждения для указанного e-mail.
class CodeScreen extends StatefulWidget {
  /// Почта, на которую был отправлен код.
  final String email;

  const CodeScreen({super.key, required this.email});

  @override
  State<CodeScreen> createState() => _CodeScreenState();
}

/// Визуальное состояние поля кода.
enum _CodeState { neutral, ok, error }

class _CodeScreenState extends State<CodeScreen> with SingleTickerProviderStateMixin {
  /// Длина OTP-кода.
  static const int _otpLen = 6;

  /// Текущий собранный код из всех ячеек.
  String code = '';

  /// Флаг активного запроса верификации/переотправки.
  bool loading = false;

  /// Можно ли отправить код повторно (по истечении таймера).
  bool canResend = false;

  /// Оставшееся время до возможности повторной отправки, сек.
  int secondsLeft = 60;

  /// Периодический таймер обратного отсчёта.
  Timer? timer;

  /// Текущее визуальное состояние ввода кода.
  _CodeState _state = _CodeState.neutral;

  /// Таймер авто-сброса визуального состояния к neutral.
  Timer? _stateResetTimer;

  /// Контроллеры полей ввода цифр.
  late final List<TextEditingController> _ctrs;

  /// Узлы фокуса для навигации по полям.
  late final List<FocusNode> _nodes;

  /// Контроллер анимации встряски при ошибке.
  late final AnimationController _shakeCtrl;

  /// Прогресс кривой анимации встряски 0..1.
  late final Animation<double> _shakeAnim;

  @override
  void initState() {
    super.initState();
    _ctrs = List.generate(_otpLen, (_) => TextEditingController());
    _nodes = List.generate(_otpLen, (_) => FocusNode());
    _shakeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
    _shakeAnim = CurvedAnimation(parent: _shakeCtrl, curve: Curves.easeOutCubic);
    startTimer();
  }

  @override
  void dispose() {
    timer?.cancel();
    _stateResetTimer?.cancel();
    _shakeCtrl.dispose();
    for (final c in _ctrs) {
      c.dispose();
    }
    for (final f in _nodes) {
      f.dispose();
    }
    super.dispose();
  }

  /// Устанавливает визуальное состояние и автоматически сбрасывает его через [ms] миллисекунд.
  ///
  /// При значении [_CodeState.error] запускает анимацию встряски.
  void _setStateWithAutoReset(_CodeState s, {int ms = 900}) {
    setState(() => _state = s);
    _stateResetTimer?.cancel();
    _stateResetTimer = Timer(Duration(milliseconds: ms), () {
      if (mounted && _state == s) setState(() => _state = _CodeState.neutral);
    });
    if (s == _CodeState.error) {
      _shakeCtrl.forward(from: 0);
    }
  }

  /// Запускает/перезапускает таймер обратного отсчёта для повторной отправки кода.
  void startTimer() {
    setState(() {
      canResend = false;
      secondsLeft = 60;
    });
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (secondsLeft <= 1) {
        t.cancel();
        setState(() => canResend = true);
      } else {
        setState(() => secondsLeft--);
      }
    });
  }

  /// Переотправляет код на e-mail из [widget.email] и сбрасывает ввод.
  Future<void> resendCode() async {
    try {
      await dio.post('/send_code', data: {'email': widget.email});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Код отправлен повторно')),
      );
      for (final c in _ctrs) {
        c.clear();
      }
      setState(() {
        code = '';
        _state = _CodeState.neutral;
      });
      _nodes.first.requestFocus();
      startTimer();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось отправить код')),
      );
    }
  }

  /// Отправляет введённый код на верификацию.
  ///
  /// Успешный сценарий:
  /// - если `new_user == true` в ответе — переход на экран ввода имени [`AuthNamePage`];
  /// - иначе — сохранение токена в [Session] и переход к основным вкладкам [`MainTabs`].
  ///
  /// Ошибка сопровождается «встряской» и сообщением `SnackBar`.
  Future<void> verifyCode() async {
    if (loading) return;
    if (code.length != _otpLen || !code.runes.every((r) => r >= 48 && r <= 57)) return;

    setState(() => loading = true);
    FocusScope.of(context).unfocus();

    try {
      final res = await dio.post('/verify_code', data: {
        'email': widget.email,
        'code': code,
        'device': 'FlutterApp',
      });
      final data = res.data;
      if (!mounted) return;

      _setStateWithAutoReset(_CodeState.ok, ms: 500);

      if (data['new_user'] == true) {
        // новый пользователь — идём на экран ввода имени
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => AuthNamePage(email: widget.email)),
        );
      } else {
        // существующий пользователь — сразу получаем токен
        final token = data['token'] as String?;
        final refresh = data['refresh_token'] as String?;
        if (token == null || token.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Не получен токен. Повторите вход.')),
          );
          return;
        }

        // кладём в Session (для dio)...
        Session.token = token;
        Session.email = widget.email;

        // ...и сохраняем в SharedPreferences 👇
        await TokenStore.save(token, widget.email, refreshToken: refresh);

        if (!mounted) return;
        // и дальше уже в приложение
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const MainTabs()),
        );
      }
    } catch (_) {
      if (!mounted) return;
      _setStateWithAutoReset(_CodeState.error);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Неверный код или ошибка')),
      );
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }


  /// Собирает текущий код из полей и, при полной валидности, инициирует проверку.
  void _rebuildCodeAndMaybeSubmit() {
    setState(() {
      code = _ctrs.map((c) => c.text).join();
      _state = _CodeState.neutral;
    });
    if (code.length == _otpLen && code.runes.every((r) => r >= 48 && r <= 57)) {
      verifyCode();
    }
  }

  /// Обработчик изменения символа в ячейке ввода с индексом [i].
  ///
  /// Поддерживает навигацию фокуса вперёд/назад и ограничение до одной цифры.
  void _onBoxChanged(int i, String v) {
    String digit = v;
    if (digit.length > 1) digit = digit.substring(digit.length - 1);
    if (digit.isNotEmpty && (digit.codeUnitAt(0) < 48 || digit.codeUnitAt(0) > 57)) digit = '';

    final ctrl = _ctrs[i];
    if (ctrl.text != digit) {
      ctrl
        ..text = digit
        ..selection = TextSelection.collapsed(offset: digit.length);
    }

    if (digit.isNotEmpty && i < _otpLen - 1) {
      _nodes[i + 1].requestFocus();
    } else if (digit.isEmpty && i > 0) {
      _nodes[i - 1].requestFocus();
      _ctrs[i - 1].selection = TextSelection(baseOffset: 0, extentOffset: _ctrs[i - 1].text.length);
    }

    _rebuildCodeAndMaybeSubmit();
  }

  /// Строит оформление ячейки OTP с учётом [focused] и текущего состояния [_state].
  InputDecoration _otpDecoration(BuildContext context, bool focused) {
    final cs = Theme.of(context).colorScheme;
    Color borderColor;
    Color fillColor;

    switch (_state) {
      case _CodeState.ok:
        borderColor = Colors.green;
        fillColor = Colors.green.withValues(alpha: 0.12);
        break;
      case _CodeState.error:
        borderColor = Colors.red;
        fillColor = Colors.red.withValues(alpha: 0.12);
        break;
      case _CodeState.neutral:
        borderColor = focused ? cs.primary : cs.outlineVariant;
        fillColor = focused
            ? cs.primary.withValues(alpha: 0.08)
            : cs.surfaceContainerHighest.withValues(alpha: 0.60);
        break;
    }

    return InputDecoration(
      counterText: '',
      contentPadding: const EdgeInsets.symmetric(vertical: 14),
      filled: true,
      fillColor: fillColor,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: borderColor, width: 1.4),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: borderColor, width: 1.4),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: borderColor, width: 1.6),
      ),
    );
  }

  /// Создаёт одну ячейку ввода OTP под индексом [i].
  ///
  /// Центрирует ввод, ограничивает до одной цифры и применяет оформление из [_otpDecoration].
  Widget _buildOtpBox(int i) {
    final focused = _nodes[i].hasFocus;

    return SizedBox(
      width: 48,
      child: TextField(
        controller: _ctrs[i],
        focusNode: _nodes[i],
        textAlign: TextAlign.center,
        keyboardType: TextInputType.number,
        maxLength: 1,
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: 2),
        decoration: _otpDecoration(context, focused),
        onChanged: (v) => _onBoxChanged(i, v),
        onTap: () {
          final txt = _ctrs[i].text;
          _ctrs[i].selection = TextSelection(baseOffset: 0, extentOffset: txt.length);
        },
      ),
    );
  }

  /// Возвращает горизонтальное смещение в пикселях для эффекта встряски.
  double _shakeOffsetPx() {
    if (_shakeCtrl.isAnimating || _state == _CodeState.error) {
      final t = _shakeAnim.value;
      final amp = 10.0 * (1 - t);
      final cycles = 3.0;
      return math.sin(t * cycles * 2 * math.pi) * amp;
    }
    return 0.0;
  }

  /// Строит интерфейс экрана: заголовки, 6 полей кода, таймер и кнопку повторной отправки.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Подтверждение'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 8),
              Text(
                'Введите код из письма',
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                widget.email,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              AnimatedBuilder(
                animation: _shakeAnim,
                builder: (context, child) {
                  return Transform.translate(
                    offset: Offset(_shakeOffsetPx(), 0),
                    child: child,
                  );
                },
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: List.generate(_otpLen, (i) => _buildOtpBox(i)),
                ),
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.60),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SvgPicture.asset(
                      'assets/icons/timer.svg',
                      width: 18,
                      height: 18,
                      colorFilter: ColorFilter.mode(
                        theme.colorScheme.onSurfaceVariant,
                        BlendMode.srcIn,
                      ),
                      semanticsLabel: 'Timer',
                    ),
                    const SizedBox(width: 8),
                    Text(
                      canResend ? 'Можно отправить код снова' : 'Отправить снова через $secondsLeft сек',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: canResend && !loading ? resendCode : null,
                child: const Text('Отправить код ещё раз'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
