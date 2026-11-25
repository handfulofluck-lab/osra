import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/core/mutation_auth.dart';

/// Issue #742: the gate is **by default**, so these rows are about what it refuses, not what it allows.
///
/// Claude's ruling (7149939807) rejected the opt-in shape because it fails one forgotten screen at a time.
/// Each row below names the mutant that would turn the gate back into an opt-in one.
void main() {
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
          MutationAuthPolicy.requiresAuth(method: method),
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

    test('the path does not change the answer, deliberately', () {
      // A path allowlist is the "forgotten screen" bug in another costume; the guard must not special-case.
      for (final path in ['/rules', '/v1/family/children/1', '/alerts/9/ack', '/'] ) {
        expect(MutationAuthPolicy.requiresAuth(method: 'PUT', path: path), isTrue);
      }
    });
  });

  group('MutationAuthPolicy — exemptions are explicit and few', () {
    test('each named exemption frees exactly its own call', () {
      for (final exempt in AuthExempt.all) {
        expect(
          MutationAuthPolicy.requiresAuth(method: 'POST', exempt: exempt),
          isFalse,
          reason: '${exempt.reason} must be allowed to run without a prompt',
        );
      }
    });

    test('the exempt set is pinned — a new reason is a visible diff', () {
      // Mutant: appending an exemption without touching this list leaves the row green, which is why the
      // list is asserted by content rather than by length.
      expect(
        AuthExempt.all.map((e) => e.reason).toList(),
        <String>['ack-ack-0052', 'push-token', 'background-refresh', 'token-refresh'],
      );
    });

    test('a rule change is not on the exempt list', () {
      // The point of the feature: nothing that loosens protection may run without the owner present.
      for (final reason in AuthExempt.all.map((e) => e.reason)) {
        expect(reason, isNot(anyOf(contains('rule'), contains('unlink'), contains('pause'))));
      }
    });
  });
}
