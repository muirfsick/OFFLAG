import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';

/// BottomSheet для ввода нового e-mail и валидации адреса.
///
/// По подтверждению возвращает введённый адрес через `Navigator.pop(email)`.
class ChangeEmailSheet extends StatefulWidget {
  const ChangeEmailSheet({super.key});

  @override
  State<ChangeEmailSheet> createState() => _ChangeEmailSheetState();
}

class _ChangeEmailSheetState extends State<ChangeEmailSheet> {
  /// Контроллер поля ввода e-mail.
  final _ctrl = TextEditingController();

  /// Ключ формы для проверки валидности.
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Проверяет, что строка похожа на корректный e-mail.
  String? _validate(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return 'Введите e-mail';
    final ok = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s);
    if (!ok) return 'Некорректный e-mail';
    return null;
  }

  /// Вставляет текст из буфера обмена в поле e-mail.
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final txt = (data?.text ?? '').trim();
    if (txt.isNotEmpty) {
      _ctrl.text = txt;
      _ctrl.selection = TextSelection.collapsed(offset: txt.length);
    }
  }

  /// Разметка шита: поле e-mail, кнопка вставки и отправки кода.
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: 20 + MediaQuery.of(context).viewInsets.bottom,
        top: 16,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: Text('Смена e-mail', style: Theme.of(context).textTheme.titleLarge)),
            const SizedBox(height: 12),
            TextFormField(
              controller: _ctrl,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                hintText: 'new@example.com',
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
              ),
              validator: _validate,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _paste,
                  icon: const Icon(Icons.paste),
                  label: const Text('Вставить'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () {
                    if (_formKey.currentState?.validate() ?? false) {
                      Navigator.of(context).pop(_ctrl.text.trim());
                    }
                  },
                  child: const Text('Отправить код'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
