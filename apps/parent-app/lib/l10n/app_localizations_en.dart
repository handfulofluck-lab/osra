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
  String get registerFieldsHint =>
      'Uses the email and password above. The password needs at least 12 characters.';

  @override
  String get registerPasswordTooShort =>
      'The password is too short. Use at least 12 characters.';

  @override
  String get registerNamesRequired => 'Enter your name and a family name.';

  @override
  String get registerEmailTaken =>
      'An account with this email already exists. Sign in instead, or use another email.';

  @override
  String get authEmailInvalid => 'Enter a valid email address.';

  @override
  String get authFieldsInvalid =>
      'Some details were not accepted. Check the form and try again.';

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
  String screenTimeValue(int minutes, int limit) {
    String _temp0 = intl.Intl.pluralLogic(
      limit,
      locale: localeName,
      other: '$limit min',
      zero: '— min',
    );
    return '$minutes / $_temp0';
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
      'Before you add a child, we need to confirm that you are their parent or guardian.';

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
  String commandErrorForbidden(String command, String device) {
    return 'You don\'t have permission to send $command to $device. Your family owner can give you access.';
  }

  @override
  String commandErrorRateLimited(String command, String device) {
    return '$command was not sent to $device: too many requests right now. Try again in a minute.';
  }

  @override
  String commandRefusedBackgroundLocation(String command, String device) {
    return '$command was not sent to $device: the phone has not granted “Allow all the time” location, so Locate and geofence alerts cannot reach it. Ask your child to open OSRA and grant it.';
  }

  @override
  String commandRefusedLocationPermission(String command, String device) {
    return '$command was not sent to $device: the phone has no location permission. Ask your child to open OSRA and grant location.';
  }

  @override
  String get commandRefusedLockScreen =>
      'The lock can\'t hold on your child\'s phone: turn on OSRA\'s accessibility service there.';

  @override
  String get commandRefusedWebFilter =>
      'The web filter is not set up on your child\'s phone, so the internet was not paused.';

  @override
  String get commandRefusedUnsupportedCommand =>
      'This command needs a newer OSRA on your child\'s phone.';

  @override
  String commandRefusedNotSupported(String command, String device) {
    return '$command isn\'t available on $device: this phone or app version cannot do it, so nothing was sent.';
  }

  @override
  String get commandRefusedInvalidPayload =>
      'The phone rejected this command\'s settings.';

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
  String get readPermissionRequired =>
      'Your family owner can give you access to this.';

  @override
  String get readErrorConsentMissing =>
      'This change was not saved: this child has no active consent, so monitoring is paused. Open Parental consent on the child\'s page to see why.';

  @override
  String get readErrorConsentRegion =>
      'This change was not saved: this child\'s consent was given for a different region than your family\'s. Open Parental consent on the child\'s page for details.';

  @override
  String get familyDone => 'Done';

  @override
  String get familyMembersTitle => 'Family members';

  @override
  String get familyParentsHeading => 'Parents';

  @override
  String get familyNoParents => 'No parents found';

  @override
  String get familyInviteMember => 'Invite member';

  @override
  String get familyPendingInvites => 'Pending invites';

  @override
  String familyInvitesLoadFailed(String error) {
    return 'Failed to load invites: $error';
  }

  @override
  String get familyNoPendingInvites => 'No pending invites';

  @override
  String get familyRevokeInvite => 'Revoke invite';

  @override
  String familyInviteRevoked(String email) {
    return 'Invite to $email revoked';
  }

  @override
  String familyRevokeFailed(String error) {
    return 'Revoke failed: $error';
  }

  @override
  String get familyEnterEmail => 'Enter an email address';

  @override
  String get familyInviteSent => 'Invite sent';

  @override
  String get familyEmailLabel => 'Email';

  @override
  String get familyRoleLabel => 'Role';

  @override
  String get familyRoleCoParent => 'Co-parent';

  @override
  String get familyRoleGuardian => 'Guardian';

  @override
  String get familyPermissions => 'Permissions';

  @override
  String get listSeparator => ', ';

  @override
  String familyInviteSentTo(String email) {
    return 'Invite sent to $email.';
  }

  @override
  String get familyTokenExplanation =>
      '(test build: share this token — the invited parent registers, then POSTs accept with it)';

  @override
  String get familySendInvite => 'Send invite';

  @override
  String get familyCopyToken => 'Copy token';

  @override
  String get familyTokenCopied => 'Token copied';

  @override
  String get familyPermRules => 'Rules';

  @override
  String get familyPermLocation => 'Location';

  @override
  String get familyPermAlerts => 'Alerts';

  @override
  String get familyPermSocial => 'Social';

  @override
  String get familyMapTitle => 'Family map';

  @override
  String get familyMapAddGeofence => 'Add geofence';

  @override
  String familyMapLastUpdate(String time) {
    return 'Last update: $time';
  }

  @override
  String get familyMapLastUpdateUnknown => 'unknown';

  @override
  String familyMapBattery(int pct) {
    return 'Battery: $pct%';
  }

  @override
  String get familyMapRing => 'Ring device';

  @override
  String get familyMapLock => 'Lock device';

  @override
  String familyMapRingQueued(String model) {
    return 'Ring queued for $model — the device has not confirmed it yet.';
  }

  @override
  String familyMapLockQueued(String model) {
    return 'Lock queued for $model — the device has not confirmed it yet.';
  }

  @override
  String familyMapCommandFailed(String error) {
    return 'Command failed: $error';
  }

  @override
  String get familyMapNoChildren => 'No children to show';

  @override
  String get familyMapEnterLabel => 'Enter a label';

  @override
  String familyMapGeofenceAdded(String name) {
    return 'Geofence \"$name\" added';
  }

  @override
  String get familyMapChild => 'Child';

  @override
  String get familyMapLabelField => 'Label (e.g. School)';

  @override
  String familyMapRadius(int meters) {
    return 'Radius: $meters m';
  }

  @override
  String familyMapMeters(int meters) {
    return '$meters m';
  }

  @override
  String get familyMapCreate => 'Create';

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
  String get alertCategoryWebThreat => 'Blocked site';

  @override
  String get alertCategoryAppBlocked => 'Blocked app';

  @override
  String get alertCategoryScreenTime => 'Screen time';

  @override
  String get alertCategoryGeofence => 'Places';

  @override
  String get alertCategorySos => 'SOS';

  @override
  String get alertCategoryAiConcern => 'Concerning content';

  @override
  String get alertCategoryCyberbullying => 'Bullying';

  @override
  String get alertCategorySelfHarm => 'Self-harm';

  @override
  String get alertCategoryGrooming => 'Grooming';

  @override
  String get alertCategoryTamper => 'Protection';

  @override
  String get alertCategoryVpnDetected => 'VPN';

  @override
  String get alertCategoryInstallRequest => 'App install request';

  @override
  String get alertCategoryUnknownContact => 'Unknown contact';

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
  String get chooseInstalledApp => 'Choose from child\'s apps';

  @override
  String get installedAppsTitle => 'Installed apps';

  @override
  String get searchApps => 'Search apps';

  @override
  String get showSystemApps => 'Show system apps';

  @override
  String get alreadyRuled => 'Already ruled';

  @override
  String get installedAppsEmpty => 'No apps reported yet';

  @override
  String get installedAppsEmptyHint =>
      'The list appears after the child device\'s next check-in (up to 15 minutes).';

  @override
  String get installedAppsNoMatch => 'No apps match your search.';

  @override
  String installedAppsLoadFailed(String error) {
    return 'Could not load apps: $error';
  }

  @override
  String installedAppsTruncated(int count) {
    return 'Showing the first $count apps.';
  }

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
  String get pairConsentError =>
      'The server needs parental consent for this child before it can create a pairing code. Go back and add the child again, then retry.';

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
  String get callsAndTexts => 'Phone calls & texts';

  @override
  String get iosNoCallMonitoring =>
      'iOS does not support phone-call or text monitoring.';

  @override
  String get noCallsOrTexts => 'No phone calls or texts yet';

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

  @override
  String get onboardingWelcomeTitle => 'Welcome to OSRA';

  @override
  String get onboardingWelcomeBody =>
      'Set up protection for your child in three short steps. It takes about five minutes.';

  @override
  String get onboardingGetStarted => 'Get started';

  @override
  String get onboardingSignInTitle => 'Sign in or create an account';

  @override
  String get onboardingSignInBody =>
      'This account controls your child\'s protection. Sign in, or create your family account below.';

  @override
  String get onboardingWrongPassword =>
      'The email or password is incorrect. Check it and try again.';

  @override
  String get onboardingInvalidMfaCode =>
      'That authentication code was not accepted. Check the code and try again.';

  @override
  String get onboardingNoNetwork =>
      'Cannot reach the server. Check the server address and your internet connection, then try again.';

  @override
  String get onboardingChildTitle => 'Add your child';

  @override
  String get onboardingChildIntro =>
      'Enter your child\'s name and birth year. Choose how you gave parental consent — the server requires consent before a child can be added.';

  @override
  String get onboardingChildNameRequired => 'Enter your child\'s name.';

  @override
  String get onboardingBirthYearInvalid =>
      'Enter a birth year between 1900 and this year.';

  @override
  String get onboardingAddChildContinue => 'Add child and continue';

  @override
  String get onboardingChildPrivacy =>
      'Your child\'s name and birth year are stored on your family\'s server. They are used only for protection and reports.';

  @override
  String get onboardingExistingChildren =>
      'Your account already has children. Continue to pair a device.';

  @override
  String get onboardingConsentRequired =>
      'The server needs parental consent for this child. Check the consent details and try again.';

  @override
  String get onboardingOwnerOnly =>
      'Only the family owner can add a child. Sign in with the owner account or ask the owner to add this child.';

  @override
  String get onboardingChildInvalid =>
      'The server could not add this child. Check the name and birth year, then try again.';

  @override
  String get onboardingChildFailed =>
      'Could not add your child. Check your connection and try again.';

  @override
  String get onboardingLeaveTitle => 'Go back to sign in?';

  @override
  String get onboardingLeaveBody =>
      'You will be signed out. Anything you have already added stays on your account.';

  @override
  String get onboardingLeaveStay => 'Stay';

  @override
  String get onboardingLeaveConfirm => 'Sign out';

  @override
  String get onboardingPairTitle => 'Pair their device';

  @override
  String onboardingPairIntro(String childName) {
    return 'Open OSRA on $childName\'s phone and choose Pair with a code.';
  }

  @override
  String get onboardingPairSteps =>
      'Scan this QR code, or type the six digits below if the camera cannot scan it. You do not need to give your password to the person holding the phone.';

  @override
  String get onboardingPairConfirm => 'My child has finished pairing';

  @override
  String get onboardingPairWaiting =>
      'Not paired yet. Ask your child to finish on their phone, then tap again.';

  @override
  String get onboardingPairCheckFailed =>
      'Could not check the pairing yet. Check your connection and tap again.';

  @override
  String get onboardingPairLater => 'Set up later';

  @override
  String get onboardingPairLaterNote =>
      'You can pair from the dashboard whenever the phone is ready. Protection starts after pairing.';

  @override
  String pairingCodeSemantics(String code) {
    return 'Pairing code $code';
  }

  @override
  String get onboardingDoneStepTitle => 'Setup';

  @override
  String get onboardingDoneTitle => 'You\'re all set';

  @override
  String get onboardingDoneBody =>
      'Your child is added and their device is paired. Open the dashboard to see their status.';

  @override
  String get onboardingDonePendingTitle => 'One step left';

  @override
  String get onboardingDonePendingBody =>
      'Your child is added, but their phone is not paired yet. You can pair it any time from the dashboard.';

  @override
  String get onboardingGoToDashboard => 'Go to dashboard';

  @override
  String get onboardingFinishSetupTitle => 'Finish setting up';

  @override
  String onboardingFinishSetupBody(String childName) {
    return 'Pair $childName\'s phone to start protection.';
  }

  @override
  String get onboardingPairNow => 'Pair now';

  @override
  String get consentRecordSummary => 'Method, dates and withdrawal';

  @override
  String consentStatusSubtitle(String childName) {
    return 'What the server has on record for $childName.';
  }

  @override
  String get consentStateActive => 'Active';

  @override
  String get consentStateExpiring => 'Expiring soon';

  @override
  String get consentStateExpired => 'Expired';

  @override
  String get consentStateRevoked => 'Withdrawn';

  @override
  String get consentStateMismatch => 'Wrong region';

  @override
  String get consentStateNone => 'No consent record';

  @override
  String get consentStateActiveDetail =>
      'Monitoring and data collection are allowed under this record.';

  @override
  String consentStateExpiringDetail(String date) {
    return 'This record expires on $date. Collection and alerts stop after that date unless consent is granted again.';
  }

  @override
  String consentStateExpiredDetail(String date) {
    return 'This record expired on $date. Monitoring and data collection are stopped until consent is granted again.';
  }

  @override
  String consentStateRevokedDetail(String date) {
    return 'Consent was withdrawn on $date. Monitoring and data collection are stopped until consent is granted again.';
  }

  @override
  String consentStateMismatchDetail(String record, String family) {
    return 'The record\'s jurisdiction ($record) does not match your family region ($family), so it cannot authorise monitoring.';
  }

  @override
  String get consentStateNoneDetail =>
      'No parental consent is on record for this child. Monitoring and data collection require an active record.';

  @override
  String get consentJurisdictionLabel => 'Jurisdiction';

  @override
  String get consentGrantedLabel => 'Granted';

  @override
  String get consentExpiryLabel => 'Expires';

  @override
  String get consentNoExpiry => 'No expiry';

  @override
  String get consentThirdPartyLabel => 'Third-party sharing';

  @override
  String get consentSharingOn => 'On';

  @override
  String get consentSharingOff => 'Off';

  @override
  String get consentRevokedLabel => 'Withdrawn';

  @override
  String get consentNotRevoked => 'Not withdrawn';

  @override
  String get consentCurrentRecord => 'Current record';

  @override
  String get consentHistorySection => 'Earlier records';

  @override
  String consentHistoryGranted(String method, String date) {
    return '$method · granted $date';
  }

  @override
  String consentHistoryRevoked(String date) {
    return 'withdrawn $date';
  }

  @override
  String consentHistoryExpired(String date) {
    return 'expired $date';
  }

  @override
  String get consentHistoryActive => 'active';

  @override
  String get consentLoadFailed =>
      'Could not load the consent record. Check your connection and try again.';

  @override
  String get consentWithdrawAction => 'Withdraw consent';

  @override
  String get consentWithdrawOnlyOwner =>
      'Only the family owner can withdraw consent.';

  @override
  String get consentWithdrawUnavailable =>
      'There is no active consent record to withdraw.';

  @override
  String get consentWithdrawNote =>
      'Withdrawing consent stops monitoring. It does not delete data that was already collected.';

  @override
  String get consentRevokeTitle => 'Withdraw consent?';

  @override
  String consentRevokeWarning(String childName) {
    return 'This stops monitoring for $childName. The device stays paired, and consent can be granted again later.';
  }

  @override
  String get consentRevokeStopsTitle => 'What stops immediately';

  @override
  String get consentRevokeStopsCollection =>
      'New data collection stops: location, app and web activity, and chat scans.';

  @override
  String get consentRevokeStopsAlerts =>
      'Safety alerts stop, including SOS, screen-time and blocked-site alerts.';

  @override
  String get consentRevokeStopsRules =>
      'Monitoring pauses on every device. Saved rules stay, but are not enforced until consent is granted again.';

  @override
  String get consentRevokeKeepsSafe =>
      'Unlocking and resuming your child\'s device still work while consent is withdrawn.';

  @override
  String get consentRevokeDataTitle => 'What happens to data already collected';

  @override
  String get consentRevokeDataRetained =>
      'Nothing is deleted or anonymised now. Reports, alerts and location history already collected stay in your family account.';

  @override
  String get consentRevokeDataRetention =>
      'Raw location data is deleted by the retention job after 30 days by default; raw app, web and chat data after 90 days.\n\nUsage summaries are kept for 365 days. Alerts are kept until the child\'s data is erased.';

  @override
  String get consentRevokeDataErase =>
      'Deleting your child\'s profile is a separate action that removes all their data immediately. It is not part of withdrawing consent.';

  @override
  String consentRevokeTypePrompt(String childName) {
    return 'Type $childName to confirm';
  }

  @override
  String get consentRevokeTypeHint => 'The name must match.';

  @override
  String consentRevokeMismatch(String childName) {
    return 'This does not match $childName.';
  }

  @override
  String get consentRevokeSubmit => 'Withdraw consent now';

  @override
  String get consentRevokeCancel => 'Keep consent';

  @override
  String get consentRevokeBusy => 'Withdrawing…';

  @override
  String get consentRevokeFailed =>
      'Could not withdraw consent. Nothing was changed. Check your connection and try again.';

  @override
  String get consentRevokeForbidden =>
      'Only the family owner can withdraw consent. Nothing was changed.';

  @override
  String get consentRevokeDone => 'Consent withdrawn. Monitoring is paused.';

  @override
  String get consentRevokeNoActive =>
      'There was no active consent record. Nothing changed.';

  @override
  String consentRevokeDevices(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Pause signal queued for $count devices.',
      one: 'Pause signal queued for 1 device.',
      zero: 'No device was connected.',
    );
    return '$_temp0';
  }

  @override
  String get consentChildNameMissing =>
      'Could not load your child\'s name. Go back and try again.';

  @override
  String get refresh => 'Refresh';

  @override
  String get searchSafetyTitle => 'Search safety';

  @override
  String searchSafetyLoadFailed(String error) {
    return 'Failed to load search activity: $error';
  }

  @override
  String get searchSafetyEmptyTitle => 'No flagged searches detected';

  @override
  String get searchSafetyEmptyBody =>
      'SafeSearch enforcement and content inspection are active across all supported browsers and apps.';

  @override
  String get searchSafetyVaultNotice =>
      'Search queries are analysed for safety concerns. High-severity matches are logged to the encrypted family vault.';

  @override
  String searchSafetyFlaggedCount(int count) {
    return 'Flagged searches ($count)';
  }

  @override
  String get searchSafetyEngineFallback => 'Search';

  @override
  String get searchSafetyEmptyQuery => '(Empty query)';

  @override
  String get searchSafetyViewVault => 'View vault details';

  @override
  String searchSafetyVaultTitle(String query) {
    return 'Search: \"$query\"';
  }

  @override
  String get digestPrefsTitle => 'Digest preferences';

  @override
  String digestPrefsLoadFailed(String error) {
    return 'Failed to load preferences: $error';
  }

  @override
  String get digestPrefsDailyTitle => 'Daily email digest';

  @override
  String get digestPrefsDailyBody => 'A short summary every evening';

  @override
  String get digestPrefsWeeklyTitle => 'Weekly email digest';

  @override
  String get digestPrefsWeeklyBody => 'A deeper summary once a week';

  @override
  String get digestPrefsPushTitle => 'Push notifications';

  @override
  String get digestPrefsPushBody => 'Critical alerts as push messages';

  @override
  String get digestPrefsEmailsLabel => 'Digest emails';

  @override
  String get digestPrefsEmailsHelper =>
      'For the digest summary (separate addresses with commas)';

  @override
  String get digestPrefsConfirmationSent =>
      'Confirmation sent — this address gets no digest until it is confirmed';

  @override
  String get digestPrefsNotSent => 'Not sent. Save again to retry.';

  @override
  String get digestPrefsConfirmationLimited =>
      'Not sent yet: too many confirmations are waiting. Try again tomorrow.';

  @override
  String get digestPrefsTimezoneTitle => 'Digest timezone (local send hour)';

  @override
  String get digestPrefsTimezoneLabel => 'Timezone';

  @override
  String get digestPrefsTimezoneLoading => 'Loading…';

  @override
  String get digestPrefsSendHour =>
      'The digest is sent at the hour shown below, in your local time zone.';

  @override
  String get digestPrefsSavingSuffix => 'saving…';

  @override
  String get digestPrefsSaving => 'Saving…';

  @override
  String get digestPrefsSave => 'Save preferences';

  @override
  String get digestPrefsRendering => 'Rendering…';

  @override
  String get digestPrefsSendNow => 'Send test digest now';

  @override
  String get digestPrefsSaved => 'Digest preferences saved';

  @override
  String digestPrefsSaveFailed(String error) {
    return 'Save failed: $error';
  }

  @override
  String digestPrefsTimezoneSet(String zone) {
    return 'Digest timezone set to $zone';
  }

  @override
  String digestPrefsTimezoneFailed(String error) {
    return 'Timezone not saved: $error';
  }

  @override
  String get digestPrefsTestTitle => 'Test digest';

  @override
  String get digestPrefsClose => 'Close';

  @override
  String digestPrefsSendFailed(String error) {
    return 'Send failed: $error';
  }

  @override
  String get digestPrefsNoDigests => 'No digests generated';

  @override
  String get digestPrefsChildFallback => 'Child';

  @override
  String get mfaResetTitle => 'Reset two-step verification';

  @override
  String get mfaResetIntro =>
      'Use this only if you have lost your authenticator and every recovery code. You will need your account password and access to this account\'s email, and one of these: a code shown on your child\'s phone, or another owner or co-parent who approves from their app. Then there is a 72-hour wait before two-step verification is reset.';

  @override
  String get mfaResetSubmit => 'Request a reset';

  @override
  String get mfaResetFieldsRequired => 'Fill in your email and password.';

  @override
  String get mfaResetInvalidCredentials =>
      'The email or password is incorrect.';

  @override
  String get mfaResetMfaNotEnabled =>
      'Two-step verification is off for this account, so there is nothing to reset. Sign in with your password.';

  @override
  String get mfaResetNoWitness =>
      'This account has no family witness: no paired child device and no other owner or co-parent. Without one, two-step verification cannot be reset. If the child\'s phone is no longer paired, you can create a new account with another email address.';

  @override
  String get mfaResetAlreadyPending =>
      'A reset for this account is already in its 72-hour wait and cannot be replaced. Finish that one, or cancel it with the link in its email.';

  @override
  String get mfaResetLimitReached =>
      'You can request at most three resets in 30 days. This account has used them all for now.';

  @override
  String get mfaResetLinkExpired =>
      'That link has expired or was already used.';

  @override
  String get mfaResetEntry => 'No recovery code left? Request a reset';

  @override
  String get mfaResetSettingsEntry =>
      'Lost your authenticator and recovery codes?';

  @override
  String get mfaResetSetupNote =>
      'If you lose the authenticator and every one of these codes, you can only get back in with a family witness: a paired child device or another owner or co-parent.';

  @override
  String get mfaResetWaitingTitle => 'Reset in progress';

  @override
  String get mfaResetStageMailboxTitle => 'Check your email';

  @override
  String get mfaResetStageMailboxBody =>
      'Open the reset link sent to this account\'s email within 30 minutes. Opening the link puts an 8-digit code on your child\'s phone. If another parent is going to approve instead, they must do it from their app.';

  @override
  String mfaResetMailboxExpires(String time) {
    return 'The link is valid until $time.';
  }

  @override
  String mfaResetMailboxLinkGrace(String time) {
    return 'The link expired at $time. If you opened it before then, enter the code now: it works for 10 minutes after the link was opened.';
  }

  @override
  String get mfaResetCancelHint =>
      'To stop this request, open the cancel link in any email about it. Signing in with your authenticator also cancels it.';

  @override
  String get mfaResetStageWitnessTitle =>
      'Enter the code from your child\'s phone';

  @override
  String get mfaResetStageWitnessBody =>
      'The code is 8 digits and is valid for 10 minutes.';

  @override
  String mfaResetCodeExpires(String time) {
    return 'The code is valid until $time.';
  }

  @override
  String mfaResetAwaitingCoParent(String time) {
    return 'Waiting for another parent in your family to approve, by $time.';
  }

  @override
  String get mfaResetHaveCode => 'I have the code';

  @override
  String get mfaResetEnterCode => 'Enter the code';

  @override
  String get mfaResetStageWindowTitle => 'The 72-hour wait has started';

  @override
  String get mfaResetStageWindowBody =>
      'Two-step verification will be reset when the wait ends, unless the request is cancelled before then.';

  @override
  String mfaResetWindowEndsAt(String time) {
    return 'The wait ends at $time.';
  }

  @override
  String get mfaResetWindowDue =>
      'The wait is over. You can finish the reset now.';

  @override
  String get mfaResetDeadlinePassed =>
      'This link or code has run out. A new request replaces this one.';

  @override
  String get mfaResetFinish => 'Finish the reset';

  @override
  String get mfaResetCancelKeep => 'Keep waiting';

  @override
  String get mfaResetRequestNotFound => 'That request no longer exists.';

  @override
  String get mfaResetRequestNotOpen =>
      'This request is no longer open. Start again from the beginning.';

  @override
  String get mfaResetRequestExpired =>
      'This request has expired. Start again from the beginning.';

  @override
  String get mfaResetRequestCompleted =>
      'This request has already been completed.';

  @override
  String get mfaResetRequestCancelled => 'This request was cancelled.';

  @override
  String get mfaResetWitnessRequired =>
      'The witness step has not been completed yet.';

  @override
  String get mfaResetWindowOpen =>
      'The wait is not over yet. Nothing has changed.';

  @override
  String get mfaResetWitnessDispatchFailed =>
      'The code could not be sent to your child\'s phone. Request a reset again in a moment.';

  @override
  String get mfaResetUnavailable =>
      'The reset service is unavailable right now. Try again in a moment.';

  @override
  String get mfaResetFinishTitle => 'Finish the reset';

  @override
  String get mfaResetFinishBody =>
      'Enter this account\'s email and password. Two-step verification will be cleared and you will set up a new authenticator.';

  @override
  String get mfaResetFinishSubmit => 'Reset two-step verification';

  @override
  String get mfaResetWitnessTitle => 'Enter the reset code';

  @override
  String get mfaResetWitnessIntro =>
      'Type the 8-digit code shown on your child\'s phone. It is valid for 10 minutes, and five wrong codes end this request.';

  @override
  String get mfaResetWitnessLabel => '8-digit code';

  @override
  String get mfaResetWitnessSubmit => 'Check code';

  @override
  String get mfaResetWitnessEnterCode => 'Enter the 8-digit code.';

  @override
  String get mfaResetWitnessInvalid =>
      'That code was not accepted or has expired. Check the code on your child\'s phone and try again.';

  @override
  String mfaResetWitnessAttemptsLeft(int count) {
    return 'That code was not accepted. Attempts left: $count.';
  }

  @override
  String get mfaResetWitnessTooMany =>
      'Too many wrong codes. This request has ended; start again from the beginning.';

  @override
  String get mfaResetApproveTitle => 'Approve a reset request';

  @override
  String get mfaResetApproveIntro =>
      'Another parent in your family asked to reset their two-step verification after losing their authenticator and recovery codes. Approving starts a 72-hour wait. A sign-in by that parent during the wait cancels the request.';

  @override
  String get mfaResetApproveAction => 'Approve';

  @override
  String get mfaResetDeclineAction => 'Decline';

  @override
  String get mfaResetDeclineTitle => 'Decline this request?';

  @override
  String get mfaResetDeclineBody =>
      'The reset will not happen and two-step verification stays as it is.';

  @override
  String get mfaResetDeclineConfirm => 'Decline request';

  @override
  String get mfaResetApproved => 'Approved. The 72-hour wait has started.';

  @override
  String get mfaResetDeclined => 'Declined. The request was cancelled.';

  @override
  String get mfaResetApproveRole =>
      'Only an owner or co-parent can approve or decline a reset request.';

  @override
  String get mfaResetApproveForbidden =>
      'You cannot approve or decline this request.';

  @override
  String get mfaResetApproveNeedsId =>
      'Open this screen from the notification about the request.';

  @override
  String mfaResetApproveIntroNamed(String name, String role) {
    return '$name ($role) asked to reset their two-step verification after losing their authenticator and recovery codes. Approving starts a 72-hour wait. A sign-in by $name during the wait cancels the request.';
  }

  @override
  String get mfaResetApproveAlready =>
      'This request already has its witness. The 72-hour wait is running; you can still decline it to cancel.';

  @override
  String get mfaResetRoleOwner => 'owner';

  @override
  String get mfaResetRoleCoParent => 'co-parent';

  @override
  String get mfaResetRoleGuardian => 'guardian';

  @override
  String get mfaResetRoleFamilyMember => 'family member';

  @override
  String get mfaResetPendingSectionTitle => 'Reset requests waiting for you';

  @override
  String mfaResetPendingBanner(String name, String role) {
    return '$name ($role) asked to reset their two-step verification.';
  }

  @override
  String get mfaResetPendingReview => 'Review';

  @override
  String mfaResetPendingMore(int count) {
    return 'and $count more';
  }

  @override
  String mfaResetPendingAlreadyWaiting(String role) {
    return '$role — witness passed, the 72-hour wait is running';
  }

  @override
  String get mfaResetResumeTitle => 'Continue your reset';

  @override
  String get mfaResetResumeBody =>
      'A reset request from this phone is still on file. Enter your account password to see where it stands. The password is used only for this check and is not saved.';

  @override
  String get mfaResetResumePasswordRequired =>
      'Enter your password to continue.';

  @override
  String get mfaResetResumeSubmit => 'Continue';

  @override
  String get mfaResetResumeNone =>
      'There is no saved reset request on this phone.';

  @override
  String get mfaResetStartNewRequest => 'Start a new request';

  @override
  String get mfaResetTerminalTitle => 'This reset request has ended';

  @override
  String get mfaResetTerminalSigninCancelled =>
      'A successful sign-in cancels a reset request, so nothing was changed. If you still need to reset two-step verification, start a new request.';

  @override
  String get mfaResetTerminalCancelled =>
      'This request was cancelled, so nothing was changed. If you still need to reset two-step verification, start a new request.';

  @override
  String get mfaResetTerminalExpired =>
      'This request expired before it finished, so nothing was changed. Start a new request when you are ready.';

  @override
  String get mfaResetTerminalTooManyAttempts =>
      'Five wrong codes ended this request, so nothing was changed. Have the child whose phone shows the code with you, then start a new request.';

  @override
  String get mfaResetTerminalCompleted =>
      'This reset was completed. Sign in with your new authenticator; if you have not set it up yet, do that first.';

  @override
  String get mfaResetTerminalNotFound =>
      'This request no longer exists, so nothing was changed. Start again from the beginning.';

  @override
  String get mfaResetTerminalUnknown =>
      'This request cannot continue, and nothing was changed. Start a new request.';

  @override
  String get mfaResetStageWitnessTitleResumed => 'Waiting for the witness step';

  @override
  String get mfaResetStageWitnessBodyResumed =>
      'If an 8-digit code is shown on your child\'s phone, enter it below. If another owner or co-parent is approving instead, they must do it from their app; this request moves on when that happens.';

  @override
  String get digestPrefsSendHourLabel => 'Send hour';

  @override
  String get alertTitleSos => 'SOS pressed';

  @override
  String get alertTitleBlockedSite => 'Blocked site attempted';

  @override
  String get alertTitleDailyLimit => 'Daily limit reached';

  @override
  String get alertTitleAppBlocked => 'App blocked';

  @override
  String get alertTitleGeofence => 'Place alert';

  @override
  String get alertTitleAiConcern => 'Concerning content';

  @override
  String get alertTitleCyberbullying => 'Possible cyberbullying';

  @override
  String get alertTitleSelfHarm => 'Possible self-harm risk';

  @override
  String get alertTitleGrooming => 'Possible grooming';

  @override
  String get alertTitleTamper => 'Protection tampered with';

  @override
  String get alertTitleVpnDetected => 'VPN detected';

  @override
  String get alertTitleInstallRequest => 'App install request';

  @override
  String get alertTitleUnknownContact => 'Unknown contact';

  @override
  String get alertTitleGeneric => 'Alert';

  @override
  String get alertPushBodyGeneric =>
      'Open OSRA to see the details.\nProtecting your family at all times.';

  @override
  String get riskSelfHarm => 'Self-harm';

  @override
  String get riskSubstanceUse => 'Substance use';

  @override
  String get riskSubstanceAbuse => 'Substance abuse';

  @override
  String get riskAdultContent => 'Adult content';

  @override
  String get riskSexualContent => 'Sexual content';

  @override
  String get riskCyberbullying => 'Cyberbullying';

  @override
  String get riskGrooming => 'Grooming';

  @override
  String get riskViolence => 'Violence';

  @override
  String get riskHateSpeech => 'Hate speech';

  @override
  String get riskAiConcern => 'Concerning content';
}
