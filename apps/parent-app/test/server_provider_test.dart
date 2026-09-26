import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/providers/server_provider.dart';

void main() {
  group('normalizeServerUrl', () {
    test('trims, strips trailing slashes, requires http(s)://host[:port]', () {
      expect(normalizeServerUrl('  http://192.168.1.5:3000/  '), 'http://192.168.1.5:3000');
      expect(normalizeServerUrl('https://example.com///'), 'https://example.com');
      expect(normalizeServerUrl('http://10.0.2.2:3000'), 'http://10.0.2.2:3000');
      expect(normalizeServerUrl('http://example.com:8080/api/'), 'http://example.com:8080/api');
      expect(normalizeServerUrl(''), isNull);
      expect(normalizeServerUrl('http://'), isNull); // no host
      expect(normalizeServerUrl('ftp://example.com'), isNull);
    });

    test('prepends http:// for scheme-less input (BUG-006)', () {
      expect(normalizeServerUrl('10.0.2.2:3000'), 'http://10.0.2.2:3000');
      expect(normalizeServerUrl('192.168.1.5:3000/'), 'http://192.168.1.5:3000');
      expect(normalizeServerUrl('example.com'), 'http://example.com');
    });

    test('accepts hyphenated LAN hostnames', () {
      expect(normalizeServerUrl('my-server.local'), 'http://my-server.local');
      expect(normalizeServerUrl('http://my-server.local:3000'), 'http://my-server.local:3000');
      expect(normalizeServerUrl('https://osra-server.local/api/'), 'https://osra-server.local/api');
    });
  });

  group('first-run default', () {
    test('default server URL is blank until the tester enters one', () {
      expect(kDefaultServerUrl, '');
      expect(normalizeServerUrl(kDefaultServerUrl), isNull);
    });
  });
}
