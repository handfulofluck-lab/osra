import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';

/// The consent methods the server accepts (`ConsentCreateSchema.method`).
///
/// One list, because the wire codes are the contract: a fifth method added here
/// without a matching `consentMethod()` label renders an empty row, and a code
/// the route rejects gets a 400 the parent cannot read.
const List<String> kConsentMethods = ['sms_plus', 'kba', 'face_match', 'credit_card'];

/// The consent step: the notice and the method picker, and nothing else.
///
/// Two places ask a parent for consent — adding a child (`AddChildDialog`) and
/// restoring an expired or withdrawn record (`ConsentScreen`, issue #437 part B)
/// — and both must show the same notice, so it lives here once rather than
/// twice. It is a controlled widget: the owner of the choice holds `method` and
/// decides what a change means.
///
/// **Jurisdiction deliberately stays out.** `AddChildDialog` keeps its own
/// dropdown, because child creation is the one place a wrong region can still
/// be corrected before the record exists. The consent screen offers no region
/// choice at all: `POST /v1/family/children/:id/consent` refuses any jurisdiction
/// other than the family's (`family.ts`, `428 consent_jurisdiction_mismatch`),
/// so a choice there would only be a way to fail.
class ConsentStep extends StatelessWidget {
  /// The currently selected method code, one of [kConsentMethods].
  final String method;

  /// Called with the new code when the parent picks another method.
  final ValueChanged<String> onMethodChanged;

  /// The notice above the picker. Defaults to the add-child wording, which says
  /// "before you add a child" — true there, false on the re-grant dialog where
  /// the child already exists with a record. Claude's #448 review: that screen
  /// passes [AppLocalizations.consentRegrantNotice] instead.
  final String? notice;

  const ConsentStep({
    super.key,
    required this.method,
    required this.onMethodChanged,
    this.notice,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // TODO(#159): legal consent wording needs a product/legal
        // decision before it can be translated; it stays English.
        Text(notice ?? l10n.consentNotice),
        const SizedBox(height: AppSpace.md),
        DropdownButtonFormField<String>(
          key: const ValueKey('consentMethod'),
          initialValue: method,
          // `isExpanded` is false by default, which sizes the button to its widest item rather than
          // the field: at 320 px the Arabic method labels then overflow the dialog by 56 px (found by
          // the RTL row on this screen; the same field is in the add-child dialog). Expanded, the
          // labels ellipsise inside the field instead.
          isExpanded: true,
          decoration: InputDecoration(
            labelText: l10n.consentMethodLabel,
            border: const OutlineInputBorder(),
          ),
          items: [
            for (final m in kConsentMethods)
              DropdownMenuItem(value: m, child: Text(l10n.consentMethod(m))),
          ],
          onChanged: (v) => onMethodChanged(v ?? kConsentMethods.first),
        ),
      ],
    );
  }
}
