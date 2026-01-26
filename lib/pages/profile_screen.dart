import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';
import '../net.dart';
import '../models/user_profile.dart';
import '../pages/auth_email.dart';
import '../widgets/widgets.dart';
import '../storage/token_store.dart'; // 👈 добавили

/// Экран профиля пользователя.
///
/// Показывает основные данные (никнейм, e-mail, тариф, число активных сессий),
/// текущий баланс и дату, до которой средств хватит при текущем тарифе.
/// Также даёт действия: выход из аккаунта, смена e-mail, ввод промокода, пополнение.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.me,
    required this.loadingMe,
    required this.onRefreshMe,
    required this.onDisconnectVpn,
  });

  /// Загруженный профиль пользователя, если доступен.
  final UserProfile? me;

  /// Флаг текущей загрузки профиля.
  final bool loadingMe;

  /// Обновление данных профиля по жесту pull-to-refresh.
  final Future<void> Function() onRefreshMe;

  /// Отключить VPN перед выходом из аккаунта.
  final Future<void> Function() onDisconnectVpn;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  /// Таймер авто-обновления после старта оплаты.
  Timer? _autoRefreshTimer;

  /// Сколько раз уже дернули onRefreshMe() в рамках авто-обновления.
  int _autoRefreshAttempts = 0;

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  /// Форматирует денежную сумму с разделителями тысяч и 0/2 знаками после запятой.
  String _fmtMoney(num v) {
    final s = v.toStringAsFixed(v.truncateToDouble() == v ? 0 : 2);
    return s.replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
          (m) => '${m[1]} ',
    );
  }

  /// Возвращает дату (ДД.ММ), до которой хватит баланса при текущем тарифе.
  String _enoughUntil(UserProfile? me) {
    final pricePerMonth =
    (me?.effectivePrice ?? 0) > 0 ? me!.effectivePrice : 60.0;
    final daily = pricePerMonth / 30.0;
    if (daily <= 0) return '—';
    final days = ((me?.balance ?? 0.0) / daily).floor();
    final target = DateTime.now().add(Duration(days: days));
    final dd = target.day.toString().padLeft(2, '0');
    final mm = target.month.toString().padLeft(2, '0');
    return '$dd.$mm';
  }

  /// Стартуем авто-обновление профиля после запуска оплаты.
  /// Дёргаем onRefreshMe каждые 5 секунд, максимум 10 раз (~50 сек).
  void _startAutoRefreshAfterPayment() {
    _autoRefreshTimer?.cancel();
    _autoRefreshAttempts = 0;

    _autoRefreshTimer =
        Timer.periodic(const Duration(seconds: 5), (t) async {
          _autoRefreshAttempts++;
          await widget.onRefreshMe();

          if (_autoRefreshAttempts >= 10) {
            t.cancel();
          }
        });
  }

  /// Выход из аккаунта: вызывает `/logout_device`, очищает сессию,
  /// чистит сохранённый токен и переводит на экран входа.
  Future<void> _logout() async {
    await widget.onDisconnectVpn();
    try {
      await dio.post('/logout_device');
    } catch (_) {}

    // чистим in-memory сессию
    Session.token = null;
    Session.email = null;

    // чистим сохранённый токен в SharedPreferences 👇
    await TokenStore.clear();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Вы вышли из аккаунта')),
    );
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AuthEmailPage()),
          (route) => false,
    );
  }

  /// Запускает поток смены e-mail.
  Future<void> _openChangeEmailFlow() async {
    final newEmail = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: kBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(kRadiusXXL)),
      ),
      builder: (_) => const ChangeEmailSheet(),
    );
    if (newEmail == null) return;

    try {
      await dio.post('/change_email_request', data: {'new_email': newEmail});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Не удалось отправить код на новую почту')),
      );
      return;
    }

    final code = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: kBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(kRadiusXXL)),
      ),
      builder: (_) => ConfirmEmailCodeSheet(email: newEmail),
    );
    if (code == null) return;

    try {
      final res = await dio.post('/change_email_confirm', data: {
        'new_email': newEmail,
        'code': code,
      });
      final token = (res.data?['token'] as String?) ?? '';
      if (token.isNotEmpty) {
        // обновляем in-memory сессию
        Session.token = token;
        Session.email = newEmail;

        // и перезаписываем персистентный токен 👇
        await TokenStore.save(token, newEmail);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Почта успешно изменена')),
      );
      await widget.onRefreshMe();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Неверный код или ошибка подтверждения')),
      );
    }
  }

  /// Открывает модальное окно ввода промокода и применяет его.
  Future<void> _openPromoDialog() async {
    final code = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: kBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(kRadiusXXL)),
      ),
      builder: (ctx) => const PromoCodeSheet(),
    );
    if (code == null) return;
    try {
      await dio.post('/redeem_promo', data: {'code': code});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Промокод применён')),
      );
      await widget.onRefreshMe();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось применить промокод')),
      );
    }
  }

  /// Открывает внешний URL в браузере.
  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    final ok = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть ссылку')),
      );
    }
  }

  /// Модалка с юридическими документами.
  Future<void> _openDocsModal() async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: kBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(kRadiusXXL),
        ),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Документы',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Пользовательское соглашение и Политика конфиденциальности',
                ),
                subtitle: const Text(
                  'offlag.ru/docs/privacy_policy',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _openUrl('https://offlag.ru/docs/privacy_policy');
                },
              ),
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Публичная оферта'),
                subtitle: const Text(
                  'offlag.ru/docs/public_offer',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _openUrl('https://offlag.ru/docs/public_offer');
                },
              ),
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Политика возврата'),
                subtitle: const Text(
                  'offlag.ru/docs/refund_policy',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _openUrl('https://offlag.ru/docs/refund_policy');
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.me;

    return RefreshIndicator(
      onRefresh: widget.onRefreshMe,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        children: [
          Row(
            children: [
              Text(
                'Профиль',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(width: 8),
              if (widget.loadingMe)
                const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 16),
          // Карточка профиля
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.circular(kRadiusXXL),
              border: Border.all(color: kBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _kv(context, 'Никнейм', me?.nickname ?? '—'),
                const SizedBox(height: 6),
                _kv(context, 'Email', me?.email ?? '—'),
                const SizedBox(height: 6),
                _kv(
                  context,
                  'Тариф',
                  me == null
                      ? '—'
                      : '${me.planName.isEmpty ? me.planCode : me.planName}'
                      '${me.effectivePrice > 0 ? '${me.formattedEffective} ₽/мес' : ''}',
                ),
                const SizedBox(height: 6),
                _kv(
                  context,
                  'Активных сессий',
                  '${me?.activeSessions ?? 0}',
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _logout,
                        child: const Text('Выйти'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _openChangeEmailFlow,
                        child: const Text('Сменить e-mail'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Карточка баланса
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.circular(kRadiusXXL),
              border: Border.all(color: kBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Баланс',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  '${_fmtMoney(me?.balance ?? 0)} ₽',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Хватит до: ${_enoughUntil(me)}',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: Colors.white70),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          showModalBottomSheet(
                            context: context,
                            useSafeArea: true,
                            isScrollControlled: true,
                            showDragHandle: true,
                            backgroundColor: kBg,
                            shape: const RoundedRectangleBorder(
                              borderRadius: BorderRadius.vertical(
                                top: Radius.circular(kRadiusXXL),
                              ),
                            ),
                            builder: (_) => TopUpSheet(
                              onPaymentStarted:
                              _startAutoRefreshAfterPayment,
                            ),
                          );
                        },
                        child:
                        const Center(child: Text('Пополнить')),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _openPromoDialog,
                        child: const Center(
                          child: Text(
                            'Ввести промокод',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Карточка документов
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.circular(kRadiusXXL),
              border: Border.all(color: kBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Юридические документы',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'Пользовательское соглашение, Политика конфиденциальности, '
                      'Публичная оферта и Политика возврата.',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: Colors.white70),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _openDocsModal,
                    child: const Text('Документы'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Пара «ключ-значение» в две строки с аккуратными отступами.
  Widget _kv(BuildContext context, String k, String v) {
    final styleK = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: Colors.white70);
    final styleV = Theme.of(context)
        .textTheme
        .bodyMedium
        ?.copyWith(fontWeight: FontWeight.w600);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(k, style: styleK),
        const SizedBox(height: 2),
        Text(
          v,
          style: styleV,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
