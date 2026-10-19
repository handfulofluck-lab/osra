import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `shared_preferences` keys for the first-run wizard. The flag is stored the
/// same way `theme_mode` and `app_locale` are: one key, read once at startup,
/// written best-effort on every transition.
const kOnboardingCompleteKey = 'onboarding_complete';
const kOnboardingStepKey = 'onboarding_step';
const kOnboardingChildIdKey = 'onboarding_child_id';
const kPairingPendingKey = 'pairing_pending';

/// The durable position in the first-run flow.
///
/// [none] means the wizard has never been started (a fresh install, or a
/// signed-in account that predates it). [welcome] and [signIn] are the
/// unauthenticated half; the rest need a session.
enum OnboardingStep { none, welcome, signIn, addChild, pair, done }

OnboardingStep onboardingStepFromName(String? name) => switch (name) {
      'welcome' => OnboardingStep.welcome,
      'sign_in' => OnboardingStep.signIn,
      'add_child' => OnboardingStep.addChild,
      'pair' => OnboardingStep.pair,
      'done' => OnboardingStep.done,
      _ => OnboardingStep.none,
    };

String onboardingStepName(OnboardingStep step) => switch (step) {
      OnboardingStep.welcome => 'welcome',
      OnboardingStep.signIn => 'sign_in',
      OnboardingStep.addChild => 'add_child',
      OnboardingStep.pair => 'pair',
      OnboardingStep.done => 'done',
      OnboardingStep.none => 'none',
    };

@immutable
class OnboardingState {
  /// The parent has seen the flow through (pairing may still be pending; see
  /// [pairingPending]). A completed flow never shows the wizard again.
  final bool complete;

  final OnboardingStep step;

  /// The parent chose to pair later. This stays until dashboard setup or a
  /// successful pairing clears it, and drives the dashboard banner.
  final bool pairingPending;

  /// The child being set up, so a resumed pair step opens the same child.
  final String? childId;

  /// `load()` has answered. The router waits for this before steering.
  final bool loaded;

  const OnboardingState({
    this.complete = false,
    this.step = OnboardingStep.none,
    this.pairingPending = false,
    this.childId,
    this.loaded = false,
  });

  /// A flow that is under way and still needs the wizard.
  bool get inProgress => !complete && step != OnboardingStep.none;

  OnboardingState copyWith({
    bool? complete,
    OnboardingStep? step,
    bool? pairingPending,
    String? childId,
    bool clearChildId = false,
    bool? loaded,
  }) {
    return OnboardingState(
      complete: complete ?? this.complete,
      step: step ?? this.step,
      pairingPending: pairingPending ?? this.pairingPending,
      childId: clearChildId ? null : (childId ?? this.childId),
      loaded: loaded ?? this.loaded,
    );
  }
}

/// Fires on every [OnboardingNotifier] transition so `GoRouter` re-evaluates
/// its redirect. Mirrors [AuthRouterListenable] in `auth_provider.dart`.
class OnboardingRouterListenable extends ChangeNotifier {
  void notify() => notifyListeners();
}

final onboardingRouterListenable = OnboardingRouterListenable();

/// Persisted first-run state; `load()` runs at creation, matching the
/// `themeModeProvider` / `localeProvider` pattern.
final onboardingProvider = StateNotifierProvider<OnboardingNotifier, OnboardingState>((ref) {
  final notifier = OnboardingNotifier();
  notifier.load();
  return notifier;
});

class OnboardingNotifier extends StateNotifier<OnboardingState> {
  OnboardingNotifier() : super(const OnboardingState());

  bool _disposed = false;
  bool _touched = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _set(OnboardingState next) {
    if (_disposed) return;
    state = next;
    onboardingRouterListenable.notify();
  }

  /// Reads the persisted position. A failure (prefs unavailable in a test)
  /// leaves the fresh-install defaults in place. A transition the user made
  /// while the read was in flight wins over the persisted value.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_touched) {
        if (!_disposed) _set(state.copyWith(loaded: true));
        return;
      }
      _set(OnboardingState(
        complete: prefs.getBool(kOnboardingCompleteKey) ?? false,
        step: onboardingStepFromName(prefs.getString(kOnboardingStepKey)),
        pairingPending: prefs.getBool(kPairingPendingKey) ?? false,
        childId: prefs.getString(kOnboardingChildIdKey),
        loaded: true,
      ));
    } catch (_) {
      if (!_disposed) _set(state.copyWith(loaded: true));
    }
  }

  /// Welcome → sign-in. Starting over never erases a completed flag; the flag
  /// only becomes true at [completeSetup].
  Future<void> begin() => _update(step: OnboardingStep.signIn);

  /// Back from the sign-in step to the welcome step.
  Future<void> backToWelcome() => _update(step: OnboardingStep.welcome);

  /// A successful sign-in/registration: the next required step is the child.
  Future<void> signedIn() => _update(step: OnboardingStep.addChild);

  /// The child was created (or an existing one was chosen).
  Future<void> childAdded(String childId) =>
      _update(step: OnboardingStep.pair, childId: childId.isEmpty ? null : childId);

  /// Back from pairing to the child step.
  Future<void> backToChild() => _update(step: OnboardingStep.addChild);

  /// A device for [childId] is paired; the flow can finish honestly.
  Future<void> pairingFinished() =>
      _update(step: OnboardingStep.done, pairingPending: false);

  /// The parent chose to pair later. The flow completes, but the dashboard
  /// keeps a "finish setting up" affordance for [childId].
  Future<void> pairingSkipped({String? childId}) =>
      _update(step: OnboardingStep.done, pairingPending: true, childId: childId);

  /// Back from the done step to pairing.
  Future<void> backToPairing() => _update(step: OnboardingStep.pair);

  /// The wizard is over; normal routing takes over from the next build.
  Future<void> completeSetup() =>
      _update(complete: true, step: OnboardingStep.done);

  /// The dashboard saw a device for the pending child (paired elsewhere).
  Future<void> clearPairingPending() => _update(pairingPending: false);

  /// Session-expired / use-another-account path: keep the progress, return to
  /// the sign-in step. Sign-in cannot be skipped.
  Future<void> backToSignIn() => _update(step: OnboardingStep.signIn);

  Future<void> _update({
    bool? complete,
    OnboardingStep? step,
    bool? pairingPending,
    String? childId,
    bool clearChildId = false,
  }) async {
    _touched = true;
    final next = state.copyWith(
      complete: complete,
      step: step,
      pairingPending: pairingPending,
      childId: childId,
      clearChildId: clearChildId,
      loaded: true,
    );
    _set(next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kOnboardingCompleteKey, next.complete);
      await prefs.setString(kOnboardingStepKey, onboardingStepName(next.step));
      await prefs.setBool(kPairingPendingKey, next.pairingPending);
      if (next.childId == null) {
        await prefs.remove(kOnboardingChildIdKey);
      } else {
        await prefs.setString(kOnboardingChildIdKey, next.childId!);
      }
    } catch (_) {
      // The in-memory position still applies for this session.
    }
  }
}
