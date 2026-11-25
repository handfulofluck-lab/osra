import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models.dart';
import '../../core/digits.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../theme/app_tokens.dart';
import 'command_messages.dart';

/// #1108: "Change device PIN". A parent who forgot the OSRA PIN on a child's phone sets a new one here.
///
/// There is no "show PIN" anywhere (Ahmed's R3 ruling, condition 7): the old PIN is never read back, from the
/// phone or the server. The new PIN goes to `POST /v1/devices/:id/parent-pin` with the parent's password (and
/// authenticator code when MFA is on); the API derives the hash and the phone stores it.
///
/// Android only for now: the iPhone agent has no PIN pad to change, and the server refuses other platforms.
bool canChangeDevicePin(Device device) => device.platform == 'android';

/// The phone's own PIN rules (`ParentPin.validationError`, `docs/test-vectors/parent-pin.tsv`), checked here
/// so the parent hears about a weak PIN before typing a password. The server checks again.
enum DevicePinProblem { tooShort, tooLong, notDigits, weak }

const _weakPins = {'1234', '0000', '1111', '1212', '12345', '123456', '111111', '654321'};

DevicePinProblem? devicePinProblem(String pin) {
  final normalized = normalizeDigits(pin);
  if (normalized.length < 4) return DevicePinProblem.tooShort;
  if (normalized.length > 8) return DevicePinProblem.tooLong;
  if (!RegExp(r'^[0-9]+$').hasMatch(normalized)) return DevicePinProblem.notDigits;
  if (normalized.split('').toSet().length == 1 || _weakPins.contains(normalized)) return DevicePinProblem.weak;
  return null;
}

String devicePinProblemText(AppLocalizations l10n, DevicePinProblem problem) => switch (problem) {
      DevicePinProblem.tooShort => l10n.changeDevicePinTooShort,
      DevicePinProblem.tooLong => l10n.changeDevicePinTooLong,
      DevicePinProblem.notDigits => l10n.changeDevicePinNotDigits,
      DevicePinProblem.weak => l10n.changeDevicePinWeak,
    };

@immutable
class DevicePinChange {
  final String pin;
  final String password;
  final String code;
  const DevicePinChange({required this.pin, required this.password, this.code = ''});

  Map<String, Object> toJson() => {
        'pin': normalizeDigits(pin),
        'password': password,
        if (code.trim().isNotEmpty) 'mfaCode': normalizeDigits(code.trim()),
      };
}

/// The full-width button under a device's action grid.
class ChangeDevicePinButton extends ConsumerWidget {
  final Device device;
  const ChangeDevicePinButton({super.key, required this.device});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TextButton.icon(
      key: ValueKey('deviceAction-changePin-${device.id}'),
      style: TextButton.styleFrom(minimumSize: const Size(0, 48), alignment: AlignmentDirectional.centerStart),
      onPressed: () => changeDevicePin(context, ref, device),
      icon: const Icon(Icons.pin_outlined, size: 18),
      label: Text(context.l10n.changeDevicePinButton, softWrap: true),
    );
  }
}

/// Asks for the new PIN and the parent's proof, sends it, and says what happened.
Future<void> changeDevicePin(BuildContext context, WidgetRef ref, Device device) async {
  final l10n = context.l10n;
  final change = await showDialog<DevicePinChange>(
    context: context,
    builder: (_) => ChangeDevicePinDialog(deviceName: device.model),
  );
  if (change == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref.read(apiClientProvider).raw.post('/v1/devices/${device.id}/parent-pin', data: change.toJson());
    ref.invalidate(deviceCommandHistoryProvider(device.id));
    messenger.showSnackBar(SnackBar(content: Text(l10n.changeDevicePinQueued(device.model))));
  } on DioException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(changeDevicePinErrorText(l10n, device.model, e))));
  }
}

/// The refusals only this route sends, in the parent's words. Everything else (a missing permission, the
/// 1-minute auth rate limit, consent withdrawn, no network) reads exactly as it does for any other command,
/// through [commandErrorText] (Antigravity's F2 on #1126).
String changeDevicePinErrorText(AppLocalizations l10n, String deviceModel, DioException error) {
  final status = error.response?.statusCode;
  final body = error.response?.data;
  final code = body is Map ? body['error'] : null;
  if (status == 401 && (code == 'reauth_failed' || code == 'reauth_required' || code == 'mfa_reenroll_required')) {
    return l10n.changeDevicePinWrongProof;
  }
  final own = switch (code) {
    'pin_change_limit' => l10n.changeDevicePinLimit,
    'command_not_supported' => l10n.changeDevicePinNotSupported,
    'pin_too_short' => l10n.changeDevicePinTooShort,
    'pin_too_long' => l10n.changeDevicePinTooLong,
    'pin_not_digits' => l10n.changeDevicePinNotDigits,
    'pin_weak' => l10n.changeDevicePinWeak,
    _ => null,
  };
  return own ?? commandErrorText(l10n, 'set_parent_pin', deviceModel, error);
}

class ChangeDevicePinDialog extends StatefulWidget {
  final String deviceName;
  const ChangeDevicePinDialog({super.key, required this.deviceName});

  @override
  State<ChangeDevicePinDialog> createState() => _ChangeDevicePinDialogState();
}

class _ChangeDevicePinDialogState extends State<ChangeDevicePinDialog> {
  final _pin = TextEditingController();
  final _repeat = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  String? _error;

  @override
  void dispose() {
    // Clear before disposing so the typed PIN and password do not outlive the dialog in memory longer than needed.
    for (final c in [_pin, _repeat, _password, _code]) {
      c.clear();
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final l10n = context.l10n;
    final problem = devicePinProblem(_pin.text);
    String? error;
    if (problem != null) {
      error = devicePinProblemText(l10n, problem);
    } else if (normalizeDigits(_pin.text) != normalizeDigits(_repeat.text)) {
      error = l10n.changeDevicePinMismatch;
    } else if (_password.text.isEmpty) {
      error = l10n.changeDevicePinPasswordRequired;
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(DevicePinChange(pin: _pin.text, password: _password.text, code: _code.text));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    InputDecoration field(String label, {String? helper}) =>
        InputDecoration(labelText: label, helperText: helper, border: const OutlineInputBorder());
    return AlertDialog(
      scrollable: true,
      title: Text(l10n.changeDevicePinTitle(widget.deviceName)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.changeDevicePinBody),
          const SizedBox(height: AppSpace.md),
          TextField(
            key: const ValueKey('changePinNew'),
            controller: _pin,
            obscureText: true,
            keyboardType: TextInputType.number,
            decoration: field(l10n.changeDevicePinNew, helper: l10n.changeDevicePinDigitsHint),
          ),
          const SizedBox(height: AppSpace.sm),
          TextField(
            key: const ValueKey('changePinRepeat'),
            controller: _repeat,
            obscureText: true,
            keyboardType: TextInputType.number,
            decoration: field(l10n.changeDevicePinRepeat),
          ),
          const SizedBox(height: AppSpace.md),
          Text(l10n.changeDevicePinProof),
          const SizedBox(height: AppSpace.sm),
          TextField(
            key: const ValueKey('changePinPassword'),
            controller: _password,
            obscureText: true,
            autofillHints: const [AutofillHints.password],
            decoration: field(l10n.passwordLabel),
          ),
          const SizedBox(height: AppSpace.sm),
          TextField(
            key: const ValueKey('changePinCode'),
            controller: _code,
            keyboardType: TextInputType.number,
            autofillHints: const [AutofillHints.oneTimeCode],
            decoration: field(l10n.mfaReauthCode, helper: l10n.changeDevicePinCodeHelper),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpace.md),
            Text(_error!, key: const ValueKey('changePinError'), style: TextStyle(color: context.tokens.danger)),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.cancel)),
        FilledButton(key: const ValueKey('changePinSave'), onPressed: _submit, child: Text(l10n.changeDevicePinSave)),
      ],
    );
  }
}
