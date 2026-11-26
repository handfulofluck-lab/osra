import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/models.dart';
import '../../api/permission_errors.dart';
import '../../core/ltr_isolate.dart';
import '../../l10n/l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/family_provider.dart';
import '../../providers/world_class_provider.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/error_retry_view.dart';
import 'rules_behind_banner.dart';
import 'rules_editor_screen.dart' show RulesEditorScreen, kLegacyWebCategories;

/// Build-time switch for the P-12 Web filter redesign (#1179, `OSRA_UX_P12`).
/// Defaults to `false` so the legacy `RulesEditorScreen` web-filter tab remains
/// the fallback unless `--dart-define=OSRA_UX_P12=true` or a test overrides
/// [p12WebFilterEnabledProvider].
const bool kP12WebFilterDefault = bool.fromEnvironment('OSRA_UX_P12', defaultValue: false);

/// Feature switch for P-12 Web filter (#1179).
final p12WebFilterEnabledProvider = Provider<bool>((ref) => kP12WebFilterDefault);

/// `/child/:id/web-filter` (#1229): the P-12 screen when its switch is on, the
/// legacy web-filter tab of the rules editor when it is off. One entry point,
/// so a parent can always reach their filter either way.
class WebFilterP12Route extends ConsumerWidget {
  final String childId;

  const WebFilterP12Route({super.key, required this.childId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(p12WebFilterEnabledProvider)) return WebFilterP12Screen(childId: childId);
    return RulesEditorScreen(childId: childId, initialTab: RulesEditorScreen.webFilterTab);
  }
}

/// P-12 Web filter (#1229, row P-12 of the UX final breakdown).
///
/// Category tiles saying Blocked/Allowed, the recently blocked sites with
/// "Allow site" for one exact domain, the always-allow and blocked site lists,
/// Safe search and YouTube Restricted Mode in one card under the UI/UX Bureau's
/// binding line, which browsers are covered (Android wording; iPhone shows the
/// "Not yet available" state), and the enforcement banner with its state pill
/// built on the pack state the child reports (#1079/#1097).
///
/// A11 ("Recommended protection" for the 13 categories) keeps its place above
/// the tiles and A14 ("Searches and videos") links the existing search screen.
/// There is no single shield toggle and no school whitelist (Bureau row P-12).
class WebFilterP12Screen extends ConsumerStatefulWidget {
  final String childId;

  const WebFilterP12Screen({super.key, required this.childId});

  @override
  ConsumerState<WebFilterP12Screen> createState() => _WebFilterP12ScreenState();
}

class _WebFilterP12ScreenState extends ConsumerState<WebFilterP12Screen> {
  RuleSet _draft = const RuleSet();
  RuleSet? _saved;
  bool _saving = false;
  String? _error;

  /// Days the recently-blocked list covers, matching the reports screen's short window.
  static const int _recentDays = 7;

  bool get _recommendedOn => kRecommendedCategories.every(_draft.webFilter.blockedCategories.contains);

  void _applyLoaded(RuleSet ruleSet) {
    if (_saved != null) return;
    _saved = ruleSet;
    _draft = ruleSet;
  }

  void _updateWebFilter(WebFilterRule Function(WebFilterRule) f) {
    setState(() => _draft = _draft.copyWith(webFilter: f(_draft.webFilter)));
  }

  Future<void> _toggleRecommended(bool enable) async {
    final l10n = context.l10n;
    if (enable) {
      _updateWebFilter((w) => w.copyWith(
            blockedCategories: {...w.blockedCategories, ...kRecommendedCategories}.toList(),
          ));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(l10n.recommendedProtection),
        content: Text(l10n.disablingRecommended),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.cancel)),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(l10n.continueLabel)),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _updateWebFilter((w) => w.copyWith(
          blockedCategories: ({...w.blockedCategories}..removeAll(kRecommendedCategories)).toList(),
        ));
  }

  void _setCategoryBlocked(String category, bool blocked) {
    _updateWebFilter((w) {
      final cats = {...w.blockedCategories};
      blocked ? cats.add(category) : cats.remove(category);
      return w.copyWith(blockedCategories: cats.toList());
    });
  }

  void _addDomain(String domain, {required bool allowed}) {
    final value = domain.trim();
    if (value.isEmpty) return;
    _updateWebFilter((w) => allowed
        ? w.copyWith(
            allowedDomains: {...w.allowedDomains, value}.toList(),
            blockedDomains: [...w.blockedDomains]..remove(value),
          )
        : w.copyWith(
            blockedDomains: {...w.blockedDomains, value}.toList(),
            allowedDomains: [...w.allowedDomains]..remove(value),
          ));
  }

  void _removeDomain(String domain, {required bool allowed}) {
    _updateWebFilter((w) => allowed
        ? w.copyWith(allowedDomains: [...w.allowedDomains]..remove(domain))
        : w.copyWith(blockedDomains: [...w.blockedDomains]..remove(domain)));
  }

  /// The always-allow dialog, also used by "Allow site" on one recently blocked
  /// host: the field arrives filled with that exact domain, so saving it stores
  /// the host and nothing wider.
  Future<void> _addSiteDialog({String? exactDomain, required bool allowed}) async {
    final l10n = context.l10n;
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _SiteDialog(
        title: allowed ? l10n.alwaysAllowed : l10n.alertCategoryWebThreat,
        initial: exactDomain ?? '',
      ),
    );
    if (value == null || !mounted) return;
    _addDomain(value, allowed: allowed);
  }

  Future<void> _save() async {
    final saved = _saved;
    if (saved == null || _saving) return;
    final submitted = _draft;
    final l10n = context.l10n;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).raw.patch(
            '/v1/rules/${widget.childId}',
            data: submitted.changesFrom(saved),
          );
      if (!mounted) return;
      _saved = submitted;
      ref.invalidate(rulesProvider(widget.childId));
      ref.invalidate(familyProvider);
      final savedDevices =
          ref.read(familyProvider).valueOrNull?.devicesFor(widget.childId) ?? const <Device>[];
      for (final device in savedDevices) {
        ref.invalidate(deviceCommandHistoryProvider(device.id));
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.rulesSaved)));
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _error = saveErrorText(l10n, e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyErrorText(l10n, e, () => l10n.rulesLoadFailed));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final rules = ref.watch(rulesProvider(widget.childId));
    ref.listen(rulesProvider(widget.childId), (_, next) => next.whenData(_applyLoaded));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.tabWebFilter, maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
      body: rules.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorRetryView(
          message: friendlyErrorText(l10n, e, () => l10n.rulesLoadFailed),
          onRetry: () => ref.invalidate(rulesProvider(widget.childId)),
        ),
        data: (ruleSet) {
          _applyLoaded(ruleSet);
          return _buildBody(context, l10n);
        },
      ),
      bottomNavigationBar: rules.valueOrNull != null ? _buildSaveFooter(context, l10n) : null,
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final tokens = context.tokens;
    final devices = ref.watch(familyProvider).valueOrNull?.devicesFor(widget.childId) ?? const <Device>[];
    final iosOnly = devices.isNotEmpty && devices.every((d) => d.platform == 'ios');

    return Column(
      children: [
        RulesBehindBanner(childId: widget.childId),
        Expanded(
          child: ListView(
            key: const ValueKey('p12-list'),
            padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.sm, AppSpace.lg, AppSpace.lg),
            children: [
              _enforcementBanner(context, l10n, tokens, devices),
              _recommendedCard(context, l10n, tokens),
              const SizedBox(height: AppSpace.md),
              _categoriesCard(context, l10n, tokens),
              const SizedBox(height: AppSpace.md),
              _blockedCard(context, l10n, tokens),
              const SizedBox(height: AppSpace.md),
              _allowedCard(context, l10n, tokens),
              const SizedBox(height: AppSpace.md),
              _safeSearchAndYouTubeCard(context, l10n, tokens),
              const SizedBox(height: AppSpace.md),
              _browsersCard(context, l10n, tokens, iosOnly: iosOnly),
              const SizedBox(height: AppSpace.sm),
              _searchesRow(context, l10n, tokens),
            ],
          ),
        ),
      ],
    );
  }

  /// F9 (#1079/#1097): what the child reports about its filter, in the parent's
  /// own words. The banner appears only when a phone says the filter is not
  /// running in full — never for a phone that never reported.
  Widget _enforcementBanner(
    BuildContext context,
    AppLocalizations l10n,
    AppTokens tokens,
    List<Device> devices,
  ) {
    final degraded = [
      for (final d in devices)
        if (d.setup?.feature('web_filter') case final state? when state != 'ready') d,
    ];
    if (degraded.isEmpty) return const SizedBox.shrink();
    final first = degraded.first;
    final model = first.model.trim();

    return Card(
      key: const ValueKey('p12-enforcement-banner'),
      color: tokens.warn.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, color: tokens.warn, size: 20),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    l10n.phoneSetupFeatureWebFilter,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(color: tokens.onSurface),
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                _pill(
                  context,
                  key: const ValueKey('p12-not-blocked-pill'),
                  label: l10n.phoneSetupStateDegraded,
                  color: tokens.warn,
                ),
              ],
            ),
            if (model.isNotEmpty) ...[
              const SizedBox(height: AppSpace.xs),
              Text(
                firstStrongIsolate(model),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
              ),
            ],
            if (first.setup?.missing.contains('web_filter') ?? false) ...[
              const SizedBox(height: AppSpace.xs),
              Text(
                l10n.phoneSetupFixList,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
              ),
              Text(
                '• ${l10n.grantWebFilter}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _pill(BuildContext context, {required Key key, required String label, required Color color}) {
    return Container(
      key: key,
      padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.sm, AppSpace.xxs, AppSpace.sm, AppSpace.xxs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
      ),
    );
  }

  /// A11: the one-tap preset for the 13 recommended categories, first row above
  /// the tiles (Karim's 17:06 rule — a shipped feature the design drops stays).
  Widget _recommendedCard(BuildContext context, AppLocalizations l10n, AppTokens tokens) {
    return Card(
      key: const ValueKey('p12-recommended-card'),
      child: SwitchListTile.adaptive(
        key: const ValueKey('p12-recommended-switch'),
        title: Text(l10n.recommendedProtection),
        subtitle: Text(l10n.recommendedProtectionSubtitle),
        value: _recommendedOn,
        onChanged: _toggleRecommended,
      ),
    );
  }

  /// One category as a tile that says its state in words, not a switch: the
  /// Bureau's row asks for "Blocked" / "Allowed" and no icon-only control.
  Widget _categoryTile(BuildContext context, AppLocalizations l10n, AppTokens tokens, String category) {
    final blocked = _draft.webFilter.blockedCategories.contains(category);
    final color = blocked ? tokens.ok : tokens.onSurfaceVariant;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('p12-category-$category'),
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () => _setCategoryBlocked(category, !blocked),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 120),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
          decoration: BoxDecoration(
            color: blocked ? tokens.ok.withValues(alpha: 0.10) : tokens.surfaceContainer,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: blocked ? tokens.ok : tokens.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  l10n.webCategory(category),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.onSurface),
                  softWrap: true,
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Text(
                blocked ? l10n.blocked : l10n.allowed,
                key: ValueKey('p12-category-state-$category'),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _categoriesCard(BuildContext context, AppLocalizations l10n, AppTokens tokens) {
    // Recommended categories first, then any legacy extras still stored, so a
    // category turned on by an older build stays visible and switchable.
    final categories = [
      ...kRecommendedCategories,
      for (final c in kLegacyWebCategories)
        if (!kRecommendedCategories.contains(c)) c,
      for (final c in _draft.webFilter.blockedCategories)
        if (!kRecommendedCategories.contains(c) && !kLegacyWebCategories.contains(c)) c,
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.blockedCategories,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: tokens.onSurface),
            ),
            const SizedBox(height: AppSpace.sm),
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.sm,
              children: [
                for (final c in categories) _categoryTile(context, l10n, tokens, c),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Recently blocked hosts and the blocked-site list in one card: both answer
  /// "what is blocked". The recent rows come from the reports summary and are
  /// hidden whole when the server withholds host names (SITE_NAMES off, or a
  /// guardian without `social`), per the P-12 row's dependency.
  Widget _blockedCard(BuildContext context, AppLocalizations l10n, AppTokens tokens) {
    final summary = ref.watch(reportSummaryProvider((childId: widget.childId, days: _recentDays))).valueOrNull;
    final recent = summary?.blockedDomainsVisible == true ? summary!.topBlockedDomains : null;
    return Card(
      key: const ValueKey('p12-blocked-card'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.alertCategoryWebThreat,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: tokens.onSurface),
            ),
            if (recent != null) ...[
              const SizedBox(height: AppSpace.xs),
              if (recent.isEmpty)
                Text(
                  l10n.noBlockedSites(_recentDays),
                  key: const ValueKey('p12-recently-empty'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
                )
              else
                for (final site in recent)
                  _recentSiteRow(context, l10n, tokens, site),
            ],
            const Divider(height: AppSpace.xl),
            ..._domainList(context, l10n, tokens, allowed: false),
          ],
        ),
      ),
    );
  }

  Widget _recentSiteRow(BuildContext context, AppLocalizations l10n, AppTokens tokens, BlockedDomain site) {
    return Padding(
      key: ValueKey('p12-recent-${site.domain}'),
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xxs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ltrIsolate(site.domain),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.onSurface),
                ),
                Text(
                  l10n.blockedTimes(site.count),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
                ),
              ],
            ),
          ),
          TextButton(
            key: ValueKey('p12-allow-${site.domain}'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => _addSiteDialog(exactDomain: site.domain, allowed: true),
            child: Text(l10n.allowAction),
          ),
        ],
      ),
    );
  }

  Widget _allowedCard(BuildContext context, AppLocalizations l10n, AppTokens tokens) {
    return Card(
      key: const ValueKey('p12-allowed-card'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.alwaysAllowed,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: tokens.onSurface),
            ),
            const SizedBox(height: AppSpace.xs),
            ..._domainList(context, l10n, tokens, allowed: true),
          ],
        ),
      ),
    );
  }

  /// One site list: chips with a remove control (48 dp) and an add button.
  List<Widget> _domainList(
    BuildContext context,
    AppLocalizations l10n,
    AppTokens tokens, {
    required bool allowed,
  }) {
    final domains = allowed ? _draft.webFilter.allowedDomains : _draft.webFilter.blockedDomains;
    return [
      if (domains.isEmpty)
        Text(
          '—',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
        )
      else
        Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.xs,
          children: [
            for (final d in domains)
              InputChip(
                key: ValueKey('p12-site-${allowed ? 'allow' : 'block'}-$d'),
                label: Text(ltrIsolate(d)),
                onDeleted: () => _removeDomain(d, allowed: allowed),
                deleteIcon: const Icon(Icons.close, size: 18),
                materialTapTargetSize: MaterialTapTargetSize.padded,
              ),
          ],
        ),
      const SizedBox(height: AppSpace.xs),
      TextButton.icon(
        key: ValueKey(allowed ? 'p12-add-allowed' : 'p12-add-blocked'),
        style: TextButton.styleFrom(minimumSize: const Size(48, 48), alignment: AlignmentDirectional.centerStart),
        icon: const Icon(Icons.add),
        label: Text(l10n.add),
        onPressed: () => _addSiteDialog(allowed: allowed),
      ),
    ];
  }

  /// A12 kept as one card: Safe search and YouTube Restricted Mode together, the
  /// YouTube line carrying the UI/UX Bureau's binding English verbatim
  /// (#1226, 7201504906). A12's three levels stay reachable here.
  Widget _safeSearchAndYouTubeCard(BuildContext context, AppLocalizations l10n, AppTokens tokens) {
    final wf = _draft.webFilter;
    return Card(
      key: const ValueKey('p12-safe-search-youtube'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.searchSafetyTitle,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: tokens.onSurface),
            ),
            SwitchListTile.adaptive(
              key: const ValueKey('p12-safe-search-switch'),
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.enforceSafeSearch),
              value: wf.safeSearchEnforced,
              onChanged: (v) => _updateWebFilter((w) => w.copyWith(safeSearchEnforced: v)),
            ),
            const Divider(height: AppSpace.lg),
            Text(
              l10n.youtubeRestrictedMode,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(color: tokens.onSurface),
            ),
            const SizedBox(height: AppSpace.xxs),
            Text(
              l10n.youtubeRestrictedDesc,
              key: const ValueKey('p12-youtube-desc'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpace.sm),
            SegmentedButton<String>(
              key: const ValueKey('p12-youtube-mode'),
              segments: [
                ButtonSegment(value: 'strict', label: Text(l10n.strict)),
                ButtonSegment(value: 'moderate', label: Text(l10n.moderate)),
                ButtonSegment(value: 'off', label: Text(l10n.off)),
              ],
              selected: {wf.youtubeRestrictedMode},
              onSelectionChanged: (sel) =>
                  _updateWebFilter((w) => w.copyWith(youtubeRestrictedMode: sel.first)),
            ),
          ],
        ),
      ),
    );
  }

  /// Which browsers the filter covers, in the Android wording the existing app
  /// uses; an iPhone-only child gets the "Not yet available" state instead (F8).
  Widget _browsersCard(BuildContext context, AppLocalizations l10n, AppTokens tokens, {required bool iosOnly}) {
    return Card(
      key: const ValueKey('p12-browsers-card'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.public, color: iosOnly ? tokens.onSurfaceVariant : tokens.primary, size: 20),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: iosOnly
                  ? Row(
                      children: [
                        Flexible(
                          child: Text(
                            l10n.tabWebFilter,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.onSurface),
                          ),
                        ),
                        const SizedBox(width: AppSpace.sm),
                        _pill(
                          context,
                          key: const ValueKey('p12-iphone-not-available'),
                          label: l10n.phoneSetupStateUnavailable,
                          color: tokens.onSurfaceVariant,
                        ),
                      ],
                    )
                  : Text(
                      l10n.searchSafetyEmptyBody,
                      key: const ValueKey('p12-browsers-android'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// A14: the shipped searches screen stays reachable from P-12.
  Widget _searchesRow(BuildContext context, AppLocalizations l10n, AppTokens tokens) {
    return Card(
      child: ListTile(
        key: const ValueKey('p12-searches-row'),
        leading: Icon(Icons.manage_search, color: tokens.primary),
        title: Text(l10n.searchSafetyTitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/child/${widget.childId}/searches'),
      ),
    );
  }

  Widget _buildSaveFooter(BuildContext context, AppLocalizations l10n) {
    final tokens = context.tokens;
    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: tokens.surface,
          border: Border(top: BorderSide(color: tokens.border)),
        ),
        padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.sm, AppSpace.lg, AppSpace.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              Container(
                key: const ValueKey('p12-save-error'),
                decoration: BoxDecoration(
                  color: tokens.danger.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: tokens.danger),
                ),
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
                child: Text(
                  _error!,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.onSurface),
                ),
              ),
              const SizedBox(height: AppSpace.sm),
            ],
            FilledButton(
              key: const ValueKey('p12-save-button'),
              style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 52)),
              onPressed: (_saved != null && !_saving) ? _save : null,
              child: _saving
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: tokens.onPrimary),
                    )
                  : Text(l10n.save),
            ),
          ],
        ),
      ),
    );
  }
}

/// One-domain dialog that owns its [TextEditingController], so the field outlives
/// the dialog's exit animation (disposing it when `showDialog` returned tripped
/// "A TextEditingController was used after being disposed").
class _SiteDialog extends StatefulWidget {
  final String title;
  final String initial;

  const _SiteDialog({required this.title, required this.initial});

  @override
  State<_SiteDialog> createState() => _SiteDialogState();
}

class _SiteDialogState extends State<_SiteDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      scrollable: true,
      title: Text(widget.title),
      content: TextField(
        key: const ValueKey('p12-site-field'),
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        textDirection: TextDirection.ltr,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(hintText: 'example.com', border: OutlineInputBorder()),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.cancel)),
        FilledButton(
          key: const ValueKey('p12-site-save'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(l10n.save),
        ),
      ],
    );
  }
}
