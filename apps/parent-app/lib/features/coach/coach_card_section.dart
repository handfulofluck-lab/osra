import 'package:flutter/material.dart';

import 'coach_content.dart';
import 'local_help_numbers.dart';

/// Feature #16: expandable "How to talk about this" coaching section (EN/AR).
/// Reused by the alert-detail dialog and the social-concerns vault; the card
/// follows the app locale and keeps a manual toggle between English and Arabic.
class CoachCardSection extends StatefulWidget {
  final CoachCard card;

  /// The family's region (`US`, `EU`, `UK`, `OTHER`), used only as the fallback
  /// for the emergency number when the device locale carries no country. The
  /// card always resolves from the device first (#723).
  final String? region;

  const CoachCardSection({super.key, required this.card, this.region});

  @override
  State<CoachCardSection> createState() => _CoachCardSectionState();
}

class _CoachCardSectionState extends State<CoachCardSection> {
  bool? _arabicOverride;

  bool get _arabic =>
      _arabicOverride ?? Localizations.localeOf(context).languageCode == 'ar';

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final numbers = resolveHelpNumbers(
        countryCode: deviceCountryCode(), region: widget.region);
    final title = _arabic ? card.titleAr : card.title;
    final body = fillHelpNumbers(_arabic ? card.bodyAr : card.body, numbers,
        arabic: _arabic);
    final tips = <String>[
      for (final tip in _arabic ? card.tipsAr : card.tips)
        fillHelpNumbers(tip, numbers, arabic: _arabic),
    ];
    return ExpansionTile(
      leading: const Icon(Icons.forum_outlined),
      // The card is deliberately bilingual: its heading follows the card's
      // language, not the surrounding UI locale.
      title:
          Text(_arabic ? 'كيف تتحدث مع طفلك عن هذا' : 'How to talk about this'),
      subtitle: Text(title),
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(body),
                const SizedBox(height: 8),
                for (final tip in tips)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsetsDirectional.only(end: 6),
                          child: Text('•'),
                        ),
                        Expanded(child: Text(tip)),
                      ],
                    ),
                  ),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton.icon(
                    key: const ValueKey('coachLangToggle'),
                    onPressed: () => setState(() => _arabicOverride = !_arabic),
                    icon: const Icon(Icons.translate, size: 18),
                    label: Text(_arabic ? 'EN' : 'عربي'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
