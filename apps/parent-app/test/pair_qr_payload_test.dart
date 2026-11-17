import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/features/pairing/pair_qr_payload.dart';

void main() {
  group('PairQrPayload.encode', () {
    test('is the documented v1 format, with a stable parameter order', () {
      const payload =
          PairQrPayload(code: '482916', apiBaseUrl: 'http://192.168.1.5:3000');
      expect(
        payload.encode(),
        'osra://pair?v=1&code=482916&host=http%3A%2F%2F192.168.1.5%3A3000',
      );
    });

    test('keeps an https host with a path', () {
      const payload = PairQrPayload(
          code: '000042', apiBaseUrl: 'https://osra.example.com/api');
      expect(
        payload.encode(),
        'osra://pair?v=1&code=000042&host=https%3A%2F%2Fosra.example.com%2Fapi',
      );
    });

    test('refuses a non-six-digit code and a non-http host', () {
      expect(
        () => const PairQrPayload(
                code: 'ABC123', apiBaseUrl: 'http://192.168.1.5:3000')
            .encode(),
        throwsFormatException,
      );
      expect(
        () =>
            const PairQrPayload(code: '482916', apiBaseUrl: '192.168.1.5:3000')
                .encode(),
        throwsFormatException,
      );
      expect(
        () =>
            const PairQrPayload(code: '482916', apiBaseUrl: 'ftp://example.com')
                .encode(),
        throwsFormatException,
      );
    });
  });

  group('PairQrPayload.decode', () {
    test('round-trips every field', () {
      const original =
          PairQrPayload(code: '482916', apiBaseUrl: 'http://10.0.2.2:3000');
      expect(PairQrPayload.decode(original.encode()), original);
    });

    test('refuses a bare code and other schemes/authorities', () {
      expect(() => PairQrPayload.decode('482916'), throwsFormatException);
      expect(
          () => PairQrPayload.decode(
              'https://pair?v=1&code=482916&host=http%3A%2F%2Fx'),
          throwsFormatException);
      expect(
          () => PairQrPayload.decode(
              'osra://join?v=1&code=482916&host=http%3A%2F%2Fx'),
          throwsFormatException);
    });

    test('refuses unknown versions, missing fields and bad values', () {
      expect(
        () => PairQrPayload.decode(
            'osra://pair?v=2&code=482916&host=http%3A%2F%2Fx'),
        throwsFormatException,
      );
      expect(
        () => PairQrPayload.decode('osra://pair?v=1&host=http%3A%2F%2Fx'),
        throwsFormatException,
      );
      expect(
        () =>
            PairQrPayload.decode('osra://pair?v=1&code=12&host=http%3A%2F%2Fx'),
        throwsFormatException,
      );
      expect(
        () => PairQrPayload.decode(
            'osra://pair?v=1&code=482916&host=192.168.1.5%3A3000'),
        throwsFormatException,
      );
    });

    test('tryDecode returns null instead of throwing', () {
      expect(PairQrPayload.tryDecode('not a pairing payload'), isNull);
      expect(
        PairQrPayload.tryDecode(
            'osra://pair?v=1&code=482916&host=http%3A%2F%2F192.168.1.5%3A3000'),
        const PairQrPayload(
            code: '482916', apiBaseUrl: 'http://192.168.1.5:3000'),
      );
    });
  });

  group('Arabic digits (#771)', () {
    test('decode normalises a code typed with Arabic digits', () {
      // ١٢٣٤٥٦ percent-encoded, as a scanner can hand it over.
      final payload = PairQrPayload.decode(
          'osra://pair?v=1&code=%D9%A1%D9%A2%D9%A3%D9%A4%D9%A5%D9%A6'
          '&host=http%3A%2F%2F192.168.1.5%3A3000');
      expect(payload.code, '123456');
    });

    test('decode accepts the Extended Arabic-Indic family too', () {
      final payload = PairQrPayload.decode(
          'osra://pair?v=1&code=%DB%B0%DB%B1%DB%B2%DB%B3%DB%B4%DB%B5'
          '&host=http%3A%2F%2F192.168.1.5%3A3000');
      expect(payload.code, '012345');
    });

    test('encode emits Western digits for an Arabic-digit code', () {
      const payload =
          PairQrPayload(code: '١٢٣٤٥٦', apiBaseUrl: 'http://192.168.1.5:3000');
      expect(payload.encode(), contains('code=123456'));
    });
  });
}
