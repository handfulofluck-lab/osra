import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/client.dart';
import 'package:familyshield_parent/providers/server_provider.dart';
import 'package:familyshield_parent/push/background_push.dart';

/// osra-security#8 F3, the child's rule from #553: a build with `API_BASE` built in (the store builds) talks to
/// that server only. A typed URL, a URL saved by an earlier build, and a wake all end at the built-in server, and
/// the login field is locked. A build without it keeps today's editable field.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const builtIn = 'https://api.osratech.com';
  const other = 'https://other.example';

  group('the rule', () {
    test('a built-in server locks the field and wins over a saved one', () {
      expect(isServerLocked(builtIn), isTrue);
      expect(builtInServerUrl(builtIn), builtIn);
      expect(effectiveServerUrl(saved: other, builtIn: builtIn), builtIn);
      expect(effectiveServerUrl(saved: null, builtIn: builtIn), builtIn);
    });

    test('without one the field stays editable and the saved server is used', () {
      expect(isServerLocked(''), isFalse);
      expect(builtInServerUrl(''), isNull);
      expect(effectiveServerUrl(saved: ' 192.168.1.5:3000/ ', builtIn: ''), 'http://192.168.1.5:3000');
      expect(effectiveServerUrl(saved: 'not a url', builtIn: ''), '');
    });

    test('a test build has no built-in server, so nothing here changes local testing', () {
      expect(isServerLocked(), isFalse);
    });
  });

  group('the notifier', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({kServerUrlKey: other});
    });

    test('a locked build ignores the saved URL and anything typed', () async {
      final api = ApiClient();
      final notifier = ServerUrlNotifier(api, builtIn: builtIn);
      await notifier.ensureApplied();
      expect(notifier.state, builtIn);
      await notifier.setServerUrl('https://typed.example');
      expect(notifier.state, builtIn);
      expect(api.raw.options.baseUrl, builtIn);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kServerUrlKey), other, reason: 'nothing typed is saved');
      notifier.dispose();
    });

    test('an unlocked build keeps the saved URL and takes a typed one', () async {
      final api = ApiClient();
      final notifier = ServerUrlNotifier(api, builtIn: '');
      await notifier.ensureApplied();
      expect(notifier.state, other);
      await notifier.setServerUrl('http://10.0.2.2:3000');
      expect(notifier.state, 'http://10.0.2.2:3000');
      expect(api.raw.options.baseUrl, 'http://10.0.2.2:3000');
      notifier.dispose();
    });
  });

  test('a wake uses the built-in server whatever was saved', () {
    expect(resolveBackgroundBaseUrl(other, builtIn: builtIn), builtIn);
    expect(resolveBackgroundBaseUrl(null, builtIn: builtIn), builtIn);
    expect(resolveBackgroundBaseUrl(other, builtIn: ''), other);
  });

  test('the login field is locked, and a locked build never reads it', () {
    final src = File('lib/features/auth/login_screen.dart').readAsStringSync();
    final field = src.substring(src.indexOf("key: const ValueKey('loginServerField')"));
    expect(field.substring(0, 400), contains('readOnly: isServerLocked(),'));
    expect(field.substring(0, 400), contains('enabled: !isServerLocked(),'));
    final save = src.substring(src.indexOf('Future<String?> _saveServer() async {'));
    final builtInReturn = save.indexOf('if (builtIn != null) return builtIn;');
    expect(builtInReturn, greaterThan(0));
    expect(builtInReturn, lessThan(save.indexOf('_server.text')), reason: 'the built-in server returns before the field is read');
  });
}
