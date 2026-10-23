import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

export 'app_localizations.dart';

/// `context.l10n` is the screen-facing entry point for translated copy.
extension AppLocalizationsContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);

  /// BCP-47 tag used by `intl`'s `DateFormat`, so month and weekday names
  /// follow the app locale instead of the host process default.
  String get localeName => Localizations.localeOf(this).toLanguageTag();
}

/// The alert categories the API accepts, in the order `InternalAlertSchema`
/// lists them (`services/api/src/routes/alerts.ts`). This is the one place the
/// app enumerates them: `alertTitleFor` maps every entry, and
/// `localization_test.dart` iterates this list so a category that falls through
/// to the generic title fails the suite instead of showing "Alert"/"تنبيه".
const serverAlertCategories = <String>[
  'web_threat',
  'app_blocked',
  'screen_time_exceeded',
  'geofence',
  'sos',
  'ai_concern',
  'cyberbullying',
  'self_harm',
  'grooming',
  'tamper',
  'vpn_detected',
  'install_request',
  'unknown_contact',
];

/// Human labels for values that cross the API boundary. Unknown values fall
/// back to the raw API value rather than disappearing.
extension AppLocalizationsLabels on AppLocalizations {
  String weekdayShort(int day) => switch (day) {
        1 => weekdayMon,
        2 => weekdayTue,
        3 => weekdayWed,
        4 => weekdayThu,
        5 => weekdayFri,
        6 => weekdaySat,
        7 => weekdaySun,
        _ => '?',
      };

  String consentMethod(String method) => switch (method) {
        'sms_plus' => consentMethodSmsPlus,
        'kba' => consentMethodKba,
        'face_match' => consentMethodFaceMatch,
        'credit_card' => consentMethodCreditCard,
        _ => method,
      };

  String webCategory(String category) => switch (category) {
        'pornography' => categoryPornography,
        'gambling' => categoryGambling,
        'drugs' => categoryDrugs,
        'violence' => categoryViolence,
        'weapons' => categoryWeapons,
        'hate' => categoryHate,
        'self_harm' => categorySelfHarm,
        'dating' => categoryDating,
        'social_media_nsfw' => categorySocialMediaNsfw,
        'chat_random' => categoryChatRandom,
        'proxies_vpn' => categoryProxiesVpn,
        'warez' => categoryWarez,
        'ai_chatbots' => categoryAiChatbots,
        'social_media' => categorySocialMedia,
        'chat' => categoryChat,
        _ => category,
      };

  /// The short label under an alert's title, by **type** — the same 13
  /// categories as [serverAlertCategories], never a vocabulary of its own. A
  /// value the app does not know yet falls back to the raw key, so a new server
  /// category shows up as itself instead of a blank line, and the drift test
  /// fails before one ships.
  String alertCategory(String category) => switch (category) {
        'web_threat' => alertCategoryWebThreat,
        'app_blocked' => alertCategoryAppBlocked,
        'screen_time_exceeded' => alertCategoryScreenTime,
        'geofence' => alertCategoryGeofence,
        'sos' => alertCategorySos,
        'ai_concern' => alertCategoryAiConcern,
        'cyberbullying' => alertCategoryCyberbullying,
        'self_harm' => alertCategorySelfHarm,
        'grooming' => alertCategoryGrooming,
        'tamper' => alertCategoryTamper,
        'vpn_detected' => alertCategoryVpnDetected,
        'install_request' => alertCategoryInstallRequest,
        'unknown_contact' => alertCategoryUnknownContact,
        _ => category,
      };

  /**
   * The title shown for an alert, chosen by **type**, never by matching the server's English text (#159).
   *
   * The titles Karim flagged ("SOS pressed", "Blocked site visited", "Daily limit reached") arrive from the
   * server in English and were rendered verbatim on an Arabic screen. Matching the English string would break
   * the moment the server reworded one, and would leave every new type in English anyway — so the app maps
   * every category in [serverAlertCategories] to a translated title.
   *
   * A category the app does not know yet is the one case where the two locales differ: English shows the
   * server's own [serverTitle] (it is already English, and it beats a bare "Alert"), any other locale shows
   * the translated generic, so English never leaks onto an Arabic screen. Hence [isEnglish].
   */
  String alertTitleFor(String category, String serverTitle, {required bool isEnglish}) => switch (category) {
        'web_threat' => alertTitleBlockedSite,
        'app_blocked' => alertTitleAppBlocked,
        'screen_time_exceeded' => alertTitleDailyLimit,
        'geofence' => alertTitleGeofence,
        'sos' => alertTitleSos,
        'ai_concern' => alertTitleAiConcern,
        'cyberbullying' => alertTitleCyberbullying,
        'self_harm' => alertTitleSelfHarm,
        'grooming' => alertTitleGrooming,
        'tamper' => alertTitleTamper,
        'vpn_detected' => alertTitleVpnDetected,
        'install_request' => alertTitleInstallRequest,
        'unknown_contact' => alertTitleUnknownContact,
        _ => isEnglish ? serverTitle : alertTitleGeneric,
      };

  /// Risk labels for the `concernTypes` tags on search results and social rows.
  ///
  /// The vocabulary is the AI engine's `CATEGORIES` (`services/ai-engine/model.py`, minus `safe`) plus the
  /// local search patterns in `services/api/src/routes/content.ts`. A tag with no label falls back to the raw
  /// key, so a new server tag shows up as itself instead of a blank chip.
  String searchRiskCategory(String tag) => switch (tag.trim().toLowerCase()) {
        'self_harm' => riskSelfHarm,
        'substance_use' => riskSubstanceUse,
        'substance_abuse' => riskSubstanceAbuse,
        'adult_content' => riskAdultContent,
        'sexual_content' || 'explicit_content' => riskSexualContent,
        'cyberbullying' => riskCyberbullying,
        'grooming' || 'grooming_risk' => riskGrooming,
        'violence' => riskViolence,
        'hate_speech' => riskHateSpeech,
        'ai_concern' => riskAiConcern,
        _ => tag,
      };

  String severityName(String severity) => switch (severity) {
        'critical' => severityCritical,
        'warning' => severityWarning,
        'info' => severityInfo,
        _ => severity,
      };

  String commandType(String type) => switch (type) {
        'lock' => commandLock,
        'unlock' => commandUnlock,
        'ring' => commandRing,
        'stop_ring' => commandStopRing,
        'sos_clear' => commandClearSos,
        'pause' => commandPauseDevice,
        'resume' => commandResumeDevice,
        'pause_internet' => commandPauseInternet,
        'resume_internet' => commandResumeInternet,
        'bonus_time' => commandBonusTime,
        'wind_down' => commandWindDown,
        'locate_now' => commandLocateNow,
        'rules_updated' => commandRulesUpdated,
        'consent_granted' => commandConsentGranted,
        'consent_revoked' => commandConsentRevoked,
        _ => type.replaceAll('_', ' '),
      };

  String commandStatus(String status) => switch (status) {
        'acked' => statusConfirmed,
        'delivered' => statusDelivered,
        'failed' => statusFailed,
        'expired' => statusExpired,
        _ => statusPending,
      };
}
