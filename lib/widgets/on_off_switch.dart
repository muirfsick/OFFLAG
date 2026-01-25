import 'package:flutter/material.dart';
import '../theme.dart';

/// Кастомный тумблер включения/выключения с анимацией и drag-жестами.
///
/// Поддерживает:
/// - программное управление значением через [value] и [onChanged];
/// - блокировку взаимодействия через [enabled];
/// - колбэк [onBlocked], вызываемый при попытке взаимодействия в заблокированном состоянии.
class OnOffSwitch extends StatefulWidget {
  /// Текущее значение тумблера.
  final bool value;

  /// Колбэк при изменении значения.
  final ValueChanged<bool> onChanged;

  /// Флаг доступности тумблера. Если `false`, жесты отключены.
  final bool enabled;

  /// Колбэк, вызываемый при тапе по заблокированному тумблеру.
  final VoidCallback? onBlocked;

  const OnOffSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.onBlocked,
  });

  @override
  State<OnOffSwitch> createState() => _OnOffSwitchState();
}

class _OnOffSwitchState extends State<OnOffSwitch> with SingleTickerProviderStateMixin {
  static const _w = 200.0;
  static const _h = 88.0;
  static const _pad = 8.0;
  static const _knob = _h - _pad * 2;

  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: widget.value ? 1 : 0,
  );
  late final Animation<double> _t = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);

  double get _trackW => _w - 2 * _pad - _knob;

  @override
  void didUpdateWidget(covariant OnOffSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
      widget.value ? _ctrl.forward() : _ctrl.reverse();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Вызывает [onBlocked], если тумблер заблокирован.
  void _blocked() {
    if (widget.onBlocked != null) widget.onBlocked!();
  }

  /// Переключает значение тумблера (если не заблокирован).
  void _toggle() {
    if (!widget.enabled) return _blocked();
    widget.onChanged(!widget.value);
  }

  /// Обработчик горизонтального перетаскивания для плавного изменения состояния.
  void _onDragUpdate(DragUpdateDetails d) {
    if (!widget.enabled) return;
    final dv = (d.primaryDelta ?? 0) / _trackW;
    _ctrl.value = (_ctrl.value + dv).clamp(0.0, 1.0);
  }

  /// Завершение перетаскивания: выбирает конечное состояние по скорости/позиции.
  void _onDragEnd(DragEndDetails d) {
    if (!widget.enabled) return;
    final vx = d.primaryVelocity ?? 0.0;
    final bool target = vx.abs() > 300 ? (vx > 0) : (_ctrl.value >= 0.5);
    if (target != widget.value) {
      widget.onChanged(target);
    } else {
      target ? _ctrl.forward() : _ctrl.reverse();
    }
  }

  /// Рендерит тумблер: фон, подписи и круглый ползунок.
  @override
  Widget build(BuildContext context) {
    const txtStyle = TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.w800,
      color: Colors.white,
      shadows: [Shadow(blurRadius: 1, offset: Offset(0, 1), color: Colors.black45)],
    );

    final disabled = !widget.enabled;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggle,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      child: AnimatedBuilder(
        animation: _t,
        builder: (context, _) {
          final bgOn = const Color(0xFF2ECC71);
          final bgOff = kSurface;
          final bg = Color.lerp(bgOff, bgOn, _t.value)!;

          return Opacity(
            opacity: disabled ? 0.75 : 1,
            child: Container(
              width: _w,
              height: _h,
              decoration: BoxDecoration(
                color: disabled ? kSurface : bg,
                borderRadius: BorderRadius.circular(_h / 2),
                border: Border.all(color: kBorder),
              ),
              padding: const EdgeInsets.all(_pad),
              child: Stack(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Opacity(
                      opacity: 0.9 * _t.value,
                      child: const Padding(
                        padding: EdgeInsets.only(left: 18),
                        child: Text('OFF LAG', style: txtStyle),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Opacity(
                      opacity: 0.9 * (1 - _t.value),
                      child: const Padding(
                        padding: EdgeInsets.only(right: 18),
                        child: Text('OFF', style: txtStyle),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment(-1 + 2 * _t.value, 0),
                    child: Container(
                      width: _knob,
                      height: _knob,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: const [BoxShadow(blurRadius: 8, offset: Offset(0, 2), color: Colors.black26)],
                        border: Border.all(color: kBorder),
                      ),
                    ),
                  ),
                  if (disabled)
                    Positioned.fill(
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _blocked,
                          splashColor: Colors.transparent,
                          highlightColor: Colors.transparent,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
