import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/app.dart';
import 'package:familyshield_parent/providers/family_provider.dart';

/// Issue #1056, the wiring row. `AlertsBadgeRefresh` is tested on its own in `alerts_badge_refresh_test.dart`;
/// this one makes sure the app actually connects it — the signal reaches the provider, and the count the bell
/// watches is re-read. Mutant: leave `appWideRefreshProvider` refreshing `socialEventsProvider` only, which is
/// exactly the state the issue reports, and this row fails.
void main() {
  testWidgets('a resume re-reads the unacknowledged count the bell watches', (tester) async {
    var reads = 0;
    final container = ProviderContainer(
      overrides: [
        unacknowledgedAlertsProvider.overrideWith((ref) async {
          reads++;
          return const UnacknowledgedAlertsSummary(total: 1, items: []);
        }),
      ],
    );
    // disposed inside the body so the poll timer is gone before the invariant check

    // The bell watches `alertsBadgeCountProvider`; listening keeps the chain alive so invalidation rebuilds it.
    final sub = container.listen(alertsBadgeCountProvider, (_, __) {});
    await tester.pump();
    expect(reads, 1, reason: 'the count is read once when the screen starts watching');

    container.read(appWideRefreshProvider);
    await tester.pump();

    // A real lifecycle change, through the same binding `AppLifecycleListener` listens to.
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

    // Let the bounded second read fire, then dispose inside the test body: the fallback poll is a live timer,
    // and the harness fails a test that leaves one pending after the tree is gone.
    await tester.pump(const Duration(seconds: 5));
    sub.close();
    container.dispose();
  });
}
