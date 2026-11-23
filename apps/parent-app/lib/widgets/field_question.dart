import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// The question for a form field, placed **above** it and free to wrap.
///
/// Flutter paints `InputDecoration.labelText` on a single line and ellipsises it, so at 320 px / 200 %
/// the add-child dialog showed "Consent meth…" and the onboarding screen showed an incomplete question
/// (Codex's #874 frames, `bureau/874-e6fe7361`). Above the field the same string wraps to as many lines
/// as it needs, and the visible text is excluded from semantics while the field carries it as its
/// accessible name — so a screen reader hears the question once, on the control.
class FieldQuestion extends StatelessWidget {
  const FieldQuestion({super.key, required this.text, required this.child});

  final String text;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(
          child: Text(text, style: Theme.of(context).textTheme.titleSmall),
        ),
        const SizedBox(height: AppSpace.xs),
        Semantics(label: text, child: child),
      ],
    );
  }
}
