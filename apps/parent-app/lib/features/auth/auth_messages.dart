import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';

/// The server's minimum password length (`RegisterSchema` in services/api/src/routes/auth.ts).
const kMinPasswordLength = 12;

/// The register form's first problem a parent can fix, checked before the request goes out, in
/// the order the fields appear; null leaves the rest to the server. It mirrors `RegisterSchema`
/// loosely on purpose: the email check is only "has an @", and the server's stricter answer comes
/// back through [authFieldError].
String? registerFormProblem(
  AppLocalizations l10n, {
  required String email,
  required String password,
  required String displayName,
  required String familyName,
}) {
  if (!email.contains('@')) return l10n.authEmailInvalid;
  if (password.length < kMinPasswordLength) return l10n.registerPasswordTooShort;
  if (displayName.isEmpty || familyName.isEmpty) return l10n.registerNamesRequired;
  return null;
}

/// One sentence for a [kValidationFailedPrefix] error, naming the field the server rejected.
/// Only registration checks the password's length (sign-in accepts any string), so a `password`
/// field error always means "too short".
String authFieldError(AppLocalizations l10n, String error) {
  final fields = error.substring(kValidationFailedPrefix.length).split(',').toSet();
  if (fields.contains('email')) return l10n.authEmailInvalid;
  if (fields.contains('password')) return l10n.registerPasswordTooShort;
  if (fields.contains('displayName') || fields.contains('familyName')) return l10n.registerNamesRequired;
  return l10n.authFieldsInvalid;
}
