// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'OSRA';

  @override
  String get cancel => 'Cancel';

  @override
  String get save => 'Save';

  @override
  String get add => 'Add';

  @override
  String get continueLabel => 'Continue';

  @override
  String get close => 'Close';

  @override
  String get tryAgain => 'Try again';

  @override
  String get retry => 'Retry';

  @override
  String get dismiss => 'Dismiss';

  @override
  String get system => 'System';

  @override
  String get light => 'Light';

  @override
  String get dark => 'Dark';

  @override
  String get english => 'English';

  @override
  String get arabic => 'العربية';

  @override
  String get unknown => 'Unknown';

  @override
  String get never => 'never';

  @override
  String get timeUnknown => 'time unknown';

  @override
  String get saving => 'Saving…';

  @override
  String minutesShort(int minutes) {
    return '$minutes min';
  }

  @override
  String get appTagline => 'أسرة — parental control for your family';

  @override
  String get serverLabel => 'Server';

  @override
  String get serverHint => 'http://host:port';

  @override
  String serverShown(String url) {
    return 'Server: $url';
  }

  @override
  String get invalidServer =>
      'Enter a valid server, e.g. http://192.168.1.5:3000';

  @override
  String get emailLabel => 'Email';

  @override
  String get passwordLabel => 'Password';

  @override
  String get mfaCodeLabel => 'Authentication code (if MFA is on)';

  @override
  String get signIn => 'Sign in';

  @override
  String get createAccount => 'Create account';

  @override
  String get familyNameLabel => 'Family name';

  @override
  String get yourNameLabel => 'Your name';

  @override
  String get regionLabel => 'Region';

  @override
  String get regionUS => 'United States';

  @override
  String get regionEU => 'European Union';

  @override
  String get regionUK => 'United Kingdom';

  @override
  String get regionOther => 'Other';

  @override
  String get register => 'Register';

  @override
  String get familyMapTooltip => 'Family map';

  @override
  String get alertsTooltip => 'Alerts';

  @override
  String get familyMembersMenu => 'Family members';

  @override
  String get appearanceMenu => 'Appearance';

  @override
  String get digestPreferencesMenu => 'Digest preferences';

  @override
  String get signOutTooltip => 'Sign out';

  @override
  String familyLoadFailed(String error) {
    return 'Failed to load family: $error';
  }

  @override
  String get noChildrenYet => 'No children yet — tap \"Add child\"';

  @override
  String get addChild => 'Add child';

  @override
  String get statusOnline => 'online';

  @override
  String get statusOffline => 'offline';

  @override
  String get noLocationYet => 'No location yet';

  @override
  String get screenTime => 'Screen time';

  @override
  String screenTimeValue(int minutes, String limit) {
    return '$minutes / $limit min';
  }

  @override
  String liveActivityToday(String app, int minutes) {
    return '$app · ${minutes}m today';
  }

  @override
  String wellbeingScore(int score) {
    return 'Wellbeing $score/100';
  }

  @override
  String get wellbeingUsage => 'usage';

  @override
  String get wellbeingSocial => 'social';

  @override
  String get wellbeingSafety => 'safety';

  @override
  String get paused => 'Paused';

  @override
  String get internet => 'Internet';

  @override
  String pauseInternetTitle(String name) {
    return 'Pause internet for $name?';
  }

  @override
  String resumeInternetTitle(String name) {
    return 'Resume internet for $name?';
  }

  @override
  String get pauseInternetBody => 'Educational apps keep working.';

  @override
  String get resumeInternetBody => 'All apps and sites work again.';

  @override
  String get pause => 'Pause';

  @override
  String get resume => 'Resume';

  @override
  String internetChangeFailed(String error) {
    return 'Internet change failed: $error';
  }

  @override
  String get parentalConsent => 'Parental consent';

  @override
  String get childDetails => 'Child details';

  @override
  String get consentNotice =>
      'Verifiable parental consent is required before adding a child (COPPA/GDPR-K).';

  @override
  String get consentMethodLabel => 'Consent method';

  @override
  String get consentMethodSmsPlus => 'SMS +';

  @override
  String get consentMethodKba => 'Knowledge-based questions';

  @override
  String get consentMethodFaceMatch => 'Face match';

  @override
  String get consentMethodCreditCard => 'Credit card';

  @override
  String get jurisdictionLabel => 'Jurisdiction';

  @override
  String get childNameLabel => 'Child name';

  @override
  String get birthYearLabel => 'Birth year';

  @override
  String get childFallback => 'Child';

  @override
  String get tabOverview => 'Overview';

  @override
  String get tabApps => 'Apps';

  @override
  String get tabSocial => 'Social';

  @override
  String get tabLocation => 'Location';

  @override
  String get tabAlerts => 'Alerts';

  @override
  String get reportsTooltip => 'Reports';

  @override
  String get searchSafetyTooltip => 'Search & web safety';

  @override
  String get editRules => 'Edit rules';

  @override
  String bornYear(int year) {
    return 'Born $year';
  }

  @override
  String get socialMonitoringTitle => 'Social monitoring';

  @override
  String get devices => 'Devices';

  @override
  String get pairADevice => 'Pair a device';

  @override
  String get noDevicesRegistered => 'No devices registered';

  @override
  String lastSeenLabel(String time) {
    return 'Last seen: $time';
  }

  @override
  String get deliveryStatus => 'Delivery status';

  @override
  String get ring => 'Ring';

  @override
  String get lock => 'Lock';

  @override
  String get unlock => 'Unlock';

  @override
  String get pauseNet => 'Pause net';

  @override
  String get resumeNet => 'Resume net';

  @override
  String get checkingCommandDelivery => 'Checking command delivery…';

  @override
  String get commandDeliveryUnavailable => 'Command delivery unavailable';

  @override
  String get noCommandsYet => 'No commands yet';

  @override
  String latestCommand(String type, String status, String time) {
    return 'Latest: $type · $status · $time';
  }

  @override
  String get bonusTime => 'Bonus time';

  @override
  String get extraScreenTimeToday => 'Extra screen time today only';

  @override
  String bonusGranted(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '+$minutes extra minutes granted today',
      one: '+1 extra minute granted today',
    );
    return '$_temp0';
  }

  @override
  String bonusFailed(String error) {
    return 'Bonus failed: $error';
  }

  @override
  String get windDown => 'Wind down';

  @override
  String get windDownBody =>
      'The device shows a soft bedtime warning, then locks.';

  @override
  String get windDownSubtitle => 'Soft warning, then the screen locks';

  @override
  String windDownConfirm(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: 'Screen will lock in $minutes minutes on the device',
      one: 'Screen will lock in 1 minute on the device',
    );
    return '$_temp0';
  }

  @override
  String windDownFailed(String error) {
    return 'Wind down failed: $error';
  }

  @override
  String commandQueued(String command, String device) {
    return '$command queued for $device — the device has not confirmed it yet.';
  }

  @override
  String netQueued(String action, String device) {
    return '$action queued for $device — the device has not confirmed it yet.';
  }

  @override
  String commandFailed(String error) {
    return 'Command failed: $error';
  }

  @override
  String rulesLoadFailed(String error) {
    return 'Failed to load rules: $error';
  }

  @override
  String get noPerAppRules => 'No per-app rules';

  @override
  String get appActionBlock => 'Block';

  @override
  String get appActionTimeLimit => 'Time limit';

  @override
  String get appActionAllow => 'Allow';

  @override
  String locationLoadFailed(String error) {
    return 'Failed to load location: $error';
  }

  @override
  String get noLocationReported => 'No location reported yet';

  @override
  String accuracyLabel(int meters, String time) {
    return 'Accuracy ±$meters m · $time';
  }

  @override
  String get mapPreview => 'Map preview';

  @override
  String locationHistoryLoadFailed(String error) {
    return 'Failed to load history: $error';
  }

  @override
  String get noLocationHistoryToday => 'No location history for today';

  @override
  String get todaysRoute => 'Today\'s route';

  @override
  String get back15Tooltip => 'Back 15 min';

  @override
  String get forward15Tooltip => 'Forward 15 min';

  @override
  String get accuracyUnknown => 'accuracy unknown';

  @override
  String alertsLoadFailed(String error) {
    return 'Failed to load alerts: $error';
  }

  @override
  String get noRecentAlerts => 'No recent alerts';

  @override
  String get acknowledgeTooltip => 'Acknowledge';

  @override
  String ageRating(String rating) {
    return 'Age rating: $rating';
  }

  @override
  String get risks => 'Risks';

  @override
  String get saferAlternatives => 'Safer alternatives';

  @override
  String get noInsightsYet => 'No insights for this app yet';

  @override
  String insightsLoadFailed(String error) {
    return 'Failed to load insights: $error';
  }

  @override
  String get commandLock => 'Lock';

  @override
  String get commandUnlock => 'Unlock';

  @override
  String get commandRing => 'Ring';

  @override
  String get commandStopRing => 'Stop ringing';

  @override
  String get commandClearSos => 'Clear SOS';

  @override
  String get commandPauseDevice => 'Pause device';

  @override
  String get commandResumeDevice => 'Resume device';

  @override
  String get commandPauseInternet => 'Pause internet';

  @override
  String get commandResumeInternet => 'Resume internet';

  @override
  String get commandBonusTime => 'Bonus time';

  @override
  String get commandWindDown => 'Wind down';

  @override
  String get commandLocateNow => 'Locate now';

  @override
  String get commandRulesUpdated => 'Rules update';

  @override
  String get commandConsentGranted => 'Consent granted';

  @override
  String get commandConsentRevoked => 'Consent revoked';

  @override
  String get statusConfirmed => 'Confirmed by device';

  @override
  String get statusDelivered => 'Delivered — awaiting device confirmation';

  @override
  String get statusFailed => 'Failed on device';

  @override
  String get statusExpired => 'Expired before delivery';

  @override
  String get statusPending => 'Pending — waiting for the device';

  @override
  String get alertsTitle => 'Alerts';

  @override
  String get noAlertsYet => 'No alerts yet';

  @override
  String get loadMore => 'Load more';

  @override
  String acknowledgeFailed(String error) {
    return 'Acknowledge failed: $error';
  }

  @override
  String categoryLabel(String category) {
    return 'Category: $category';
  }

  @override
  String severityLabel(String severity) {
    return 'Severity: $severity';
  }

  @override
  String timeLabel(String time) {
    return 'Time: $time';
  }

  @override
  String get allowAction => 'Allow';

  @override
  String get blockThisApp => 'Block this app';

  @override
  String get allowedSnack => 'Allowed';

  @override
  String get appBlockedSnack => 'App blocked';

  @override
  String blockFailed(String error) {
    return 'Block failed: $error';
  }

  @override
  String get severityCritical => 'Critical';

  @override
  String get severityWarning => 'Warning';

  @override
  String get severityInfo => 'Info';

  @override
  String get alertCategorySos => 'SOS';

  @override
  String get alertCategoryWebFilter => 'Web filter';

  @override
  String get alertCategoryScreenTime => 'Screen time';

  @override
  String get alertCategoryInstallRequest => 'App install request';

  @override
  String get alertCategorySocialConcern => 'Social concern';

  @override
  String get alertCategoryLocation => 'Location';

  @override
  String get alertCategoryDevice => 'Device';

  @override
  String get alertCategorySafety => 'Safety';

  @override
  String get tabScreenTime => 'Screen time';

  @override
  String get tabWebFilter => 'Web filter';

  @override
  String get tabRoutines => 'Routines';

  @override
  String dailyLimit(int minutes) {
    return 'Daily limit: $minutes min';
  }

  @override
  String weekendLimit(int minutes) {
    return 'Weekend limit: $minutes min';
  }

  @override
  String get bedtime => 'Bedtime';

  @override
  String get starts => 'Starts';

  @override
  String get ends => 'Ends';

  @override
  String get schoolHours => 'School hours';

  @override
  String get weekdayMon => 'Mon';

  @override
  String get weekdayTue => 'Tue';

  @override
  String get weekdayWed => 'Wed';

  @override
  String get weekdayThu => 'Thu';

  @override
  String get weekdayFri => 'Fri';

  @override
  String get weekdaySat => 'Sat';

  @override
  String get weekdaySun => 'Sun';

  @override
  String get recommendedProtection => 'Recommended protection';

  @override
  String get recommendedProtectionSubtitle =>
      'Block all 13 recommended categories';

  @override
  String get disablingRecommended =>
      'Disabling recommended categories reduces protection. Continue?';

  @override
  String get blockedCategories => 'Blocked categories';

  @override
  String get categoryPornography => 'Pornography';

  @override
  String get categoryGambling => 'Gambling';

  @override
  String get categoryDrugs => 'Drugs';

  @override
  String get categoryViolence => 'Violence';

  @override
  String get categoryWeapons => 'Weapons';

  @override
  String get categoryHate => 'Hate speech';

  @override
  String get categorySelfHarm => 'Self-harm';

  @override
  String get categoryDating => 'Dating';

  @override
  String get categorySocialMediaNsfw => 'NSFW social media';

  @override
  String get categoryChatRandom => 'Random chat';

  @override
  String get categoryProxiesVpn => 'Proxies & VPN';

  @override
  String get categoryWarez => 'Piracy';

  @override
  String get categoryAiChatbots => 'AI chatbots';

  @override
  String get categorySocialMedia => 'Social media';

  @override
  String get categoryChat => 'Chat';

  @override
  String get allowedDomainsLabel => 'Allowed domains (comma-separated)';

  @override
  String get blockedDomainsLabel => 'Blocked domains (comma-separated)';

  @override
  String get enforceSafeSearch => 'Enforce SafeSearch';

  @override
  String get youtubeRestrictedMode => 'YouTube Restricted Mode';

  @override
  String get youtubeRestrictedDesc =>
      'Filters out potentially mature content on YouTube across child devices.';

  @override
  String get strict => 'Strict';

  @override
  String get moderate => 'Moderate';

  @override
  String get off => 'Off';

  @override
  String get alwaysAllowed => 'Always allowed';

  @override
  String get alwaysAllowedDesc =>
      'These apps stay open during bedtime, school time, pause and routines.';

  @override
  String get noAlwaysAllowedApps => 'No always-allowed apps yet';

  @override
  String get addApp => 'Add app';

  @override
  String get addAppRule => 'Add app rule';

  @override
  String get addAlwaysAllowedTitle => 'Add always-allowed app';

  @override
  String get appNameLabel => 'App name';

  @override
  String get packageIdLabel => 'Package ID (e.g. com.example.app)';

  @override
  String get limitPerDayLabel => 'Limit (minutes/day)';

  @override
  String get addRoutine => 'Add routine';

  @override
  String get editRoutine => 'Edit routine';

  @override
  String get nameLabel => 'Name';

  @override
  String startTimeButton(String time) {
    return 'Start $time';
  }

  @override
  String endTimeButton(String time) {
    return 'End $time';
  }

  @override
  String get blockedAppsLabel => 'Blocked apps (comma-separated)';

  @override
  String get allowedAppsLabel => 'Allowed apps (comma-separated)';

  @override
  String get rulesSaved => 'Rules saved';

  @override
  String get reportsTitle => 'Reports';

  @override
  String get screenTimeWebHistoryTooltip => 'Screen time & web history';

  @override
  String get sevenDays => '7 days';

  @override
  String get thirtyDays => '30 days';

  @override
  String reportLoadFailed(String error) {
    return 'Failed to load report: $error';
  }

  @override
  String noActivityDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'No activity recorded in the last $days days',
      one: 'No activity recorded in the last day',
    );
    return '$_temp0';
  }

  @override
  String get appUsage => 'App usage';

  @override
  String totalAverage(int total, int avg) {
    return 'Total $total min · avg $avg min/day';
  }

  @override
  String get noAppUsage => 'No app usage recorded';

  @override
  String get webSection => 'Web';

  @override
  String urlVisits(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count URL visits',
      one: '1 URL visit',
      zero: 'No URL visits',
    );
    return '$_temp0';
  }

  @override
  String get noBlockedDomains => 'No blocked domains';

  @override
  String blockedTimes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count× blocked',
      one: 'blocked once',
    );
    return '$_temp0';
  }

  @override
  String get safeSearchForced => 'YouTube search is forced to SafeSearch';

  @override
  String get restrictedModeNote =>
      'Restricted Mode needs HTTPS inspection on the child PC (see guide)';

  @override
  String get socialAndCommunication => 'Social & communication';

  @override
  String socialConcerns(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count social concerns',
      one: '1 social concern',
      zero: 'No social concerns',
    );
    return '$_temp0';
  }

  @override
  String callsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count calls',
      one: '1 call',
      zero: 'No calls',
    );
    return '$_temp0';
  }

  @override
  String smsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count SMS',
      one: '1 SMS',
      zero: 'No SMS',
    );
    return '$_temp0';
  }

  @override
  String get screenTimeWebTitle => 'Screen time & web';

  @override
  String daysShort(int days) {
    return '${days}d';
  }

  @override
  String get couldNotLoadScreenTime => 'Could not load screen time';

  @override
  String noScreenTimeData(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'No screen time data in the last $days days',
      one: 'No screen time data in the last day',
    );
    return '$_temp0';
  }

  @override
  String noScreenTimeRecorded(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'No screen time recorded in the last $days days',
      one: 'No screen time recorded in the last day',
    );
    return '$_temp0';
  }

  @override
  String totalOverDays(int total, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days',
      one: '1 day',
    );
    return 'Total $total min over $_temp0';
  }

  @override
  String fewerDaysReturned(int returned, int requested) {
    return 'Only $returned of the $requested requested days were returned; showing those days as-is.';
  }

  @override
  String get dayByDay => 'Day by day';

  @override
  String get browsingHistory => 'Browsing history';

  @override
  String get blockedOnly => 'Blocked only';

  @override
  String get showLabel => 'Show';

  @override
  String get couldNotLoadBrowsing => 'Could not load browsing history';

  @override
  String noBlockedSites(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'No blocked sites in the last $days days',
      one: 'No blocked sites in the last day',
    );
    return '$_temp0';
  }

  @override
  String noBrowsingHistory(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'No browsing history in the last $days days',
      one: 'No browsing history in the last day',
    );
    return '$_temp0';
  }

  @override
  String showingLatestVisits(int limit) {
    return 'Showing the latest $limit visits — raise the limit to see more.';
  }

  @override
  String get blocked => 'Blocked';

  @override
  String get allowed => 'Allowed';

  @override
  String dayTooltip(String date, int minutes) {
    return '$date: $minutes min';
  }

  @override
  String get scanQr => 'Scan this QR code with the OSRA child app.';

  @override
  String get typeSixDigit =>
      'If the camera cannot scan it, type the 6-digit code below on the child device.';

  @override
  String get codeExpired => 'Code expired';

  @override
  String get generateNewCode => 'Generate a new code to keep pairing.';

  @override
  String pairingQrSemantics(String code) {
    return 'Pairing QR code for $code';
  }

  @override
  String expiresIn(String time) {
    return 'Expires in $time';
  }

  @override
  String get regenerate => 'Regenerate';

  @override
  String get copyCode => 'Copy code';

  @override
  String get codeCopied => 'Code copied';

  @override
  String codeWorksOnce(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: 'The code works once and expires after $minutes minutes.',
      one: 'The code works once and expires after 1 minute.',
    );
    return '$_temp0';
  }

  @override
  String get pairCodeError =>
      'The server did not return a usable pairing code. Try Regenerate.';

  @override
  String get pairCreateError =>
      'Could not create a pairing code. Check the connection and try again.';

  @override
  String get appearanceTitle => 'Appearance';

  @override
  String get themeLabel => 'Theme';

  @override
  String get appearanceDesc =>
      'System follows this device. Light or Dark overrides it for OSRA only.';

  @override
  String followingDevice(String mode) {
    return 'Following the device (currently $mode).';
  }

  @override
  String get lightAlwaysOn => 'Light theme is always on.';

  @override
  String get darkAlwaysOn => 'Dark theme is always on.';

  @override
  String get languageLabel => 'Language';

  @override
  String get languageDesc =>
      'System follows this device. English or Arabic overrides it for OSRA only.';

  @override
  String followingLanguage(String language) {
    return 'Following the device (currently $language).';
  }

  @override
  String get englishAlwaysOn => 'English is always on.';

  @override
  String get arabicAlwaysOn => 'Arabic is always on.';

  @override
  String get monitoring => 'Monitoring';

  @override
  String get monitoringSaved => 'Monitoring saved';

  @override
  String saveFailed(String error) {
    return 'Save failed: $error';
  }

  @override
  String get saveMonitoring => 'Save monitoring';

  @override
  String get concerns => 'Concerns';

  @override
  String get vaultTrustCopy =>
      'Snippets are encrypted with your family key before leaving the device and stored encrypted on your server.';

  @override
  String get noConcernsDetected => 'No concerns detected';

  @override
  String get unknownContact => 'Unknown contact';

  @override
  String get unknownApp => 'Unknown app';

  @override
  String get noPreviewAvailable => 'No preview available';

  @override
  String get viewInDecryptionVault => 'View in Decryption Vault';

  @override
  String get socialMessage => 'Social message';

  @override
  String get callsAndTexts => 'Calls & texts';

  @override
  String get iosNoCallMonitoring =>
      'iOS does not support call/text monitoring.';

  @override
  String get noCallsOrTexts => 'No calls or texts yet';

  @override
  String get unknownNumber => 'Unknown number';

  @override
  String get trustedContacts => 'Trusted contacts';

  @override
  String get trustedContactsDesc => 'Numbers here never raise social concerns.';

  @override
  String get phoneNumberLabel => 'Phone number';

  @override
  String get saveAllowlist => 'Save allowlist';

  @override
  String get allowlistSaved => 'Allowlist saved';

  @override
  String get relativeJustNow => 'just now';

  @override
  String relativeMinutesAgo(int count) {
    return '${count}m ago';
  }

  @override
  String relativeHoursAgo(int count) {
    return '${count}h ago';
  }

  @override
  String relativeDaysAgo(int count) {
    return '${count}d ago';
  }

  @override
  String get decryptedVaultContent => 'Decrypted Vault Content';

  @override
  String get encryptedFamilyVault => 'Encrypted Family Vault';

  @override
  String get vaultEncryptionDesc =>
      'Protected by AES-256-GCM encryption. Decrypted on-demand for authenticated guardians only.';

  @override
  String get decryptedContent => 'Decrypted content';

  @override
  String get copy => 'Copy';

  @override
  String get contentCopied => 'Content copied to clipboard';

  @override
  String get noPreviewContent => 'No preview content available';

  @override
  String get detectedConcernTypes => 'Detected concern types';

  @override
  String get commandDeliveryTitle => 'Command delivery';

  @override
  String get couldNotLoadChild => 'Could not load this child';

  @override
  String get noDevicesForChild => 'No devices registered for this child';

  @override
  String get deliveryExplanation =>
      'A command is confirmed only when the child device reports back. Delivered means the device collected it; it has not confirmed it ran.';

  @override
  String get couldNotLoadCommandHistory => 'Could not load command history';

  @override
  String createdEvent(String time) {
    return 'Created $time';
  }

  @override
  String deliveredEvent(String time) {
    return 'Delivered $time';
  }

  @override
  String confirmedEvent(String time) {
    return 'Confirmed $time';
  }

  @override
  String get mfaMenu => 'Two-step verification';

  @override
  String get mfaSettingsTitle => 'Two-step verification';

  @override
  String get mfaStatusOn => 'On';

  @override
  String get mfaStatusOff => 'Off';

  @override
  String get mfaSettingsStatusOn => 'Two-step verification is on.';

  @override
  String get mfaSettingsStatusOff => 'Two-step verification is off.';

  @override
  String get mfaSettingsExplanation =>
      'When it is on, signing in needs a code from your authenticator app as well as your password.';

  @override
  String get mfaSetupAuthenticator => 'Set up authenticator';

  @override
  String get mfaReplaceAuthenticator => 'Replace authenticator';

  @override
  String get mfaRecoveryCodesTitle => 'Recovery codes';

  @override
  String get mfaRecoveryCodesExplanation =>
      'Ten single-use codes. Each one lets you sign in once if you lose your authenticator.';

  @override
  String get mfaRegenerateCodes => 'Generate new recovery codes';

  @override
  String get mfaRegenerateWarning =>
      'Generating new codes replaces the old ones. The old codes stop working immediately.';

  @override
  String get mfaSessionNotice =>
      'Your session ended when two-step verification was turned on. Sign in again with your new authenticator.';

  @override
  String get mfaReauthTitle => 'Confirm it is you';

  @override
  String get mfaReauthExplanation =>
      'Enter your password or a current authenticator code.';

  @override
  String get mfaReauthCode => 'Authenticator code';

  @override
  String get mfaReauthRequired =>
      'Enter your password or a current authenticator code.';

  @override
  String get mfaReauthFailed => 'That password or code was not accepted.';

  @override
  String get mfaEnrollTitle => 'Set up two-step verification';

  @override
  String get mfaEnrollIntro =>
      'Scan this code with an authenticator app, then enter the six-digit code it shows.';

  @override
  String get mfaEnrollManual => 'Cannot scan? Enter this key in the app:';

  @override
  String get mfaSecretCopied => 'Key copied';

  @override
  String get mfaSecretSemantics => 'Authenticator setup key';

  @override
  String get mfaEnrollAfterRecovery =>
      'Set up a new authenticator for this account. Until you verify it, two-step verification stays off.';

  @override
  String get mfaCodeFieldLabel => 'Six-digit code';

  @override
  String get mfaVerify => 'Turn on two-step verification';

  @override
  String get mfaVerifying => 'Checking…';

  @override
  String get mfaInvalidCode =>
      'That code was not accepted. Check the clock on your phone and try the next code.';

  @override
  String get mfaNotEnrolled =>
      'Start the setup again — no authenticator is enrolled yet.';

  @override
  String get mfaSessionError => 'Your session ended. Sign in again and retry.';

  @override
  String get mfaRecoveryExpired =>
      'This recovery session has ended. Start recovery again.';

  @override
  String get mfaTooManyAttempts =>
      'Too many attempts. Wait a minute and try again.';

  @override
  String get mfaNetworkError =>
      'Could not reach the server. Check your connection and try again.';

  @override
  String get mfaRequestFailed => 'That did not work. Try again.';

  @override
  String get mfaEnrollError =>
      'Could not create an authenticator key. Try again.';

  @override
  String get mfaNoRecoveryCodes =>
      'The server did not return recovery codes. Try again before leaving this screen.';

  @override
  String get mfaCodesTitle => 'Save your recovery codes';

  @override
  String get mfaCodesIntro =>
      'These ten codes will not be shown again. Write them down or copy them somewhere safe.';

  @override
  String get mfaCopyAllCodes => 'Copy all codes';

  @override
  String get mfaCodesCopied => 'Recovery codes copied';

  @override
  String get mfaCodesSavedCheckbox => 'I have saved these codes';

  @override
  String get mfaCodesConfirm => 'I have saved these codes';

  @override
  String get mfaCodesLeaveTitle => 'Leave without saving?';

  @override
  String get mfaCodesLeaveBody =>
      'These codes cannot be shown again. If you leave now, you will have to generate a new batch from settings.';

  @override
  String get mfaCodesStay => 'Stay';

  @override
  String get mfaCodesLeave => 'Leave anyway';

  @override
  String mfaCodesIssuedAt(String date) {
    return 'Created $date';
  }

  @override
  String mfaRecoveryCodeSemantics(int index) {
    return 'Recovery code $index';
  }

  @override
  String get mfaRecoveryLink => 'Lost your authenticator?';

  @override
  String get mfaRecoveryTitle => 'Recover your account';

  @override
  String get mfaRecoveryIntro =>
      'Enter the email, password and one unused recovery code for this account. This turns off two-step verification so you can set it up again.';

  @override
  String get mfaRecoveryCodeLabel => 'Recovery code';

  @override
  String get mfaRecoveryCodeHint => 'XXXX-XXXX-XXXX-XXXX';

  @override
  String get mfaRecoverySubmit => 'Recover account';

  @override
  String get mfaRecoveryInvalid =>
      'The email, password or recovery code is incorrect.';

  @override
  String get mfaRecoveryNoToken =>
      'The server did not return a recovery session. Try again.';

  @override
  String get mfaFieldsRequired => 'Fill in email, password and recovery code.';
}
