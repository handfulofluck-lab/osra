import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';
import 'pair_qr_payload.dart';

/// Full-screen first-run pairing view: the six-digit code as a scannable QR,
/// the same code in large type for the child app's keyboard, a countdown to the
/// server's `expiresAt`, and a Regenerate action.
///
/// The QR payload is [PairQrPayload]'s documented `osra://` format; the child
/// app scans it, and the typed six-digit code remains the fallback (roadmap
/// item 3.2). In [onboarding] mode the same screen is the wizard's pairing step.
class PairingQrScreen extends ConsumerStatefulWidget {
  const PairingQrScreen({
    super.key,
    required this.childId,
    this.clock,
    this.onboarding = false,
    this.childName,
    this.onBack,
    this.onContinue,
    this.onSkip,
  });

  final String childId;

  /// Test seam: the screen's source of "now". Defaults to [DateTime.now].
  final DateTime Function()? clock;

  /// Wizard mode: an explanation of what to do on the child's phone, one
  /// primary action that verifies the pairing with the server, and an honest
  /// "set up later" exit. The standalone screen keeps its existing copy.
  final bool onboarding;
  final String? childName;
  final VoidCallback? onBack;
  final VoidCallback? onContinue;
  final VoidCallback? onSkip;

  @override
  ConsumerState<PairingQrScreen> createState() => _PairingQrScreenState();
}

class _PairingQrScreenState extends ConsumerState<PairingQrScreen> {
  String? _code;
  String? _payload;
  DateTime? _expiresAt;

  /// `format` when the response had no usable code, `network` otherwise.
  /// Storing the kind (not a translated string) lets the copy follow a locale
  /// change while the screen is open.
  String? _errorKind;
  bool _loading = true;
  Timer? _timer;

  /// Wizard-only: the result of the last "my child has finished" check.
  bool _checking = false;
  bool _notPairedYet = false;
  bool _checkFailed = false;

  DateTime get _now => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _generate();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _generate() async {
    setState(() {
      _loading = true;
      _errorKind = null;
      _notPairedYet = false;
      _checkFailed = false;
    });
    try {
      final res = await ref.read(apiClientProvider).raw.post(
        '/v1/devices/pair',
        data: {'childId': widget.childId},
      );
      final data = Map<String, dynamic>.from(res.data as Map);
      final code = data['code'] as String?;
      final expiresAt = DateTime.tryParse(data['expiresAt'] as String? ?? '') ??
          _now.add(kPairCodeTtl);
      if (code == null || !RegExp(r'^\d{6}$').hasMatch(code)) {
        throw const FormatException('pair response missing a six-digit code');
      }
      // Build the payload here, not in build(): a blank or malformed API base
      // URL must surface as an actionable error, not a render-time exception.
      final payload = PairQrPayload(
        code: code,
        apiBaseUrl: ref.read(apiClientProvider).raw.options.baseUrl,
      ).encode();
      if (!mounted) return;
      setState(() {
        _code = code;
        _payload = payload;
        _expiresAt = expiresAt;
        _loading = false;
      });
      _startCountdown();
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorKind = e.response?.statusCode == 428 ? 'consent' : 'network';
      });
    } on FormatException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorKind = 'format';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorKind = 'network';
      });
    }
  }

  void _startCountdown() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_remaining == Duration.zero) _timer?.cancel();
      setState(() {});
    });
  }

  /// Time left until the server-side expiry, clamped at zero.
  Duration get _remaining {
    final expiresAt = _expiresAt;
    if (expiresAt == null) return Duration.zero;
    final diff = expiresAt.difference(_now);
    return diff.isNegative ? Duration.zero : diff;
  }

  bool get _expired =>
      _code != null && _expiresAt != null && _remaining == Duration.zero;

  Future<void> _copyCode() async {
    final code = _code;
    if (code == null || _expired) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.codeCopied)));
    }
  }

  /// Wizard-only: ask the server whether a device exists for [childId] now.
  /// Advancing only on a confirmed device is what keeps the Done step honest.
  Future<void> _checkPairing() async {
    setState(() {
      _checking = true;
      _notPairedYet = false;
      _checkFailed = false;
    });
    try {
      ref.invalidate(familyProvider);
      final overview = await ref.read(familyProvider.future);
      if (!mounted) return;
      setState(() => _checking = false);
      if (overview.devicesFor(widget.childId).isNotEmpty) {
        widget.onContinue?.call();
      } else {
        setState(() => _notPairedYet = true);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _checkFailed = true;
      });
    }
  }

  bool _paired(FamilyOverview? overview) =>
      overview?.devicesFor(widget.childId).isNotEmpty ?? false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final overview = ref.watch(familyProvider).valueOrNull;
    final paired = widget.onboarding && _paired(overview);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.pairADevice),
        leading: widget.onboarding && widget.onBack != null
            ? BackButton(onPressed: widget.onBack)
            : null,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            if (widget.onboarding) ...[
              Text(
                l10n.onboardingPairIntro(widget.childName ?? l10n.childFallback),
                key: const ValueKey('onboardingPairIntro'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpace.xs),
              Text(
                l10n.onboardingPairSteps,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ] else ...[
              Text(
                l10n.scanQr,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpace.xs),
              Text(
                l10n.typeSixDigit,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
            const SizedBox(height: AppSpace.lg),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(AppSpace.xxl),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_errorKind != null) ...[
              Text(
                switch (_errorKind) {
                  'format' => l10n.pairCodeError,
                  'consent' => l10n.pairConsentError,
                  _ => l10n.pairCreateError,
                },
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: context.tokens.danger),
              ),
              const SizedBox(height: AppSpace.md),
              FilledButton.tonal(
                  onPressed: _generate, child: Text(l10n.tryAgain)),
            ] else
              _buildCode(context),
            if (widget.onboarding && !_loading) ...[
              const SizedBox(height: AppSpace.lg),
              if (_notPairedYet)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.sm),
                  child: Text(
                    l10n.onboardingPairWaiting,
                    key: const ValueKey('onboardingPairWaiting'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: context.tokens.warn),
                  ),
                ),
              if (_checkFailed)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.sm),
                  child: Text(
                    l10n.onboardingPairCheckFailed,
                    key: const ValueKey('onboardingPairCheckFailed'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: context.tokens.danger),
                  ),
                ),
              FilledButton(
                key: const ValueKey('onboardingPairDone'),
                onPressed: (_checking || _expired || _errorKind != null) ? null : _checkPairing,
                child: _checking
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(paired ? l10n.continueLabel : l10n.onboardingPairConfirm),
              ),
              TextButton(
                key: const ValueKey('onboardingPairSkip'),
                onPressed: _checking ? null : widget.onSkip,
                child: Text(l10n.onboardingPairLater),
              ),
              Text(
                l10n.onboardingPairLaterNote,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCode(BuildContext context) {
    final l10n = context.l10n;
    final code = _code!;
    final payload = _payload!;
    final remaining = _remaining;
    final mm = remaining.inMinutes.toString().padLeft(2, '0');
    final ss = (remaining.inSeconds % 60).toString().padLeft(2, '0');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_expired)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.xl),
              child: Column(
                children: [
                  Icon(Icons.timer_off, size: 48, color: context.tokens.danger),
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    l10n.codeExpired,
                    key: const ValueKey('pairingExpired'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: AppSpace.xs),
                  Text(l10n.generateNewCode),
                ],
              ),
            ),
          )
        else ...[
          Center(
            child: Card(
              // A QR on a dark surface does not scan: keep the symbol itself
              // black on white in both themes.
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: PairingQr(
                  key: const ValueKey('pairingQr'),
                  data: payload,
                  semanticsLabel: l10n.pairingQrSemantics(code),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpace.lg),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Semantics(
              label: l10n.pairingCodeSemantics(code),
              excludeSemantics: true,
              child: Text(
                code,
                key: const ValueKey('pairingCode'),
                style:
                    AppType.pairingCode.copyWith(color: context.tokens.onSurface),
              ),
            ),
          ),
        ],
        const SizedBox(height: AppSpace.md),
        Text(
          l10n.expiresIn('$mm:$ss'),
          key: const ValueKey('pairingCountdown'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: AppSpace.lg),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: AppSpace.sm,
          runSpacing: AppSpace.sm,
          children: [
            FilledButton.tonalIcon(
              key: const ValueKey('pairingRegenerate'),
              onPressed: _loading ? null : _generate,
              icon: const Icon(Icons.refresh),
              label: Text(l10n.regenerate),
            ),
            OutlinedButton.icon(
              key: const ValueKey('pairingCopy'),
              onPressed: _expired ? null : _copyCode,
              icon: const Icon(Icons.copy),
              label: Text(l10n.copyCode),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.md),
        Text(
          l10n.codeWorksOnce(kPairCodeTtl.inMinutes),
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// The QR symbol itself, split out so tests can read the encoded [data] (the
/// package's [QrImageView] keeps its own copy private).
class PairingQr extends StatelessWidget {
  const PairingQr({super.key, required this.data, this.semanticsLabel});

  final String data;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticsLabel,
      child: QrImageView(
        data: data,
        version: QrVersions.auto,
        size: 220,
        backgroundColor: Colors.white,
        eyeStyle:
            const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: Colors.black,
        ),
      ),
    );
  }
}
