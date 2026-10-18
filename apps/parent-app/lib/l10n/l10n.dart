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

  String alertCategory(String category) => switch (category) {
        'sos' => alertCategorySos,
        'web_filter' => alertCategoryWebFilter,
        'screen_time' => alertCategoryScreenTime,
        'install_request' => alertCategoryInstallRequest,
        'social_concern' => alertCategorySocialConcern,
        'location' => alertCategoryLocation,
        'device' => alertCategoryDevice,
        'safety' => alertCategorySafety,
        _ => category,
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
