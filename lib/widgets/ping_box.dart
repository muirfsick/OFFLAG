import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme.dart';

/// Небольшой бэйдж со страной и пингом.
///
/// Отрисовывает флаг (SVG из `assets/icons/<iso2>.svg` с фолбэком на эмодзи),
/// затем подпись вида: `<Страна> • <ping> ms`.
class PingBox extends StatelessWidget {
  const PingBox({
    super.key,
    required this.countryLabel,
    required this.pingMs,
    required this.countryCode,
  });

  /// Подпись страны (локализованное название).
  final String countryLabel;

  /// Пинг до выбранного сервера в миллисекундах.
  final int pingMs;

  /// Двухбуквенный ISO-код страны (например, `nl`).
  final String countryCode;

  /// Простейшая карта фолбэков эмодзи, если нет SVG-флага в ассетах.
  static const _emojiByCode = {
    'nl': '🇳🇱',
    'de': '🇩🇪',
    'fr': '🇫🇷',
    'se': '🇸🇪',
    'fi': '🇫🇮',
  };

  /// Рендерит контейнер с флагом/эмодзи и текстом `<countryLabel> • <pingMs> ms`.
  @override
  Widget build(BuildContext context) {
    final code = countryCode.toLowerCase();
    final assetPath = 'assets/icons/$code.svg';
    final emojiFallback = _emojiByCode[code] ?? '🌐';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(kRadiusXL),
        border: Border.all(color: kBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 20,
            child: SvgPicture.asset(
              assetPath,
              fit: BoxFit.cover,
              clipBehavior: Clip.antiAlias,
              placeholderBuilder: (_) => Center(
                child: Text(emojiFallback, style: const TextStyle(fontSize: 16)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$countryLabel • $pingMs ms',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
