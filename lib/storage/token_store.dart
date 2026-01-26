import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TokenStore {
  static const _kToken = 'auth_token';
  static const _kEmail = 'auth_email';
  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static Future<void> save(String token, String email) async {
    await _secure.write(key: _kToken, value: token);
    await _secure.write(key: _kEmail, value: email);

    // Keep a SharedPreferences copy for migration/compatibility.
    final p = await SharedPreferences.getInstance();
    await p.setString(_kToken, token);
    await p.setString(_kEmail, email);
  }

  static Future<String?> get token async {
    final stored = await _secure.read(key: _kToken);
    if (stored != null && stored.isNotEmpty) return stored;

    // Migrate legacy value from SharedPreferences if present.
    final p = await SharedPreferences.getInstance();
    final legacy = p.getString(_kToken);
    if (legacy != null && legacy.isNotEmpty) {
      await _secure.write(key: _kToken, value: legacy);
    }
    return legacy;
  }

  static Future<String?> get email async {
    final stored = await _secure.read(key: _kEmail);
    if (stored != null && stored.isNotEmpty) return stored;

    // Migrate legacy value from SharedPreferences if present.
    final p = await SharedPreferences.getInstance();
    final legacy = p.getString(_kEmail);
    if (legacy != null && legacy.isNotEmpty) {
      await _secure.write(key: _kEmail, value: legacy);
    }
    return legacy;
  }

  static Future<void> clear() async {
    await _secure.delete(key: _kToken);
    await _secure.delete(key: _kEmail);

    final p = await SharedPreferences.getInstance();
    await p.remove(_kToken);
    await p.remove(_kEmail);
  }
}
