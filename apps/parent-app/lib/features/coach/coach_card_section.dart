import 'package:flutter/material.dart';

import 'coach_content.dart';

/// Feature #16: expandable "How to talk about this" coaching section (EN/AR).
/// Reused by the alert-detail dialog and the social-concerns vault; the
/// language toggle switches the whole card between English and Arabic.
class CoachCardSection extends StatefulWidget {
  final CoachCard card;
  const CoachCardSection({super.key, required this.card});

  @override
  State<CoachCardSection> createState() => _CoachCardSectionState();
}

class _CoachCardSectionState extends State<CoachCardSection> {
  bool _arabic = false;

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final title = _arabic ? card.titleAr : card.title;
    final body = _arabic ? card.bodyAr : card.body;
    final tips = _arabic ? card.tipsAr : card.tips;
    return ExpansionTile(
      leading: const Icon(Icons.forum_outlined),
      title: Text(_arabic ? 'كيف تتحدث مع طفلك عن هذا' : 'How to talk about this'),
      subtitle: Text(title),
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
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
                          padding: EdgeInsets.only(right: 6),
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
                    onPressed: () => setState(() => _arabic = !_arabic),
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
