// Karim, 23 Nov: the iPhone kept showing "Protection tampered with" notifications, blue (info) and red
// (critical). The notification title ignored the alert's metadata.type, so the agent's own "Agent updated"
// notice, a phone going quiet and real tampering all read the same. The notification now says what happened.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/l10n/l10n.dart';
import 'package:familyshield_parent/push/local_notifier.dart';

void main() {
  late AppLocalizations en;
  late AppLocalizations ar;

  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    ar = await AppLocalizations.delegate.load(const Locale('ar'));
  });

  Alert tamper(String type, {String severity = 'critical'}) => Alert(
        id: 'a-$type',
        childId: 'child-1',
        severity: severity,
        category: 'tamper',
        title: 'SERVER ENGLISH',
        body: 'SERVER ENGLISH BODY',
        metadata: {'type': type},
      );

  test('the notification for a tamper alert is titled by its type, in both locales', () {
    expect(VisibleAlert.from(tamper('replaced', severity: 'info'), l10n: en, isEnglish: true).title, en.alertTitleAgentUpdated);
    expect(VisibleAlert.from(tamper('device_silent'), l10n: en, isEnglish: true).title, en.alertTitleDeviceSilent);
    expect(VisibleAlert.from(tamper('accessibility_off'), l10n: ar, isEnglish: false).title, ar.alertTitleProtectionOff);
    expect(VisibleAlert.from(tamper('accessibility'), l10n: en, isEnglish: true).title, en.alertTitleProtectionOff);
    expect(VisibleAlert.from(tamper('block_bypass'), l10n: ar, isEnglish: false).title, ar.alertTitleBlockBypass);
  });

  test('an unknown tamper type keeps the generic title and never shows the server English body', () {
    final v = VisibleAlert.from(tamper('some_future_type'), l10n: ar, isEnglish: false);
    expect(v.title, ar.alertTitleTamper);
    expect(v.body, ar.alertPushBodyGeneric);
  });
}
