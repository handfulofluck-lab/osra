import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/core/mutation_auth.dart';

/// Issue #742: the gate is **by default**, so these rows are about what it refuses, not what it allows.
///
/// Claude's ruling (7149939807) rejected the opt-in shape because it fails one forgotten screen at a time.
/// Ahmed's R3 review of #1114 (2026-11-25) added the second half: an exemption must name the exact call it
/// covers, or the marker itself becomes the forgotten screen. Each row below names the mutant that would
/// turn the gate back into an opt-in one.
void main() {
  // A pattern with its `:name` segments filled in, as a real caller would send it.
  String concrete(String pattern) =>
      pattern.split('/').map((s) => s.startsWith(':') ? '7f3a' : s).join('/');

  group('MutationAuthPolicy — reads never prompt', () {
    test('every safe method is free, including the ones a future caller might mark', () {
      for (final method in MutationAuthPolicy.safeMethods) {
        expect(
          MutationAuthPolicy.requiresAuth(method: method),
          isFalse,
          reason: '$method cannot change anything and must not prompt',
        );
      }
    });

    test('a safe method stays free even when someone passes an exempt marker', () {
      // Mutant: gating on the marker's absence would make a GET with a stray marker prompt the parent.
      expect(
        MutationAuthPolicy.requiresAuth(method: 'GET', exempt: AuthExempt.pushToken),
        isFalse,
      );
    });
  });

  group('MutationAuthPolicy — every mutation needs the owner', () {
    test('the four mutating verbs are gated and there is no fifth way in', () {
      for (final method in ['POST', 'PUT', 'PATCH', 'DELETE']) {
        expect(
          MutationAuthPolicy.requiresAuth(method: method, path: '/v1/rules'),
          isTrue,
          reason: '$method changes state and must be gated',
        );
      }
    });

    test('method matching is case-insensitive, so a lowercase caller cannot slip through', () {
      // Mutant: a case-sensitive set membership check lets `post` through un-gated.
      expect(MutationAuthPolicy.requiresAuth(method: 'post'), isTrue);
      expect(MutationAuthPolicy.requiresAuth(method: 'get'), isFalse);
    });

    test('an odd or future method fails closed', () {
      // Mutant: an allowlist of known mutating verbs would treat a new verb as safe.
      expect(MutationAuthPolicy.requiresAuth(method: 'PROPFIND'), isTrue);
      expect(MutationAuthPolicy.requiresAuth(method: ''), isTrue);
    });

    test('no path is free on its own, deliberately', () {
      // A path allowlist is the "forgotten screen" bug in another costume; the guard must not special-case.
      for (final path in ['/rules', '/v1/family/children/1', '/alerts/9/ack', '/']) {
        expect(MutationAuthPolicy.requiresAuth(method: 'PUT', path: path), isTrue);
      }
    });
  });

  group('MutationAuthPolicy — an exemption frees only the call it names', () {
    test('each named exemption frees exactly its own endpoints', () {
      for (final exempt in AuthExempt.all) {
        for (final endpoint in exempt.endpoints) {
          expect(
            MutationAuthPolicy.requiresAuth(
              method: endpoint.method,
              path: concrete(endpoint.pathPattern),
              exempt: exempt,
            ),
            isFalse,
            reason: '${exempt.reason} names ${endpoint.method} ${endpoint.pathPattern}',
          );
        }
      }
    });

    test('a marker on a rule change, an unlink or a pause is still gated', () {
      // The mutant Ahmed found: an unbound marker let any caller attach it to any mutation and skip the
      // prompt. These are the calls the whole feature exists for, so they must never inherit a pass.
      final mutations = <String>[
        'POST /v1/controls/children/1/pause',
        'POST /v1/controls/children/1/resume',
        'PUT /v1/rules',
        'DELETE /v1/family/children/1',
      ];
      for (final exempt in AuthExempt.all) {
        for (final mutation in mutations) {
          final parts = mutation.split(' ');
          expect(
            MutationAuthPolicy.requiresAuth(method: parts[0], path: parts[1], exempt: exempt),
            isTrue,
            reason: '${exempt.reason} must not free $mutation',
          );
        }
      }
    });

    test('a marker with no path stays gated', () {
      // Mutant: `if (exempt != null) return false;` — the shape Ahmed rejected, because the marker alone
      // says nothing about what it is attached to.
      for (final exempt in AuthExempt.all) {
        expect(MutationAuthPolicy.requiresAuth(method: 'POST', exempt: exempt), isTrue);
      }
    });

    test('a different verb on the same path stays gated', () {
      // Mutant: matching on path alone would let a DELETE ride a marker that only names a POST.
      expect(
        MutationAuthPolicy.requiresAuth(
          method: 'DELETE',
          path: '/v1/alerts/9/ack',
          exempt: AuthExempt.acknowledgeFromNotification,
        ),
        isTrue,
      );
      expect(
        MutationAuthPolicy.requiresAuth(
          method: 'PUT',
          path: '/v1/me/push-token',
          exempt: AuthExempt.pushToken,
        ),
        isTrue,
      );
    });

    test('one endpoint\'s marker does not free another endpoint', () {
      // Mutant: matching the marker against any known endpoint rather than the request's own.
      expect(
        MutationAuthPolicy.requiresAuth(
          method: 'POST',
          path: '/v1/auth/token/refresh',
          exempt: AuthExempt.pushToken,
        ),
        isTrue,
      );
      expect(
        MutationAuthPolicy.requiresAuth(
          method: 'POST',
          path: '/v1/me/push-token',
          exempt: AuthExempt.tokenRefresh,
        ),
        isTrue,
      );
    });

    test('the whole path must match: extra, missing or renamed segments stay gated', () {
      // Mutant: `path.startsWith(pattern)` or `contains`, which would free a neighbour of the named call.
      for (final path in <String>[
        '/v1/me/push-token/extra',
        '/v1/me/push-tokenX',
        '/v2/me/push-token',
        '/prefix/v1/me/push-token',
        '/v1/alerts/9/7/ack',
        '/v1/alerts/ack',
        '/v1/alerts/9/unack',
      ]) {
        expect(
          MutationAuthPolicy.requiresAuth(method: 'POST', path: path, exempt: AuthExempt.pushToken),
          isTrue,
          reason: '$path is not a call any exemption names',
        );
        expect(
          MutationAuthPolicy.requiresAuth(
            method: 'POST',
            path: path,
            exempt: AuthExempt.acknowledgeFromNotification,
          ),
          isTrue,
          reason: '$path is not a call any exemption names',
        );
      }
    });

    test('a query string does not defeat the match, and a trailing slash is the same call', () {
      // The app's own client sends query parameters on some calls; selecting within a call is not naming a
      // different one. Both forms must resolve to the same exemption, or a working feature would suddenly
      // prompt — which is how a guard gets switched off by its own users.
      expect(
        MutationAuthPolicy.requiresAuth(
          method: 'POST',
          path: '/v1/me/push-token?platform=android',
          exempt: AuthExempt.pushToken,
        ),
        isFalse,
      );
      expect(
        MutationAuthPolicy.requiresAuth(
          method: 'POST',
          path: '/v1/me/push-token/',
          exempt: AuthExempt.pushToken,
        ),
        isFalse,
      );
    });

    test('a path whose literal case differs is gated, the fail-closed side', () {
      // Express routing is case-insensitive by default, so `/V1/me/push-token` would reach the route; the
      // pattern does not match it and the call is gated. Wrong case can only come from our own code being
      // wrong, and gating is the side we can recover from.
      expect(
        MutationAuthPolicy.requiresAuth(
          method: 'POST',
          path: '/V1/me/push-token',
          exempt: AuthExempt.pushToken,
        ),
        isTrue,
      );
    });
  });

  group('AuthExempt — the list is pinned by content', () {
    test('the exempt set is pinned — a new reason is a visible diff', () {
      // Mutant: appending an exemption without touching this list leaves the row green, which is why the
      // list is asserted by content rather than by length.
      expect(
        AuthExempt.all.map((e) => e.reason).toList(),
        <String>['ack-from-notification', 'push-token', 'token-refresh'],
      );
    });

    test('every exempt endpoint is pinned — widening one is a visible diff', () {
      // Mutant: adding a path to an existing exemption (the easy way to silence a prompt) would otherwise
      // pass review as a one-word diff inside a list nobody reads.
      expect(
        AuthExempt.all
            .expand((e) => e.endpoints.map((endpoint) => '${e.reason} ${endpoint.method} ${endpoint.pathPattern}'))
            .toList(),
        <String>[
          'ack-from-notification POST /v1/alerts/:id/ack',
          'push-token POST /v1/me/push-token',
          'push-token DELETE /v1/me/push-token',
          'token-refresh POST /v1/auth/token/refresh',
        ],
      );
    });

    test('every exemption names at least one mutating endpoint', () {
      // Mutant: an exemption with no endpoints (or a GET) is a pass that frees nothing and hides that a
      // later edit forgot the half that matters.
      for (final exempt in AuthExempt.all) {
        expect(exempt.endpoints, isNotEmpty, reason: '${exempt.reason} must name its calls');
        for (final endpoint in exempt.endpoints) {
          expect(
            MutationAuthPolicy.safeMethods.contains(endpoint.method),
            isFalse,
            reason: '${exempt.reason} names ${endpoint.method}, which never needed an exemption',
          );
        }
      }
    });

    test('a rule change is not on the exempt list', () {
      // The point of the feature: nothing that loosens protection may run without the owner present.
      for (final exempt in AuthExempt.all) {
        for (final needle in ['rule', 'unlink', 'pause', 'controls', 'consent']) {
          expect(exempt.reason, isNot(contains(needle)));
          for (final endpoint in exempt.endpoints) {
            expect(endpoint.pathPattern, isNot(contains(needle)));
          }
        }
      }
    });
  });
}
