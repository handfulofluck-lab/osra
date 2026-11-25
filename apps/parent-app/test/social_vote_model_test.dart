import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/api/models.dart';

void main() {
  test('SocialConcernEvent reads the latest feedback without message text', () {
    // Mutant: ignoring latestFeedback, reading a different verdict key, or dropping
    // either timestamp leaves co-parents without the current vote and its history.
    final event = SocialConcernEvent.fromJson({
      'id': 'event-1',
      'app': 'whatsapp',
      'contact': 'Maya',
      'severity': 'warning',
      'preview': 'vault excerpt',
      'concernTypes': ['grooming_risk'],
      'createdAt': '2026-11-24T10:00:00.000Z',
      'latestFeedback': {
        'verdict': 'not_concerning',
        'parentDisplayName': 'Lina',
        'firstVotedAt': '2026-11-24T10:01:00.000Z',
        'lastChangedAt': '2026-11-24T10:02:00.000Z',
      },
      'ownFeedback': {
        'verdict': 'concerning',
        'parentDisplayName': 'QA Parent',
        'firstVotedAt': '2026-11-24T09:01:00.000Z',
        'lastChangedAt': '2026-11-24T09:02:00.000Z',
      },
    });

    expect(event.latestFeedbackVerdict, 'not_concerning');
    expect(event.latestFeedbackParentDisplayName, 'Lina');
    expect(event.latestFeedbackFirstVotedAt, DateTime.utc(2026, 11, 24, 10, 1));
    expect(
        event.latestFeedbackLastChangedAt, DateTime.utc(2026, 11, 24, 10, 2));
    expect(event.ownFeedbackVerdict, 'concerning');
    expect(event.ownFeedbackFirstVotedAt, DateTime.utc(2026, 11, 24, 9, 1));
    expect(event.ownFeedbackLastChangedAt, DateTime.utc(2026, 11, 24, 9, 2));
  });

  test(
      'SocialConcernEvent treats missing or withdrawn latest feedback as unset',
      () {
    // Mutant: defaulting an absent vote to concerning would replace the two
    // choices with a selected pill for parents who never voted.
    for (final feedback in <Object?>[null, <String, dynamic>{}]) {
      final event = SocialConcernEvent.fromJson({
        'id': 'event-1',
        'app': 'whatsapp',
        'contact': 'Maya',
        'severity': 'warning',
        'preview': '',
        'latestFeedback': feedback,
      });

      expect(event.latestFeedbackVerdict, isNull);
      expect(event.latestFeedbackParentDisplayName, isNull);
      expect(event.latestFeedbackFirstVotedAt, isNull);
      expect(event.latestFeedbackLastChangedAt, isNull);
      expect(event.ownFeedbackVerdict, isNull);
      expect(event.ownFeedbackFirstVotedAt, isNull);
      expect(event.ownFeedbackLastChangedAt, isNull);
    }
  });
}
