import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';

import '../l10n/l10n.dart';

/// A read the caller's invite does not cover (ADR-0014 amendment, decision 7).
///
/// The API answers `403 { error: "permission_required", permission: "alerts" }` for a guardian whose
/// invite lacks the permission. The parent app must say **that** rather than "failed to load": a
/// guardian who sees a generic error cannot tell a bug from a decision their owner made, and decision 7
/// is that the screen names the fix — the owner can grant it.
class ReadPermissionRequired {
  /// The permission the server refused, e.g. `alerts`.
  final String permission;

  const ReadPermissionRequired(this.permission);

  /// The refusal carried by [error], or null when it is something else.
  ///
  /// Only a `403` with the server's own `permission_required` error counts. A plain `403` can also mean
  /// `cross_child_forbidden` or a revoked session, and telling a guardian to ask the owner for access
  /// when the real problem is a stale token would send them to the wrong person.
  /// Whether [error] is a refusal at all, for a screen that wants to suppress the raw error text
  /// without needing the permission name.
  static bool isRefusal(Object error) => error is DioException && from(error) != null;

  static ReadPermissionRequired? from(DioException error) {
    if (error.response?.statusCode != 403) return null;
    final data = error.response?.data;
    if (data is! Map) return null;
    if (data['error'] != 'permission_required') return null;
    final permission = data['permission'];
    if (permission is! String || permission.isEmpty) return null;
    return ReadPermissionRequired(permission);
  }
}

/// What to show for a refused read: decision 7's sentence, naming the owner, in the app's language.
///
/// The permission itself is not interpolated: a guardian does not know the invite vocabulary, and
/// `alerts` in the middle of an Arabic sentence reads as a bug. The permission is kept on
/// [ReadPermissionRequired] for logging and for a future screen that explains each one.
String permissionRequiredMessage(AppLocalizations l10n) => l10n.readPermissionRequired;


/// The text a screen shows when a gated read fails: decision 7's sentence for a refusal, the screen's
/// own message for anything else.
///
/// One helper rather than five copies, because the distinction that matters is *which* errors count as a
/// refusal, and that is already decided in [ReadPermissionRequired.from]. The fallback is a callback so a
/// screen that builds its message from the error does not pay for it on the refusal path.
String readErrorText(AppLocalizations l10n, Object error, String Function() fallback) {
  final refusal = error is DioException ? ReadPermissionRequired.from(error) : null;
  return refusal == null ? fallback() : l10n.readPermissionRequired;
}


/// Whether **any** of these reads was refused (ADR-0014 amendment, decision 7 + #406).
///
/// One banner for the whole map: the permission belongs to the guardian, not to a child, so a screen that
/// renders several children must not show one notice per child. Loading and data are never a refusal, and a
/// plain error stays the screen's own problem — only [ReadPermissionRequired.isRefusal] counts.
bool anyReadRefused(Iterable<AsyncValue<Object?>> values) =>
    values.any((v) => v.hasError && ReadPermissionRequired.isRefusal(v.error!));
