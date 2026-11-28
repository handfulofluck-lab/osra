import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/models.dart';
import '../../core/ltr_isolate.dart';
import '../../l10n/l10n.dart';
import '../../providers/family_provider.dart';
import '../../providers/world_class_provider.dart';
import '../../theme/app_tokens.dart';
import 'rules_editor_screen.dart' show RulesEditorScreen, kLegacyWebCategories;

/// Build-time switch for the P-12 Web filter redesign (#1179, `OSRA_UX_P12`).
/// Defaults to `false` so the legacy `RulesEditorScreen` web-filter tab remains
/// the fallback unless `--dart-define=OSRA_UX_P12=true` or a test overrides
/// [p12WebFilterEnabledProvider].
const bool kP12WebFilterDefault = bool.fromEnvironment(
  'OSRA_UX_P12',
  defaultValue: bool.fromEnvironment('OSRA_UX_FINAL', defaultValue: false),
);

/// Feature switch for P-12 Web filter (#1179).
final p12WebFilterEnabledProvider = Provider<bool>((ref) => kP12WebFilterDefault);

/// `/child/:id/web-filter` (#1229): one entry point to the web filter. It opens
/// the rules editor on its web-filter tab, and the editor's own switch decides
/// whether that tab is P-12 or the legacy body — so the parent always lands on
/// an editor that owns one draft and one Save.
class WebFilterP12Route extends StatelessWidget {
  final String childId;

  const WebFilterP12Route({super.key, required this.childId});

  @override
  Widget build(BuildContext context) =>
      RulesEditorScreen(childId: childId, initialTab: RulesEditorScreen.webFilterTab);
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
///
/// It is a **view over the rules editor's draft** (#1238 review): every edit
/// goes through [onChanged] into `RulesEditorScreen`'s `_draft`, and the
/// editor's footer is the only Save. The screen posts nothing itself, so a
/// parent's change can never be saved by a path that skipped the draft.
class WebFilterP12Screen extends ConsumerWidget {
  final String childId;

  /// The editor's current web-filter draft for this child.
  final WebFilterRule webFilter;

  /// Writes a new web-filter draft back into the editor.
  final ValueChanged<WebFilterRule> onChanged;

  const WebFilterP12Screen({
    super.key,
    required this.childId,
    required this.webFilter,
    required this.onChanged,
  });

  /// Days the recently-blocked list covers, matching the reports screen's short window.
  static const int recentDays = 7;

  bool get _recommendedOn => kRecommendedCategories.every(webFilter.blockedCategories.contains);

  /// The one write path: the editor's draft, never a local copy.
  void _updateWebFilter(WebFilterRule Function(WebFilterRule) f) => onChanged(f(webFilter));

  Future<void> _toggleRecommended(BuildContext context, bool enable) async {
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
    if (confirmed != true) return;
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
  Future<void> _addSiteDialog(BuildContext context, {String? exactDomain, required bool allowed}) async {
    final l10n = context.l10n;
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _SiteDialog(
        title: allowed ? l10n.p12AllowSiteTitle : l10n.p12BlockSiteTitle,
        initial: exactDomain ?? '',
      ),
    );
    if (value == null) return;
    _addDomain(value, allowed: allowed);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final tokens = context.tokens;
    final devices = ref.watch(familyProvider).valueOrNull?.devicesFor(childId) ?? const <Device>[];
    final iosOnly = devices.isNotEmpty && devices.every((d) => d.platform == 'ios');
    // #1238 review (Codex, 11:26): the browser card's affirmative sentence claims
    // active enforcement and inspection. Only say that when an Android phone
    // actually reports the filter ready; a pending, empty or degraded device list
    // must not inherit the claim. `p12NotBlockingYet` is the approved fallback.
    final androidReady =
        devices.any((d) => d.platform != 'ios' && d.setup?.feature('web_filter') == 'ready');

    return ListView(
      key: const ValueKey('p12-list'),
      padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.sm, AppSpace.lg, AppSpace.lg),
      children: [
        _enforcementBanner(context, l10n, tokens, devices),
        _recommendedCard(context, l10n, tokens),
        const SizedBox(height: AppSpace.md),
        _categoriesCard(context, l10n, tokens),
        const SizedBox(height: AppSpace.md),
        _blockedCard(context, ref, l10n, tokens),
        const SizedBox(height: AppSpace.md),
        _blockedSitesCard(context, l10n, tokens),
        const SizedBox(height: AppSpace.md),
        _allowedCard(context, l10n, tokens),
        const SizedBox(height: AppSpace.md),
        _safeSearchAndYouTubeCard(context, l10n, tokens),
        const SizedBox(height: AppSpace.md),
        _browsersCard(context, l10n, tokens, iosOnly: iosOnly, androidReady: androidReady),
        const SizedBox(height: AppSpace.sm),
        _searchesRow(context, l10n, tokens),
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
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            // Own line: sharing the row with the title left the pill ~80 px at
            // 320 px / 200 % and split "Not blocking yet" mid-word
            // (UI/UX Bureau, 7208986773).
            _pill(
              context,
              key: const ValueKey('p12-not-blocked-pill'),
              label: l10n.p12NotBlockingYet,
              icon: Icons.block,
              color: tokens.warn,
            ),
            if (model.isNotEmpty) ...[
              const SizedBox(height: AppSpace.xs),
              Text(
                ltrIsolate(model),
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

  /// A state pill: label plus its own icon, so the state is never carried by
  /// colour alone (UI/UX Bureau, 7204314039).
  Widget _pill(
    BuildContext context, {
    required Key key,
    required String label,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      key: key,
      padding: const EdgeInsetsDirectional.fromSTEB(AppSpace.sm, AppSpace.xxs, AppSpace.sm, AppSpace.xxs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: AppSpace.xxs),
          Flexible(
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
              softWrap: true,
            ),
          ),
        ],
      ),
    );
  }

  /// A11: the one-tap preset for the 13 recommended categories, first row above
  /// the tiles (Karim's 17:06 rule — a shipped feature the design drops stays).
  Widget _recommendedCard(BuildContext context, AppLocalizations l10n, AppTokens tokens) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      key: const ValueKey('p12-recommended-card'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header first, switch beside it only while both fit: at 320 px /
            // 200 % the trailing switch squeezed "Recommended protection" into
            // "Recomme|nded" (UI/UX Bureau, 7208986773). Wrap drops the switch
            // to its own line instead.
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: AppSpace.sm,
              runSpacing: AppSpace.xxs,
              children: [
                Text(
                  l10n.recommendedProtection,
                  style: textTheme.titleMedium?.copyWith(color: tokens.onSurface),
                ),
                Switch.adaptive(
                  key: const ValueKey('p12-recommended-switch'),
                  value: _recommendedOn,
                  onChanged: (v) => _toggleRecommended(context, v),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.xxs),
            Text(
              l10n.recommendedProtectionSubtitle,
              style: textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  /// One category as a tile that says its state in words, not a switch: the
  /// Bureau's row asks for "Blocked" / "Allowed" and no icon-only control.
  Widget _categoryTile(BuildContext context, AppLocalizations l10n, AppTokens tokens, String category) {
    final blocked = webFilter.blockedCategories.contains(category);
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
      for (final c in webFilter.blockedCategories)
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

  /// Recently blocked hosts, in their own card titled by the UI/UX Bureau
  /// (`p12RecentlyBlocked`, 7204314039). The rows come from the reports summary
  /// and the whole card is hidden when the server withholds host names
  /// (SITE_NAMES off, or a guardian without `social`), per the P-12 row's
  /// dependency — an absent list is never drawn as a clean week.
  Widget _blockedCard(BuildContext context, WidgetRef ref, AppLocalizations l10n, AppTokens tokens) {
    final summary = ref.watch(reportSummaryProvider((childId: childId, days: recentDays))).valueOrNull;
    final recent = summary?.blockedDomainsVisible == true ? summary!.topBlockedDomains : null;
    if (recent == null) return const SizedBox.shrink();
    return Card(
      key: const ValueKey('p12-blocked-card'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.p12RecentlyBlocked,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: tokens.onSurface),
            ),
            const SizedBox(height: AppSpace.xs),
            if (recent.isEmpty)
              Text(
                l10n.noBlockedSites(recentDays),
                key: const ValueKey('p12-recently-empty'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
              )
            else
              for (final site in recent) _recentSiteRow(context, l10n, tokens, site),
          ],
        ),
      ),
    );
  }

  Widget _recentSiteRow(BuildContext context, AppLocalizations l10n, AppTokens tokens, BlockedDomain site) {
    return Padding(
      key: ValueKey('p12-recent-${site.domain}'),
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xxs),
      // Wrap, not Row: at 200 % text the Allow button's label is wider than the
      // space left beside the domain, and a Row cannot shrink it. Wrap keeps the
      // two on one line when they fit and stacks them when they do not.
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: AppSpace.sm,
        runSpacing: AppSpace.xxs,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                ltrIsolateHost(site.domain),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.onSurface),
              ),
              Text(
                l10n.blockedTimes(site.count),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.onSurfaceVariant),
              ),
            ],
          ),
          TextButton(
            key: ValueKey('p12-allow-${site.domain}'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => _addSiteDialog(context, exactDomain: site.domain, allowed: true),
            child: Text(l10n.p12AllowSite),
          ),
        ],
      ),
    );
  }

  /// The always-blocked site list. Its title and its dialog share
  /// `p12BlockSiteTitle`, so neither borrows the web-threat alert category.
  Widget _blockedSitesCard(BuildContext context, AppLocalizations l10n, AppTokens tokens) {
    return Card(
      key: const ValueKey('p12-blocked-sites-card'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.p12BlockSiteTitle,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: tokens.onSurface),
            ),
            const SizedBox(height: AppSpace.xs),
            ..._domainList(context, l10n, tokens, allowed: false),
          ],
        ),
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
              l10n.p12AllowSiteTitle,
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
    final domains = allowed ? webFilter.allowedDomains : webFilter.blockedDomains;
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
                label: Text(ltrIsolateHost(d)),
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
        onPressed: () => _addSiteDialog(context, allowed: allowed),
      ),
    ];
  }

  /// A12 kept as one card: Safe search and YouTube Restricted Mode together, the
  /// YouTube line carrying the UI/UX Bureau's binding English verbatim
  /// (#1226, 7201504906). A12's three levels stay reachable here.
  Widget _safeSearchAndYouTubeCard(BuildContext context, AppLocalizations l10n, AppTokens tokens) {
    final wf = webFilter;
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
            // At 320 px / 200 % three horizontal segments split their own words
            // ("Stri|ct", "Mod|erate"). A vertical radio list cannot: each
            // label gets the card's full width (UI/UX Bureau, 7208986773).
            if (MediaQuery.textScalerOf(context).scale(1) >= 1.3)
              RadioGroup<String>(
                groupValue: wf.youtubeRestrictedMode,
                onChanged: (sel) {
                  if (sel == null) return;
                  _updateWebFilter((w) => w.copyWith(youtubeRestrictedMode: sel));
                },
                child: Column(
                  children: [
                    for (final (value, label) in [
                      ('strict', l10n.strict),
                      ('moderate', l10n.moderate),
                      ('off', l10n.off),
                    ])
                      RadioListTile<String>(
                        key: ValueKey('p12-youtube-mode-$value'),
                        value: value,
                        title: Text(label),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      ),
                  ],
                ),
              )
            else
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
  Widget _browsersCard(BuildContext context, AppLocalizations l10n, AppTokens tokens,
      {required bool iosOnly, required bool androidReady}) {
    return Card(
      key: const ValueKey('p12-browsers-card'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // U96 (#650): when the phone has not reported the filter ready, the globe
            // carries the warning colour rather than the ordinary accent.
            Icon(
              Icons.public,
              color: iosOnly
                  ? tokens.onSurfaceVariant
                  : (androidReady ? tokens.primary : tokens.warn),
              size: 20,
            ),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: iosOnly
                  // Wrap, not Row: the pill is icon + label and has no width of
                  // its own, so at 200 % it pushed past the card's right edge.
                  // Wrapping lets the pill drop below the title instead.
                  ? Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: AppSpace.sm,
                      runSpacing: AppSpace.xxs,
                      children: [
                        Text(
                          l10n.tabWebFilter,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.onSurface),
                        ),
                        _pill(
                          context,
                          key: const ValueKey('p12-iphone-not-available'),
                          label: l10n.appsNotYetOnIphone,
                          icon: Icons.phone_iphone,
                          color: tokens.onSurfaceVariant,
                        ),
                      ],
                    )
                  : androidReady
                      ? Text(
                          l10n.searchSafetyEmptyBody,
                          key: const ValueKey('p12-browsers-android'),
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: tokens.onSurfaceVariant),
                        )
                      // U96 (#650, UI/UX 12:46): no new copy. The title is the
                      // screen's own name, and the state is carried by the existing
                      // warn pill on its own line — the same shape as the banner.
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.tabWebFilter,
                              key: const ValueKey('p12-browsers-not-ready'),
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(color: tokens.onSurface),
                            ),
                            const SizedBox(height: AppSpace.xxs),
                            _pill(
                              context,
                              key: const ValueKey('p12-browsers-not-ready-pill'),
                              label: l10n.p12NotBlockingYet,
                              icon: Icons.block,
                              color: tokens.warn,
                            ),
                          ],
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
        onTap: () => context.push('/child/$childId/searches'),
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
          // "Add", not "Save": the dialog adds a site to the list, and the list
          // itself is only persisted by the editor's footer Save. Arabic is the
          // existing `add` value the Bureau approved («إضافة», 7208993286).
          child: Text(l10n.add),
        ),
      ],
    );
  }
}
