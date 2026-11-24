import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:familyshield_parent/api/models.dart';
import 'package:familyshield_parent/providers/auth_provider.dart';
import 'package:familyshield_parent/providers/social_provider.dart';
import 'package:familyshield_parent/providers/social_vote_provider.dart';

import 'fake_api_client.dart';

class _AuthHarness extends AuthNotifier {
  _AuthHarness(FakeApiClient api) : super(api);

  void useParent(String id) {
    state = AuthState(
      isAuthenticated: true,
      parent: Parent(
        id: id,
        familyId: 'fam-1',
        email: '$id@example.test',
        displayName: 'QA Parent',
      ),
    );
  }

  Future<void> logout() async {
    state = const AuthState();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late FakeApiClient api;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() => container.dispose());

  Map<String, dynamic> eventJson(
          {Object? feedback = const <String, dynamic>{}}) =>
      {
        'id': 'event-1',
        'childId': 'child-1',
        'app': 'whatsapp',
        'contact': 'Maya',
        'severity': 'warning',
        'preview': 'vault excerpt',
        'concernTypes': ['grooming_risk'],
        'createdAt': '2026-11-24T10:00:00.000Z',
        'latestFeedback': feedback,
      };

  Map<String, dynamic> feedbackJson(String verdict,
          {String parentDisplayName = 'Lina'}) =>
      {
        'verdict': verdict,
        'parentDisplayName': parentDisplayName,
        'firstVotedAt': '2026-11-24T10:01:00.000Z',
        'lastChangedAt': '2026-11-24T10:02:00.000Z',
      };

  ProviderContainer makeContainer(FakeApiClient client) {
    api = client;
    return ProviderContainer(
        overrides: [apiClientProvider.overrideWithValue(client)]);
  }

  Future<void> flushAsync() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('the social event response seeds the shared vote state', () async {
    container = makeContainer(FakeApiClient({
      ...standardRoutes(),
      'GET /v1/social/events': (_) => {
            'items': [eventJson(feedback: feedbackJson('not_concerning'))],
          },
    }));

    await container.read(socialEventsProvider('child-1').future);
    final vote = container.read(socialVoteProvider('event-1'));

    expect(vote.verdict, 'not_concerning');
    expect(vote.parentDisplayName, 'Lina');
    expect(vote.firstVotedAt, DateTime.utc(2026, 11, 24, 10, 1));
    expect(vote.lastChangedAt, DateTime.utc(2026, 11, 24, 10, 2));
  });

  test('vote is optimistic and POSTs the exact concerning mapping', () async {
    // Mutant: swapping concerning/not_concerning or waiting for the response before
    // updating state fails both the immediate optimistic and request-body checks.
    final pending = Completer<Object?>();
    container = makeContainer(FakeApiClient({
      ...standardRoutes(),
      'POST /v1/social/events/event-1/feedback': (_) =>
          FakeDeferred(pending.future),
    }));
    final controller = container.read(socialVoteProvider('event-1').notifier);

    final saving = controller.vote('concerning');
    await flushAsync();

    expect(container.read(socialVoteProvider('event-1')).verdict, 'concerning');
    expect(container.read(socialVoteProvider('event-1')).isSaving, isTrue);
    final call = api.calls('POST', '/v1/social/events/event-1/feedback').single;
    expect(call.body, {'verdict': 'concerning'});

    pending.complete({'feedback': feedbackJson('concerning')});
    await saving;
    expect(container.read(socialVoteProvider('event-1')).isSaving, isFalse);
    expect(container.read(socialVoteProvider('event-1')).parentDisplayName,
        'Lina');
  });

  test('changing POSTs not_concerning and selecting it again is inert',
      () async {
    container = makeContainer(FakeApiClient({
      ...standardRoutes(),
      'POST /v1/social/events/event-1/feedback': (request) => {
            'feedback': feedbackJson(request.body['verdict'] as String),
          },
    }));
    final controller = container.read(socialVoteProvider('event-1').notifier);

    await controller.vote('concerning');
    await controller.vote('not_concerning');
    await controller.vote('not_concerning');

    final calls = api.calls('POST', '/v1/social/events/event-1/feedback');
    expect(calls, hasLength(2));
    expect(calls[0].body, {'verdict': 'concerning'});
    expect(calls[1].body, {'verdict': 'not_concerning'});
    expect(container.read(socialVoteProvider('event-1')).verdict,
        'not_concerning');
  });

  test(
      'undoing the first vote withdraws with DELETE and undoing a change restores it',
      () async {
    // Mutant: implementing Undo as a local-only change or always deleting would
    // respectively leave the server vote behind or fail to restore a prior vote.
    container = makeContainer(FakeApiClient({
      ...standardRoutes(),
      'POST /v1/social/events/event-1/feedback': (request) => {
            'feedback': feedbackJson(request.body['verdict'] as String,
                parentDisplayName: 'QA Parent'),
          },
      'DELETE /v1/social/events/event-1/feedback': (_) => {'feedback': null},
    }));
    final controller = container.read(socialVoteProvider('event-1').notifier);

    await controller.vote('concerning');
    await controller.undo();
    expect(api.calls('DELETE', '/v1/social/events/event-1/feedback'),
        hasLength(1));
    expect(container.read(socialVoteProvider('event-1')).verdict, isNull);

    await controller.vote('concerning');
    await controller.vote('not_concerning');
    await controller.undo();
    expect(api.calls('POST', '/v1/social/events/event-1/feedback').last.body,
        {'verdict': 'concerning'});
    expect(container.read(socialVoteProvider('event-1')).verdict, 'concerning');
  });

  test('immediate Undo waits for the first POST before sending DELETE',
      () async {
    // Mutant: parallel writes let a slow first POST finish after DELETE and
    // recreate the vote the parent just withdrew.
    final firstPost = Completer<Object?>();
    container = makeContainer(FakeApiClient({
      ...standardRoutes(),
      'POST /v1/social/events/event-1/feedback': (_) =>
          FakeDeferred(firstPost.future),
      'DELETE /v1/social/events/event-1/feedback': (_) => {'feedback': null},
    }));
    final controller = container.read(socialVoteProvider('event-1').notifier);

    final vote = controller.vote('concerning');
    await flushAsync();
    final undo = controller.undo();
    await flushAsync();

    expect(
        api.calls('POST', '/v1/social/events/event-1/feedback'), hasLength(1));
    final deletesBeforeFirstAnswer =
        api.calls('DELETE', '/v1/social/events/event-1/feedback').length;
    final optimisticVerdict =
        container.read(socialVoteProvider('event-1')).verdict;
    final optimisticSaving =
        container.read(socialVoteProvider('event-1')).isSaving;

    firstPost.complete({
      'feedback': feedbackJson('concerning', parentDisplayName: 'QA Parent'),
    });
    await Future.wait([vote, undo]);

    expect(deletesBeforeFirstAnswer, 0);
    expect(optimisticVerdict, isNull);
    expect(optimisticSaving, isTrue);
    expect(api.calls('DELETE', '/v1/social/events/event-1/feedback'),
        hasLength(1));
    expect(api.requests.map((request) => request.method),
        containsAllInOrder(['POST', 'DELETE']));
    expect(container.read(socialVoteProvider('event-1')).verdict, isNull);
    expect(container.read(socialVoteProvider('event-1')).isSaving, isFalse);
  });

  test(
      'Undo after voting over a co-parent verdict withdraws instead of restoring it',
      () async {
    // Mutant: replaying the previous latestFeedback writes the co-parent's
    // verdict as the current parent instead of deleting the current parent's vote.
    container = makeContainer(FakeApiClient({
      ...standardRoutes(),
      'GET /v1/social/events': (_) => {
            'items': [eventJson(feedback: feedbackJson('not_concerning'))],
          },
      'POST /v1/social/events/event-1/feedback': (request) => {
            'feedback': feedbackJson(request.body['verdict'] as String,
                parentDisplayName: 'QA Parent'),
          },
      'DELETE /v1/social/events/event-1/feedback': (_) => {'feedback': null},
    }));
    await container.read(socialEventsProvider('child-1').future);
    final controller = container.read(socialVoteProvider('event-1').notifier);

    await controller.vote('concerning');
    await controller.undo();

    expect(api.calls('DELETE', '/v1/social/events/event-1/feedback'),
        hasLength(1));
    expect(
        api.calls('POST', '/v1/social/events/event-1/feedback'), hasLength(1));
    expect(api.calls('POST', '/v1/social/events/event-1/feedback').single.body,
        {'verdict': 'concerning'});
    expect(container.read(socialVoteProvider('event-1')).verdict, isNull);
  });

  test(
      'failure preserves the optimistic vote and retry replays the same operation',
      () async {
    var attempts = 0;
    container = makeContainer(FakeApiClient({
      ...standardRoutes(),
      'POST /v1/social/events/event-1/feedback': (_) {
        attempts++;
        return attempts == 1
            ? const FakeNetworkError()
            : {'feedback': feedbackJson('not_concerning')};
      },
    }));
    final controller = container.read(socialVoteProvider('event-1').notifier);

    await controller.vote('not_concerning');
    var vote = container.read(socialVoteProvider('event-1'));
    expect(vote.verdict, 'not_concerning');
    expect(vote.needsRetry, isTrue);
    expect(vote.isSaving, isFalse);

    await controller.retry();
    vote = container.read(socialVoteProvider('event-1'));
    expect(attempts, 2);
    expect(vote.verdict, 'not_concerning');
    expect(vote.needsRetry, isFalse);
    expect(vote.parentDisplayName, 'Lina');
    expect(
        api.calls('POST', '/v1/social/events/event-1/feedback'), hasLength(2));
    expect(
        api.calls('POST', '/v1/social/events/event-1/feedback').every(
              (call) => call.body['verdict'] == 'not_concerning',
            ),
        isTrue);
  });

  test(
      'logout and parent changes clear failed optimistic votes and pending retry',
      () async {
    // Mutant: retaining the family provider's vote state lets the next parent
    // see and retry an optimistic vote created under the previous session.
    api = FakeApiClient({
      ...standardRoutes(),
      'POST /v1/social/events/event-1/feedback': (_) =>
          const FakeNetworkError(),
    });
    final auth = _AuthHarness(api);
    container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      authProvider.overrideWith((ref) => auth),
    ]);
    auth.useParent('parent-1');
    final controller = container.read(socialVoteProvider('event-1').notifier);

    await controller.vote('concerning');
    expect(container.read(socialVoteProvider('event-1')).needsRetry, isTrue);

    auth.useParent('parent-2');
    await flushAsync();
    var vote = container.read(socialVoteProvider('event-1'));
    expect(vote.verdict, isNull);
    expect(vote.needsRetry, isFalse);
    expect(vote.isSaving, isFalse);

    await controller.vote('not_concerning');
    expect(container.read(socialVoteProvider('event-1')).needsRetry, isTrue);
    auth.logout();
    await flushAsync();
    vote = container.read(socialVoteProvider('event-1'));
    expect(vote.verdict, isNull);
    expect(vote.parentDisplayName, isNull);
    expect(vote.needsRetry, isFalse);
    expect(vote.isSaving, isFalse);
    expect(
        api.calls('POST', '/v1/social/events/event-1/feedback'), hasLength(2));
  });

  for (final status in const [403, 404]) {
    test('$status marks the vote unavailable and never retries it', () async {
      // Mutant: treating permanent refusal like a transport error leaves an
      // optimistic pill with a Retry action that can never succeed.
      container = makeContainer(FakeApiClient({
        ...standardRoutes(),
        'POST /v1/social/events/event-1/feedback': (_) =>
            FakeHttpError(status, {'error': 'feedback_unavailable'}),
      }));
      final controller = container.read(socialVoteProvider('event-1').notifier);

      await controller.vote('concerning');
      final vote = container.read(socialVoteProvider('event-1'));
      expect(vote.isUnavailable, isTrue);
      expect(vote.needsRetry, isFalse);
      expect(vote.isSaving, isFalse);

      await controller.retry();
      expect(api.calls('POST', '/v1/social/events/event-1/feedback'),
          hasLength(1));
    });
  }

  test('withdrawal is an idempotent DELETE and clears voter metadata',
      () async {
    container = makeContainer(FakeApiClient({
      ...standardRoutes(),
      'GET /v1/social/events': (_) => {
            'items': [eventJson(feedback: feedbackJson('concerning'))],
          },
      'DELETE /v1/social/events/event-1/feedback': (_) => {'feedback': null},
    }));
    await container.read(socialEventsProvider('child-1').future);
    final controller = container.read(socialVoteProvider('event-1').notifier);

    await controller.withdraw();

    expect(api.calls('DELETE', '/v1/social/events/event-1/feedback'),
        hasLength(1));
    expect(api.calls('POST', '/v1/social/events/event-1/feedback'), isEmpty);
    final vote = container.read(socialVoteProvider('event-1'));
    expect(vote.verdict, isNull);
    expect(vote.parentDisplayName, isNull);
    expect(vote.firstVotedAt, isNull);
    expect(vote.lastChangedAt, isNull);
  });
}
