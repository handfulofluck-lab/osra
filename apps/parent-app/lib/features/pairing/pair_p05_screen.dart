import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../api/permission_errors.dart';
import '../../core/digits.dart';
import '../../core/ltr_isolate.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';
import 'pair_qr_payload.dart';
import 'pair_qr_screen.dart' show pairClaimDeviceLabel;

/// Feature switch for UX Final Decisions P-05 Pair (#1179, ★0).
///
/// Enable via `--dart-define=OSRA_UX_P05=true` or override
/// [p05PairEnabledProvider] in tests. When `false`, `PairingQrScreen`
/// falls back to the legacy pairing screen.
const bool kEnableUxP05Pair = bool.fromEnvironment(
  'OSRA_UX_P05',
  defaultValue: false,
);

final p05PairEnabledProvider = Provider<bool>((ref) => kEnableUxP05Pair);

/// Public download link shared by "Send install link" (never exposes internal
/// server addresses or device IDs).
const String kInstallShareUrl = 'https://osratech.com/install';

/// UX Final Decisions **P-05 Pair device** (#1179, ★0, A10):
/// - QR + typed 6-digit code on one screen from the same pairing session.
/// - Live waiting line + expiry timer + "New code".
/// - Confirm the claiming device's name (`pairClaimDeviceLabel`) before linking
///   (A10), including the `dataCleared` warning when present.
/// - `approved` acknowledges approval and keeps polling until `paired`; only
///   `paired` shows the connected card / Continue.
/// - `denied` hides the burned QR and offers a fresh code.
/// - "Send install link" and "Skip for now" (when `onSkip != null`).
/// - **No OS chooser, no copy-code button, never shows device IDs or server URLs.**
class PairP05Screen extends ConsumerStatefulWidget {
  final String childId;
  final DateTime Function()? clock;
  final String? childName;
  final VoidCallback? onBack;
  final VoidCallback? onContinue;
  final VoidCallback? onSkip;

  const PairP05Screen({
    super.key,
    required this.childId,
    this.clock,
    this.childName,
    this.onBack,
    this.onContinue,
    this.onSkip,
  });

  @override
  ConsumerState<PairP05Screen> createState() => _PairP05ScreenState();
}

class _PairP05ScreenState extends ConsumerState<PairP05Screen> {
  String? _code;
  String? _payload;
  DateTime? _expiresAt;
  String? _errorKind;
  bool _loading = true;
  Timer? _timer;
  Timer? _claimTimer;
  Map<String, dynamic>? _claim;
  bool _deciding = false;
  Object? _decisionError;
  Object? _pollError;

  DateTime get _now => (widget.clock ?? DateTime.now)();

  Duration get _remaining {
    final exp = _expiresAt;
    if (exp == null) return Duration.zero;
    final diff = exp.difference(_now);
    return diff.isNegative ? Duration.zero : diff;
  }

  bool get _expired =>
      _code != null && _expiresAt != null && _remaining == Duration.zero;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _claimTimer?.cancel();
    super.dispose();
  }

  Future<void> _generate() async {
    _timer?.cancel();
    _claimTimer?.cancel();
    setState(() {
      _loading = true;
      _errorKind = null;
      _claim = null;
      _decisionError = null;
      _pollError = null;
    });
    try {
      final res = await ref.read(apiClientProvider).raw.post(
        '/v1/devices/pair',
        data: {'childId': widget.childId},
      );
      final data = Map<String, dynamic>.from(res.data as Map);
      final rawCode = data['code'];
      final code = rawCode is String ? normalizeDigits(rawCode) : null;
      final expiresAt = DateTime.tryParse(data['expiresAt'] as String? ?? '') ??
          _now.add(kPairCodeTtl);
      if (code == null || !RegExp(r'^\d{6}$').hasMatch(code)) {
        throw const FormatException('pair response missing six-digit code');
      }
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
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if (_remaining == Duration.zero) _timer?.cancel();
        setState(() {});
      });
      _claimTimer =
          Timer.periodic(const Duration(seconds: 2), (_) => _readClaim());
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

  Future<void> _readClaim() async {
    final code = _code;
    final status = _claim?['status'];
    if (code == null || _expired || _deciding) return;
    if (status == 'paired' || status == 'denied') {
      _claimTimer?.cancel();
      return;
    }
    try {
      final res = await ref
          .read(apiClientProvider)
          .raw
          .get('/v1/devices/pair/$code/claim');
      if (!mounted || code != _code || _deciding) return;
      final data = Map<String, dynamic>.from(res.data as Map);
      setState(() {
        _claim = data;
        _pollError = null;
      });
      if (data['status'] == 'paired') {
        _claimTimer?.cancel();
        ref.invalidate(familyProvider);
      } else if (data['status'] == 'denied') {
        _claimTimer?.cancel();
      }
    } catch (e) {
      if (!mounted || code != _code) return;
      setState(() => _pollError = e);
    }
  }

  Future<void> _decide({required bool allow}) async {
    final claimId = _claim?['claimId'] as String?;
    if (claimId == null) return;
    setState(() {
      _deciding = true;
      _decisionError = null;
    });
    try {
      await ref.read(apiClientProvider).raw.post(
        '/v1/devices/pair/claims/$claimId/${allow ? 'approve' : 'deny'}',
      );
      if (!mounted) return;
      setState(() {
        _deciding = false;
        _claim = {...?_claim, 'status': allow ? 'approved' : 'denied'};
      });
      if (allow) {
        ref.invalidate(familyProvider);
      } else {
        _claimTimer?.cancel();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _deciding = false;
        _decisionError = e;
      });
    }
  }

  String _decisionErrorMessage(AppLocalizations l10n, Object error) {
    if (error is DioException) {
      final code = error.response?.statusCode;
      if (code == 409 || code == 410 || code == 404) {
        return l10n.pairClaimError;
      }
      return friendlyErrorText(l10n, error, () => l10n.pairClaimError);
    }
    return l10n.pairClaimError;
  }

  Future<void> _sendInstallLink() async {
    await Clipboard.setData(const ClipboardData(text: kInstallShareUrl));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.pairP05InstallLinkCopied)),
      );
    }
  }

  String _formatCode(String code) =>
      ltrIsolate('${code.substring(0, 3)} · ${code.substring(3)}');

  String _formatCountdown(Duration d) {
    final mins = d.inMinutes.toString().padLeft(2, '0');
    final secs = (d.inSeconds % 60).toString().padLeft(2, '0');
    return ltrIsolate('$mins:$secs');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tokens = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    final overview = ref.watch(familyProvider).valueOrNull;
    final childName = widget.childName ??
        overview?.children.where((c) => c.id == widget.childId).firstOrNull?.displayName;
    final safeChild = childName != null && childName.trim().isNotEmpty
        ? firstStrongIsolate(childName.trim())
        : null;

    final claimStatus = _claim?['status']?.toString();
    final rawLabel = _claim != null ? pairClaimDeviceLabel(_claim!) : '';
    final claimDeviceLabel = rawLabel.isNotEmpty
        ? rawLabel
        : (_claim?['deviceModel']?.toString() ?? '');
    final isDenied = claimStatus == 'denied';

    return Scaffold(
      appBar: AppBar(
        leading: widget.onBack != null ? BackButton(onPressed: widget.onBack) : null,
        title: Text(
          safeChild != null ? l10n.pairP05Title(safeChild) : l10n.pairP05TitleGeneric,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          key: const ValueKey('p05ScrollView'),
          padding: const EdgeInsetsDirectional.fromSTEB(
            AppSpace.lg,
            AppSpace.md,
            AppSpace.lg,
            AppSpace.xl,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                safeChild != null
                    ? l10n.pairP05Subtitle(safeChild)
                    : l10n.pairP05SubtitleGeneric,
                style: textTheme.bodyLarge?.copyWith(color: tokens.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpace.lg),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(AppSpace.xxl),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_errorKind != null)
                Card(
                  color: tokens.surfaceContainer,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    side: BorderSide(color: tokens.border),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpace.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _errorKind == 'consent'
                              ? l10n.pairConsentError
                              : l10n.errorNoConnection,
                          style: textTheme.bodyMedium?.copyWith(color: tokens.danger),
                        ),
                        const SizedBox(height: AppSpace.md),
                        FilledButton(
                          key: const ValueKey('p05RetryButton'),
                          onPressed: _generate,
                          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                          child: Text(l10n.pairP05NewCode),
                        ),
                      ],
                    ),
                  ),
                )
              else if (isDenied)
                // B3: Deny burns the pairing code on the server — hide the dead QR/waiting line
                // and show the approved Declined + New code card.
                Card(
                  key: const ValueKey('p05DeniedCard'),
                  color: tokens.surfaceContainer,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    side: BorderSide(color: tokens.border),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpace.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          l10n.pairClaimDenied,
                          key: const ValueKey('pairClaimDenied'),
                          style: textTheme.bodyLarge?.copyWith(color: tokens.onSurface),
                        ),
                        const SizedBox(height: AppSpace.md),
                        FilledButton.tonalIcon(
                          key: const ValueKey('p05DeniedNewCodeButton'),
                          onPressed: _generate,
                          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                          icon: const Icon(Icons.refresh, size: 18),
                          label: Text(l10n.pairP05NewCode),
                        ),
                      ],
                    ),
                  ),
                )
              else ...[
                // QR + typed code card
                Card(
                  key: const ValueKey('p05QrCodeCard'),
                  color: tokens.surfaceContainer,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    side: BorderSide(color: tokens.border),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpace.lg),
                    child: Column(
                      children: [
                        if (_payload != null && !_expired)
                          Container(
                            padding: const EdgeInsets.all(AppSpace.md),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(AppRadius.md),
                            ),
                            child: QrImageView(
                              key: const ValueKey('p05QrImage'),
                              data: _payload!,
                              version: QrVersions.auto,
                              size: 180,
                              backgroundColor: Colors.white,
                            ),
                          ),
                        const SizedBox(height: AppSpace.md),
                        Text(
                          l10n.pairP05OrTypeCode,
                          style: textTheme.bodyMedium?.copyWith(
                            color: tokens.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: AppSpace.xs),
                        if (_code != null)
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              _formatCode(_code!),
                              key: const ValueKey('p05CodeText'),
                              textAlign: TextAlign.center,
                              style: textTheme.headlineMedium?.copyWith(
                                color: _expired ? tokens.onSurfaceVariant : tokens.onSurface,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 3,
                              ),
                            ),
                          ),
                        const SizedBox(height: AppSpace.md),
                        Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: AppSpace.sm,
                          runSpacing: AppSpace.xs,
                          children: [
                            Container(
                              key: const ValueKey('p05ExpiryPill'),
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpace.md,
                                vertical: AppSpace.xs,
                              ),
                              decoration: BoxDecoration(
                                color: _expired
                                    ? tokens.danger.withValues(alpha: 0.14)
                                    : tokens.primaryContainer,
                                borderRadius: BorderRadius.circular(AppRadius.sm),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.schedule,
                                    size: 16,
                                    color: _expired ? tokens.danger : tokens.onPrimaryContainer,
                                  ),
                                  const SizedBox(width: AppSpace.xs),
                                  Flexible(
                                    child: Text(
                                      _expired
                                          ? l10n.pairP05CodeExpired
                                          : l10n.pairP05ValidFor(_formatCountdown(_remaining)),
                                      style: textTheme.labelMedium?.copyWith(
                                        color: _expired ? tokens.danger : tokens.onPrimaryContainer,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            TextButton.icon(
                              key: const ValueKey('p05NewCodeButton'),
                              onPressed: _generate,
                              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                              icon: const Icon(Icons.refresh, size: 18),
                              label: Text(l10n.pairP05NewCode),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: AppSpace.md),
                // A10 + B2 + B4: Confirm device name (preferring deviceName) + dataCleared warning
                if (claimStatus == 'pending' && claimDeviceLabel.isNotEmpty)
                  Card(
                    key: const ValueKey('p05ConfirmDeviceCard'),
                    color: tokens.primaryContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      side: BorderSide(color: tokens.primary),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpace.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            l10n.pairP05ConfirmDeviceTitle,
                            style: textTheme.titleMedium?.copyWith(
                              color: tokens.onPrimaryContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: AppSpace.xs),
                          Text(
                            l10n.pairP05ConfirmDeviceBody(firstStrongIsolate(claimDeviceLabel)),
                            style: textTheme.bodyMedium?.copyWith(
                              color: tokens.onPrimaryContainer,
                            ),
                          ),
                          if (_claim?['dataCleared'] == true) ...[
                            const SizedBox(height: AppSpace.xs),
                            Text(
                              l10n.pairClaimDataCleared,
                              key: const ValueKey('pairClaimDataCleared'),
                              style: textTheme.bodySmall?.copyWith(color: tokens.danger),
                            ),
                          ],
                          if (_decisionError != null) ...[
                            const SizedBox(height: AppSpace.xs),
                            Text(
                              _decisionErrorMessage(l10n, _decisionError!),
                              key: const ValueKey('p05DecisionError'),
                              style: textTheme.bodySmall?.copyWith(color: tokens.danger),
                            ),
                          ],
                          const SizedBox(height: AppSpace.md),
                          Wrap(
                            spacing: AppSpace.sm,
                            runSpacing: AppSpace.sm,
                            children: [
                              FilledButton(
                                key: const ValueKey('p05ConfirmLinkButton'),
                                onPressed: _deciding ? null : () => _decide(allow: true),
                                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                                child: Text(l10n.pairP05ConfirmLink),
                              ),
                              OutlinedButton(
                                key: const ValueKey('p05DeclineButton'),
                                onPressed: _deciding ? null : () => _decide(allow: false),
                                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                                child: Text(l10n.pairP05Decline),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  )
                else if (claimStatus == 'approved')
                  // B1: Approved means waiting for the phone to fetch its token; not connected yet.
                  Card(
                    key: const ValueKey('p05ApprovedCard'),
                    color: tokens.surfaceContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      side: BorderSide(color: tokens.primary),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpace.lg),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: tokens.primary,
                            ),
                          ),
                          const SizedBox(width: AppSpace.sm),
                          Expanded(
                            child: Text(
                              l10n.pairClaimAllowed,
                              key: const ValueKey('pairClaimAllowed'),
                              style: textTheme.bodyMedium?.copyWith(color: tokens.onSurface),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (claimStatus == 'paired')
                  // B1: Only `paired` shows Phone connected / Continue.
                  Card(
                    key: const ValueKey('p05ConnectedCard'),
                    color: tokens.surfaceContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      side: BorderSide(color: tokens.ok),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpace.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.check_circle, color: tokens.ok),
                              const SizedBox(width: AppSpace.sm),
                              Expanded(
                                child: Text(
                                  l10n.pairP05Connected,
                                  style: textTheme.titleMedium?.copyWith(color: tokens.ok),
                                ),
                              ),
                            ],
                          ),
                          if (widget.onContinue != null) ...[
                            const SizedBox(height: AppSpace.md),
                            FilledButton(
                              key: const ValueKey('p05ContinueButton'),
                              onPressed: widget.onContinue,
                              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                              child: Text(l10n.setupMonitoringContinue),
                            ),
                          ],
                        ],
                      ),
                    ),
                  )
                else if (_pollError != null)
                  // B5: Honest offline/retry state for claim polling errors (QR stays visible).
                  Card(
                    key: const ValueKey('p05PollErrorCard'),
                    color: tokens.surfaceContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      side: BorderSide(color: tokens.danger),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpace.md),
                      child: Row(
                        children: [
                          Icon(Icons.cloud_off_outlined, color: tokens.danger, size: 20),
                          const SizedBox(width: AppSpace.sm),
                          Expanded(
                            child: Text(
                              friendlyErrorText(l10n, _pollError!, () => l10n.errorNoConnection),
                              style: textTheme.bodySmall?.copyWith(color: tokens.danger),
                            ),
                          ),
                          TextButton(
                            key: const ValueKey('p05PollRetryButton'),
                            onPressed: _readClaim,
                            child: Text(l10n.retry),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  // Live waiting line
                  Padding(
                    key: const ValueKey('p05WaitingLine'),
                    padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: tokens.primary,
                          ),
                        ),
                        const SizedBox(width: AppSpace.sm),
                        Flexible(
                          child: Text(
                            safeChild != null
                                ? l10n.pairP05WaitingFor(safeChild)
                                : l10n.pairP05WaitingGeneric,
                            style: textTheme.bodyMedium?.copyWith(
                              color: tokens.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: AppSpace.lg),
              OutlinedButton.icon(
                key: const ValueKey('p05SendInstallLinkButton'),
                onPressed: _sendInstallLink,
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.share_outlined, size: 18),
                label: Text(l10n.pairP05SendInstallLink),
              ),
              if (widget.onSkip != null) ...[
                const SizedBox(height: AppSpace.sm),
                TextButton(
                  key: const ValueKey('p05SkipButton'),
                  onPressed: widget.onSkip,
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  child: Text(l10n.pairP05SkipForNow),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
