import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/app.dart';
import 'package:familyshield_parent/providers/family_provider.dart';

/// Issue #1056, the wiring rows. `AlertsBadgeRefresh` is tested on its own in `alerts_badge_refresh_test.dart`;
/// these make sure the app connects it — the signal reaches the provider, and the count the bell watches is
/// re-read. Mutant: leave `appWideRefreshProvider` refreshing `socialEventsProvider` only, which is exactly the
/// state the issue reports, and both rows fail.
void main() {
  ProviderContainer containerCounting(void Function() onRead) => ProviderContainer(
        overrides: [
          unacknowledgedAlertsProvider.overrideWith((ref) async {
            onRead();
            return const UnacknowledgedAlertsSummary(total: 1, items: []);
          }),
        ],
      );

  Future<void> mount(WidgetTester tester, ProviderContainer container) async {
    final badge = container.read(appWideRefreshProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: BadgePollLifecycle(badge: badge, child: const SizedBox()),
      ),
    );
    await tester.pump();
  }

  testWidgets('a resume re-reads the unacknowledged count the bell watches', (tester) async {
    var reads = 0;
    final container = containerCounting(() => reads++);
    final sub = container.listen(alertsBadgeCountProvider, (_, __) {});
    await mount(tester, container);
    expect(reads, 1, reason: 'the count is read once when the screen starts watching');

    // A real lifecycle change, through the same binding the observer listens to.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    final readsWhilePaused = reads;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(reads, greaterThan(readsWhilePaused),
        reason: 'resume must re-read the count, not only social events');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    sub.close();
    container.dispose();
  });

  testWidgets('a page mounted while the app is already foregrounded starts the poll (cold start)',
      (tester) async {
    // Codex, #1056 review: `AppLifecycleListener` only fires on a transition, so a page created while Flutter
    // is already `resumed` used to start no poll at all — a quiet socket then meant one read forever.
    // Mutant: start the poll only on a resume transition; this row then sees one read at 121 s instead of two.
    var reads = 0;
    final container = containerCounting(() => reads++);
    final sub = container.listen(alertsBadgeCountProvider, (_, __) {});
    await mount(tester, container);
    expect(reads, 1, reason: 'the badge reads once when the screen starts watching');
    expect(reads, 1, reason: 'mounting must not add an immediate read of its own');

    await tester.pump(const Duration(seconds: 121));
    expect(reads, 2, reason: 'the fallback poll must be running for a cold start too');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    sub.close();
    container.dispose();
  });

  testWidgets('leaving the tree stops the poll, so no timer outlives the page', (tester) async {
    var reads = 0;
    final container = containerCounting(() => reads++);
    final sub = container.listen(alertsBadgeCountProvider, (_, __) {});
    await mount(tester, container);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    final readsAfterUnmount = reads;
    await tester.pump(const Duration(minutes: 5));
    expect(reads, readsAfterUnmount, reason: 'mutant: a provider-owned timer keeps polling after the page is gone');

    sub.close();
    container.dispose();
  });
}
