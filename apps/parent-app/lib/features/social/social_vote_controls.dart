import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ltr_isolate.dart';
import '../../l10n/l10n.dart';
import '../../providers/social_vote_provider.dart';
import '../../theme/app_tokens.dart';

double _measureVoteButtonWidth(BuildContext context, String label) {
  final painter = TextPainter(
    text: TextSpan(
      text: label,
      style: Theme.of(context).textTheme.labelLarge,
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  return painter.width + 18 + 8 + 24;
}

double measureCompactVoteControlWidth(BuildContext context, String? verdict) {
  final l10n = context.l10n;
  if (verdict == null) {
    return _measureVoteButtonWidth(context, l10n.flagVoteConcerning) +
        AppSpace.sm +
        _measureVoteButtonWidth(context, l10n.flagVoteNotConcerning);
  }
  final label = verdict == 'concerning'
      ? l10n.flagVoteConcerning
      : l10n.flagVoteNotConcerning;
  return _measureVoteButtonWidth(context, label);
}

class SocialVoteControls extends ConsumerStatefulWidget {
  final String eventId;
  final bool compact;

  const SocialVoteControls({
    super.key,
    required this.eventId,
    this.compact = false,
  });

  @override
  ConsumerState<SocialVoteControls> createState() => _SocialVoteControlsState();
}

class _SocialVoteControlsState extends ConsumerState<SocialVoteControls> {
  bool _editing = false;

  @override
  void didUpdateWidget(covariant SocialVoteControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.eventId != widget.eventId) _editing = false;
  }

  String _label(AppLocalizations l10n, String verdict) =>
      verdict == 'concerning'
          ? l10n.flagVoteConcerning
          : l10n.flagVoteNotConcerning;

  void _cast(String verdict) {
    final controller = ref.read(socialVoteProvider(widget.eventId).notifier);
    if (ref.read(socialVoteProvider(widget.eventId)).ownVerdict == verdict) {
      return;
    }
    setState(() => _editing = false);
    unawaited(controller.vote(verdict));
    final l10n = context.l10n;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: const Duration(seconds: 4),
        persist: false,
        content: Text(l10n.flagVoteThanks),
        action: SnackBarAction(
          label: l10n.undo,
          onPressed: () => unawaited(controller.undo()),
        ),
      ));
  }

  void _clear() {
    final controller = ref.read(socialVoteProvider(widget.eventId).notifier);
    setState(() => _editing = false);
    unawaited(controller.withdraw());
    final l10n = context.l10n;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: const Duration(seconds: 4),
        persist: false,
        content: Text(l10n.flagVoteCleared),
        action: SnackBarAction(
          label: l10n.undo,
          onPressed: () => unawaited(controller.undo()),
        ),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final vote = ref.watch(socialVoteProvider(widget.eventId));
    if (vote.isUnavailable) return const SizedBox.shrink();
    final l10n = context.l10n;
    final latestVerdict = vote.verdict;
    final voterLine = vote.parentDisplayName == null || latestVerdict == null
        ? null
        : l10n.flagVoteBy(
            firstStrongIsolate(vote.parentDisplayName!),
            _label(l10n, latestVerdict),
          );

    final content = widget.compact
        ? _buildCompact(vote, voterLine)
        : _buildDetail(vote, voterLine);
    if (!vote.isSaving && !vote.needsRetry) return content;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        content,
        const SizedBox(height: AppSpace.xs),
        Wrap(
          spacing: AppSpace.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (vote.isSaving)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            Text(l10n.saving, style: Theme.of(context).textTheme.bodySmall),
            if (vote.needsRetry)
              TextButton(
                onPressed: () => unawaited(
                  ref.read(socialVoteProvider(widget.eventId).notifier).retry(),
                ),
                child: Text(l10n.retry),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildDetail(SocialVoteState vote, String? voterLine) {
    final l10n = context.l10n;
    return LayoutBuilder(builder: (context, constraints) {
      final vertical = constraints.maxWidth < 340 ||
          MediaQuery.textScalerOf(context).scale(14) > 21;
      final choices = [
        _detailChoice('concerning', vote.ownVerdict),
        _detailChoice('not_concerning', vote.ownVerdict),
      ];
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.flagVoteQuestion,
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpace.md),
          if (vertical)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                choices[0],
                const SizedBox(height: AppSpace.sm),
                choices[1],
              ],
            )
          else
            Row(
              children: [
                Expanded(child: choices[0]),
                const SizedBox(width: AppSpace.sm),
                Expanded(child: choices[1]),
              ],
            ),
          if (vote.ownVerdict != null) ...[
            const SizedBox(height: AppSpace.sm),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Semantics(
                label: l10n.flagVoteA11yClear,
                button: true,
                child: TextButton(
                  onPressed: _clear,
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  child: Text(l10n.flagVoteClear),
                ),
              ),
            ),
          ],
          const SizedBox(height: AppSpace.sm),
          Text(
            l10n.flagVoteHelp,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.tokens.onSurfaceVariant,
                ),
          ),
          if (voterLine != null) ...[
            const SizedBox(height: AppSpace.xs),
            Text(voterLine, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      );
    });
  }

  Widget _detailChoice(String verdict, String? selectedVerdict) {
    final l10n = context.l10n;
    final selected = selectedVerdict == verdict;
    final label = _label(l10n, verdict);
    final icon = verdict == 'concerning' ? Icons.flag : Icons.check_circle;
    if (!selected) {
      return OutlinedButton.icon(
        onPressed: () => _cast(verdict),
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
      );
    }
    final tokens = context.tokens;
    final concerning = verdict == 'concerning';
    return MergeSemantics(
      child: Semantics(
        selected: true,
        button: true,
        enabled: true,
        child: FilledButton.tonalIcon(
          onPressed: () {},
          icon: const Icon(Icons.check, size: 18),
          label: Text(label),
          style: FilledButton.styleFrom(
            minimumSize: const Size(48, 48),
            backgroundColor: concerning
                ? tokens.severityWarning.withValues(alpha: 0.24)
                : tokens.surfaceVariant,
            foregroundColor:
                concerning ? tokens.severityWarningText : tokens.onSurface,
          ),
        ),
      ),
    );
  }

  Widget _buildCompact(SocialVoteState vote, String? voterLine) {
    final verdict = vote.ownVerdict;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (verdict != null && !_editing)
          _selectedPill(verdict)
        else
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.xs,
            children: [
              _compactChoice('concerning', verdict),
              _compactChoice('not_concerning', verdict),
            ],
          ),
        if (voterLine != null) ...[
          const SizedBox(height: AppSpace.xs),
          Text(voterLine, style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
  }

  Widget _compactChoice(String verdict, String? selectedVerdict) {
    final l10n = context.l10n;
    final concerning = verdict == 'concerning';
    final selected = selectedVerdict == verdict;
    final tokens = context.tokens;
    final a11yLabel = concerning
        ? l10n.flagVoteA11yConcerning
        : l10n.flagVoteA11yNotConcerning;
    final label = _label(l10n, verdict);
    final icon = Icon(concerning ? Icons.flag : Icons.check_circle, size: 18);
    final Widget button;
    if (selected) {
      final bg = concerning
          ? tokens.severityWarning.withValues(alpha: 0.24)
          : tokens.surfaceVariant;
      final fg =
          concerning ? tokens.severityWarningText : tokens.onSurfaceVariant;
      button = FilledButton.tonalIcon(
        onPressed: null,
        icon: icon,
        label: Text(label),
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          backgroundColor: bg,
          foregroundColor: fg,
          disabledBackgroundColor: bg,
          disabledForegroundColor: fg,
          side: BorderSide(color: tokens.border),
        ),
      );
    } else {
      button = OutlinedButton.icon(
        onPressed: () => _cast(verdict),
        icon: icon,
        label: Text(label),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          side: BorderSide(color: tokens.border),
        ),
      );
    }
    return Tooltip(
      message: a11yLabel,
      excludeFromSemantics: true,
      child: Semantics(
        label: a11yLabel,
        button: true,
        selected: selected,
        enabled: !selected,
        child: button,
      ),
    );
  }

  Widget _selectedPill(String verdict) {
    final l10n = context.l10n;
    final concerning = verdict == 'concerning';
    final tokens = context.tokens;
    return FilledButton.tonalIcon(
      onPressed: () => setState(() => _editing = true),
      icon: const Icon(Icons.check, size: 18),
      label: Text(_label(l10n, verdict)),
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        backgroundColor: concerning
            ? tokens.severityWarning.withValues(alpha: 0.24)
            : tokens.surfaceVariant,
        foregroundColor:
            concerning ? tokens.severityWarningText : tokens.onSurfaceVariant,
        shape: const StadiumBorder(),
      ),
    );
  }
}
