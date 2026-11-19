import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/server_provider.dart';

/// ADR-0043 D3/D4, the one required choice. Counsel's 16 Nov advice left this as the whole form:
/// Terms + Privacy, required, with the other two purposes removed or parked.
class ConsentPurpose {
  const ConsentPurpose({
    required this.key,
    required this.required,
    required this.text,
    required this.textHash,
    required this.termsUrl,
    required this.privacyUrl,
    required this.termsLabel,
    required this.privacyLabel,
  });

  final String key;
  final bool required;
  final String text;
  final String textHash;
  final String termsUrl;
  final String privacyUrl;
  final String termsLabel;
  final String privacyLabel;

  factory ConsentPurpose.fromJson(Map<String, dynamic> json) {
    final links = (json['links'] as Map?) ?? const {};
    final text = '${json['text'] ?? ''}';
    return ConsentPurpose(
      key: '${json['key'] ?? ''}',
      required: json['required'] == true,
      text: text,
      textHash: '${json['textHash'] ?? ''}',
      termsUrl: '${links['terms'] ?? ''}',
      privacyUrl: '${links['privacy'] ?? ''}',
      termsLabel: _linkLabel(text, 'terms'),
      privacyLabel: _linkLabel(text, 'privacy'),
    );
  }

  /// The service sends the sentence with its links in markdown (`[label](url)`). The screen renders the
  /// row's own sentence and puts the two links as separate buttons under it, so a tap meant for a link can
  /// never tick the box — the wording itself is never rewritten here.
  static String _linkLabel(String text, String key) {
    for (final match in RegExp(r'\[([^\]]+)\]\(([^)]+)\)').allMatches(text)) {
      final url = match.group(2) ?? '';
      if (url.endsWith('/$key') || url.contains('/$key?')) return match.group(1) ?? '';
    }
    return '';
  }

  /// The sentence without the markdown, for the checkbox label. The link words stay in it as words; the
  /// buttons below carry the tap.
  String get plainText => text.replaceAllMapped(
        RegExp(r'\[([^\]]+)\]\([^)]+\)'),
        (match) => match.group(1) ?? '',
      );
}

class ConsentCopy {
  const ConsentCopy({required this.textVersion, required this.purposes});

  final String textVersion;
  final List<ConsentPurpose> purposes;

  ConsentPurpose? get termsPrivacy => purposes.where((p) => p.key == 'terms_privacy').firstOrNull;

  factory ConsentCopy.fromJson(Map<String, dynamic> json) => ConsentCopy(
        textVersion: '${json['textVersion'] ?? ''}',
        purposes: [
          for (final purpose in (json['purposes'] as List? ?? const []))
            if (purpose is Map) ConsentPurpose.fromJson(Map<String, dynamic>.from(purpose)),
        ],
      );
}

/// `GET /v1/consent-copy?locale=` (ADR-0043 D3). The app renders what it reads; it carries no legal text
/// of its own, and a `textVersion` it did not receive is never sent back on register.
///
/// `autoDispose`: a failed read must not be cached for the app's life — reopening the screen after the
/// server recovers has to try again. The screen's Retry invalidates this provider.
final consentCopyProvider = FutureProvider.autoDispose.family<ConsentCopy, String>((ref, locale) async {
  // A server typed on an unlocked build must be applied before the first request, or the read goes to an
  // empty base URL. Watching the notifier also rebuilds the read if the address changes.
  await ref.watch(serverUrlProvider.notifier).ensureApplied();
  ref.watch(serverUrlProvider);
  final api = ref.watch(apiClientProvider);
  final res = await api.raw.get('/v1/consent-copy', queryParameters: {'locale': locale});
  final data = res.data is Map ? Map<String, dynamic>.from(res.data as Map) : const <String, dynamic>{};
  return ConsentCopy.fromJson(data);
});
