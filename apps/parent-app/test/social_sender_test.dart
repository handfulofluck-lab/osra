import 'package:familyshield_parent/core/ltr_isolate.dart';
import 'package:familyshield_parent/core/social_sender.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A raw phone label instead of the masked result fails this row.
  test('number labels keep only the final four Western digits in an LTR run',
      () {
    final expected = ltrIsolate('•••• 0124');
    expect(socialSenderDisplayName('+1 202 555 0124'), expected);
    expect(socialSenderDisplayName('(202) 555-0124'), expected);
    expect(
        socialSenderDisplayName(
            '\u0662\u0660\u0662 \u0665\u0665\u0665 \u0660\u0661\u0662\u0664'),
        expected);
  });

  // Removing direction-mark cleanup prevents number recognition in this row.
  test('invisible RTL marks do not prevent a visible number being masked', () {
    expect(socialSenderDisplayName('\u200E+1 202 555 0124\u200E'),
        ltrIsolate('•••• 0124'));
  });

  // Unconditional masking would also hide real display names and profiles.
  test('display names and profile labels survive while blank text is missing',
      () {
    expect(socialSenderDisplayName('  Sample Name  '), 'Sample Name');
    expect(socialSenderDisplayName('~Sample profile'), '~Sample profile');
    expect(socialSenderDisplayName(null), isNull);
    expect(socialSenderDisplayName(''), isNull);
    expect(socialSenderDisplayName(' \u200B \u200F '), isNull);
  });

  test('a short numeric label does not disclose the whole number', () {
    expect(socialSenderDisplayName('0124'), ltrIsolate('••••'));
  });
}
