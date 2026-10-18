import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';
import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('ar'),
    Locale('en')
  ];

  /// No description provided for @appName.
  ///
  /// In en, this message translates to:
  /// **'OSRA'**
  String get appName;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @add.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get add;

  /// No description provided for @continueLabel.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continueLabel;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @tryAgain.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get tryAgain;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @dismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get dismiss;

  /// No description provided for @system.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get system;

  /// No description provided for @light.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get light;

  /// No description provided for @dark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get dark;

  /// No description provided for @english.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get english;

  /// No description provided for @arabic.
  ///
  /// In en, this message translates to:
  /// **'العربية'**
  String get arabic;

  /// No description provided for @unknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get unknown;

  /// No description provided for @never.
  ///
  /// In en, this message translates to:
  /// **'never'**
  String get never;

  /// No description provided for @timeUnknown.
  ///
  /// In en, this message translates to:
  /// **'time unknown'**
  String get timeUnknown;

  /// No description provided for @saving.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get saving;

  /// No description provided for @minutesShort.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min'**
  String minutesShort(int minutes);

  /// No description provided for @appTagline.
  ///
  /// In en, this message translates to:
  /// **'أسرة — parental control for your family'**
  String get appTagline;

  /// No description provided for @serverLabel.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get serverLabel;

  /// No description provided for @serverHint.
  ///
  /// In en, this message translates to:
  /// **'http://host:port'**
  String get serverHint;

  /// No description provided for @serverShown.
  ///
  /// In en, this message translates to:
  /// **'Server: {url}'**
  String serverShown(String url);

  /// No description provided for @invalidServer.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid server, e.g. http://192.168.1.5:3000'**
  String get invalidServer;

  /// No description provided for @emailLabel.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get emailLabel;

  /// No description provided for @passwordLabel.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get passwordLabel;

  /// No description provided for @mfaCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Authentication code (if MFA is on)'**
  String get mfaCodeLabel;

  /// No description provided for @signIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get signIn;

  /// No description provided for @createAccount.
  ///
  /// In en, this message translates to:
  /// **'Create account'**
  String get createAccount;

  /// No description provided for @familyNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Family name'**
  String get familyNameLabel;

  /// No description provided for @yourNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Your name'**
  String get yourNameLabel;

  /// No description provided for @regionLabel.
  ///
  /// In en, this message translates to:
  /// **'Region'**
  String get regionLabel;

  /// No description provided for @regionUS.
  ///
  /// In en, this message translates to:
  /// **'United States'**
  String get regionUS;

  /// No description provided for @regionEU.
  ///
  /// In en, this message translates to:
  /// **'European Union'**
  String get regionEU;

  /// No description provided for @regionUK.
  ///
  /// In en, this message translates to:
  /// **'United Kingdom'**
  String get regionUK;

  /// No description provided for @regionOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get regionOther;

  /// No description provided for @register.
  ///
  /// In en, this message translates to:
  /// **'Register'**
  String get register;

  /// No description provided for @familyMapTooltip.
  ///
  /// In en, this message translates to:
  /// **'Family map'**
  String get familyMapTooltip;

  /// No description provided for @alertsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Alerts'**
  String get alertsTooltip;

  /// No description provided for @familyMembersMenu.
  ///
  /// In en, this message translates to:
  /// **'Family members'**
  String get familyMembersMenu;

  /// No description provided for @appearanceMenu.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearanceMenu;

  /// No description provided for @digestPreferencesMenu.
  ///
  /// In en, this message translates to:
  /// **'Digest preferences'**
  String get digestPreferencesMenu;

  /// No description provided for @signOutTooltip.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get signOutTooltip;

  /// No description provided for @familyLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load family: {error}'**
  String familyLoadFailed(String error);

  /// No description provided for @noChildrenYet.
  ///
  /// In en, this message translates to:
  /// **'No children yet — tap \"Add child\"'**
  String get noChildrenYet;

  /// No description provided for @addChild.
  ///
  /// In en, this message translates to:
  /// **'Add child'**
  String get addChild;

  /// No description provided for @statusOnline.
  ///
  /// In en, this message translates to:
  /// **'online'**
  String get statusOnline;

  /// No description provided for @statusOffline.
  ///
  /// In en, this message translates to:
  /// **'offline'**
  String get statusOffline;

  /// No description provided for @noLocationYet.
  ///
  /// In en, this message translates to:
  /// **'No location yet'**
  String get noLocationYet;

  /// No description provided for @screenTime.
  ///
  /// In en, this message translates to:
  /// **'Screen time'**
  String get screenTime;

  /// No description provided for @screenTimeValue.
  ///
  /// In en, this message translates to:
  /// **'{minutes} / {limit} min'**
  String screenTimeValue(int minutes, String limit);

  /// No description provided for @liveActivityToday.
  ///
  /// In en, this message translates to:
  /// **'{app} · {minutes}m today'**
  String liveActivityToday(String app, int minutes);

  /// No description provided for @wellbeingScore.
  ///
  /// In en, this message translates to:
  /// **'Wellbeing {score}/100'**
  String wellbeingScore(int score);

  /// No description provided for @wellbeingUsage.
  ///
  /// In en, this message translates to:
  /// **'usage'**
  String get wellbeingUsage;

  /// No description provided for @wellbeingSocial.
  ///
  /// In en, this message translates to:
  /// **'social'**
  String get wellbeingSocial;

  /// No description provided for @wellbeingSafety.
  ///
  /// In en, this message translates to:
  /// **'safety'**
  String get wellbeingSafety;

  /// No description provided for @paused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get paused;

  /// No description provided for @internet.
  ///
  /// In en, this message translates to:
  /// **'Internet'**
  String get internet;

  /// No description provided for @pauseInternetTitle.
  ///
  /// In en, this message translates to:
  /// **'Pause internet for {name}?'**
  String pauseInternetTitle(String name);

  /// No description provided for @resumeInternetTitle.
  ///
  /// In en, this message translates to:
  /// **'Resume internet for {name}?'**
  String resumeInternetTitle(String name);

  /// No description provided for @pauseInternetBody.
  ///
  /// In en, this message translates to:
  /// **'Educational apps keep working.'**
  String get pauseInternetBody;

  /// No description provided for @resumeInternetBody.
  ///
  /// In en, this message translates to:
  /// **'All apps and sites work again.'**
  String get resumeInternetBody;

  /// No description provided for @pause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get pause;

  /// No description provided for @resume.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get resume;

  /// No description provided for @internetChangeFailed.
  ///
  /// In en, this message translates to:
  /// **'Internet change failed: {error}'**
  String internetChangeFailed(String error);

  /// No description provided for @parentalConsent.
  ///
  /// In en, this message translates to:
  /// **'Parental consent'**
  String get parentalConsent;

  /// No description provided for @childDetails.
  ///
  /// In en, this message translates to:
  /// **'Child details'**
  String get childDetails;

  /// No description provided for @consentNotice.
  ///
  /// In en, this message translates to:
  /// **'Verifiable parental consent is required before adding a child (COPPA/GDPR-K).'**
  String get consentNotice;

  /// No description provided for @consentMethodLabel.
  ///
  /// In en, this message translates to:
  /// **'Consent method'**
  String get consentMethodLabel;

  /// No description provided for @consentMethodSmsPlus.
  ///
  /// In en, this message translates to:
  /// **'SMS +'**
  String get consentMethodSmsPlus;

  /// No description provided for @consentMethodKba.
  ///
  /// In en, this message translates to:
  /// **'Knowledge-based questions'**
  String get consentMethodKba;

  /// No description provided for @consentMethodFaceMatch.
  ///
  /// In en, this message translates to:
  /// **'Face match'**
  String get consentMethodFaceMatch;

  /// No description provided for @consentMethodCreditCard.
  ///
  /// In en, this message translates to:
  /// **'Credit card'**
  String get consentMethodCreditCard;

  /// No description provided for @jurisdictionLabel.
  ///
  /// In en, this message translates to:
  /// **'Jurisdiction'**
  String get jurisdictionLabel;

  /// No description provided for @childNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Child name'**
  String get childNameLabel;

  /// No description provided for @birthYearLabel.
  ///
  /// In en, this message translates to:
  /// **'Birth year'**
  String get birthYearLabel;

  /// No description provided for @childFallback.
  ///
  /// In en, this message translates to:
  /// **'Child'**
  String get childFallback;

  /// No description provided for @tabOverview.
  ///
  /// In en, this message translates to:
  /// **'Overview'**
  String get tabOverview;

  /// No description provided for @tabApps.
  ///
  /// In en, this message translates to:
  /// **'Apps'**
  String get tabApps;

  /// No description provided for @tabSocial.
  ///
  /// In en, this message translates to:
  /// **'Social'**
  String get tabSocial;

  /// No description provided for @tabLocation.
  ///
  /// In en, this message translates to:
  /// **'Location'**
  String get tabLocation;

  /// No description provided for @tabAlerts.
  ///
  /// In en, this message translates to:
  /// **'Alerts'**
  String get tabAlerts;

  /// No description provided for @reportsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Reports'**
  String get reportsTooltip;

  /// No description provided for @searchSafetyTooltip.
  ///
  /// In en, this message translates to:
  /// **'Search & web safety'**
  String get searchSafetyTooltip;

  /// No description provided for @editRules.
  ///
  /// In en, this message translates to:
  /// **'Edit rules'**
  String get editRules;

  /// No description provided for @bornYear.
  ///
  /// In en, this message translates to:
  /// **'Born {year}'**
  String bornYear(int year);

  /// No description provided for @socialMonitoringTitle.
  ///
  /// In en, this message translates to:
  /// **'Social monitoring'**
  String get socialMonitoringTitle;

  /// No description provided for @devices.
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get devices;

  /// No description provided for @pairADevice.
  ///
  /// In en, this message translates to:
  /// **'Pair a device'**
  String get pairADevice;

  /// No description provided for @noDevicesRegistered.
  ///
  /// In en, this message translates to:
  /// **'No devices registered'**
  String get noDevicesRegistered;

  /// No description provided for @lastSeenLabel.
  ///
  /// In en, this message translates to:
  /// **'Last seen: {time}'**
  String lastSeenLabel(String time);

  /// No description provided for @deliveryStatus.
  ///
  /// In en, this message translates to:
  /// **'Delivery status'**
  String get deliveryStatus;

  /// No description provided for @ring.
  ///
  /// In en, this message translates to:
  /// **'Ring'**
  String get ring;

  /// No description provided for @lock.
  ///
  /// In en, this message translates to:
  /// **'Lock'**
  String get lock;

  /// No description provided for @unlock.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get unlock;

  /// No description provided for @pauseNet.
  ///
  /// In en, this message translates to:
  /// **'Pause net'**
  String get pauseNet;

  /// No description provided for @resumeNet.
  ///
  /// In en, this message translates to:
  /// **'Resume net'**
  String get resumeNet;

  /// No description provided for @checkingCommandDelivery.
  ///
  /// In en, this message translates to:
  /// **'Checking command delivery…'**
  String get checkingCommandDelivery;

  /// No description provided for @commandDeliveryUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Command delivery unavailable'**
  String get commandDeliveryUnavailable;

  /// No description provided for @noCommandsYet.
  ///
  /// In en, this message translates to:
  /// **'No commands yet'**
  String get noCommandsYet;

  /// No description provided for @latestCommand.
  ///
  /// In en, this message translates to:
  /// **'Latest: {type} · {status} · {time}'**
  String latestCommand(String type, String status, String time);

  /// No description provided for @bonusTime.
  ///
  /// In en, this message translates to:
  /// **'Bonus time'**
  String get bonusTime;

  /// No description provided for @extraScreenTimeToday.
  ///
  /// In en, this message translates to:
  /// **'Extra screen time today only'**
  String get extraScreenTimeToday;

  /// No description provided for @bonusGranted.
  ///
  /// In en, this message translates to:
  /// **'{minutes, plural, =1{+1 extra minute granted today} other{+{minutes} extra minutes granted today}}'**
  String bonusGranted(int minutes);

  /// No description provided for @bonusFailed.
  ///
  /// In en, this message translates to:
  /// **'Bonus failed: {error}'**
  String bonusFailed(String error);

  /// No description provided for @windDown.
  ///
  /// In en, this message translates to:
  /// **'Wind down'**
  String get windDown;

  /// No description provided for @windDownBody.
  ///
  /// In en, this message translates to:
  /// **'The device shows a soft bedtime warning, then locks.'**
  String get windDownBody;

  /// No description provided for @windDownSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Soft warning, then the screen locks'**
  String get windDownSubtitle;

  /// No description provided for @windDownConfirm.
  ///
  /// In en, this message translates to:
  /// **'{minutes, plural, =1{Screen will lock in 1 minute on the device} other{Screen will lock in {minutes} minutes on the device}}'**
  String windDownConfirm(int minutes);

  /// No description provided for @windDownFailed.
  ///
  /// In en, this message translates to:
  /// **'Wind down failed: {error}'**
  String windDownFailed(String error);

  /// No description provided for @commandQueued.
  ///
  /// In en, this message translates to:
  /// **'{command} queued for {device} — the device has not confirmed it yet.'**
  String commandQueued(String command, String device);

  /// No description provided for @netQueued.
  ///
  /// In en, this message translates to:
  /// **'{action} queued for {device} — the device has not confirmed it yet.'**
  String netQueued(String action, String device);

  /// No description provided for @commandFailed.
  ///
  /// In en, this message translates to:
  /// **'Command failed: {error}'**
  String commandFailed(String error);

  /// No description provided for @rulesLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load rules: {error}'**
  String rulesLoadFailed(String error);

  /// No description provided for @noPerAppRules.
  ///
  /// In en, this message translates to:
  /// **'No per-app rules'**
  String get noPerAppRules;

  /// No description provided for @appActionBlock.
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get appActionBlock;

  /// No description provided for @appActionTimeLimit.
  ///
  /// In en, this message translates to:
  /// **'Time limit'**
  String get appActionTimeLimit;

  /// No description provided for @appActionAllow.
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get appActionAllow;

  /// No description provided for @locationLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load location: {error}'**
  String locationLoadFailed(String error);

  /// No description provided for @noLocationReported.
  ///
  /// In en, this message translates to:
  /// **'No location reported yet'**
  String get noLocationReported;

  /// No description provided for @accuracyLabel.
  ///
  /// In en, this message translates to:
  /// **'Accuracy ±{meters} m · {time}'**
  String accuracyLabel(int meters, String time);

  /// No description provided for @mapPreview.
  ///
  /// In en, this message translates to:
  /// **'Map preview'**
  String get mapPreview;

  /// No description provided for @locationHistoryLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load history: {error}'**
  String locationHistoryLoadFailed(String error);

  /// No description provided for @noLocationHistoryToday.
  ///
  /// In en, this message translates to:
  /// **'No location history for today'**
  String get noLocationHistoryToday;

  /// No description provided for @todaysRoute.
  ///
  /// In en, this message translates to:
  /// **'Today\'s route'**
  String get todaysRoute;

  /// No description provided for @back15Tooltip.
  ///
  /// In en, this message translates to:
  /// **'Back 15 min'**
  String get back15Tooltip;

  /// No description provided for @forward15Tooltip.
  ///
  /// In en, this message translates to:
  /// **'Forward 15 min'**
  String get forward15Tooltip;

  /// No description provided for @accuracyUnknown.
  ///
  /// In en, this message translates to:
  /// **'accuracy unknown'**
  String get accuracyUnknown;

  /// No description provided for @alertsLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load alerts: {error}'**
  String alertsLoadFailed(String error);

  /// No description provided for @noRecentAlerts.
  ///
  /// In en, this message translates to:
  /// **'No recent alerts'**
  String get noRecentAlerts;

  /// No description provided for @acknowledgeTooltip.
  ///
  /// In en, this message translates to:
  /// **'Acknowledge'**
  String get acknowledgeTooltip;

  /// No description provided for @ageRating.
  ///
  /// In en, this message translates to:
  /// **'Age rating: {rating}'**
  String ageRating(String rating);

  /// No description provided for @risks.
  ///
  /// In en, this message translates to:
  /// **'Risks'**
  String get risks;

  /// No description provided for @saferAlternatives.
  ///
  /// In en, this message translates to:
  /// **'Safer alternatives'**
  String get saferAlternatives;

  /// No description provided for @noInsightsYet.
  ///
  /// In en, this message translates to:
  /// **'No insights for this app yet'**
  String get noInsightsYet;

  /// No description provided for @insightsLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load insights: {error}'**
  String insightsLoadFailed(String error);

  /// No description provided for @commandLock.
  ///
  /// In en, this message translates to:
  /// **'Lock'**
  String get commandLock;

  /// No description provided for @commandUnlock.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get commandUnlock;

  /// No description provided for @commandRing.
  ///
  /// In en, this message translates to:
  /// **'Ring'**
  String get commandRing;

  /// No description provided for @commandStopRing.
  ///
  /// In en, this message translates to:
  /// **'Stop ringing'**
  String get commandStopRing;

  /// No description provided for @commandClearSos.
  ///
  /// In en, this message translates to:
  /// **'Clear SOS'**
  String get commandClearSos;

  /// No description provided for @commandPauseDevice.
  ///
  /// In en, this message translates to:
  /// **'Pause device'**
  String get commandPauseDevice;

  /// No description provided for @commandResumeDevice.
  ///
  /// In en, this message translates to:
  /// **'Resume device'**
  String get commandResumeDevice;

  /// No description provided for @commandPauseInternet.
  ///
  /// In en, this message translates to:
  /// **'Pause internet'**
  String get commandPauseInternet;

  /// No description provided for @commandResumeInternet.
  ///
  /// In en, this message translates to:
  /// **'Resume internet'**
  String get commandResumeInternet;

  /// No description provided for @commandBonusTime.
  ///
  /// In en, this message translates to:
  /// **'Bonus time'**
  String get commandBonusTime;

  /// No description provided for @commandWindDown.
  ///
  /// In en, this message translates to:
  /// **'Wind down'**
  String get commandWindDown;

  /// No description provided for @commandLocateNow.
  ///
  /// In en, this message translates to:
  /// **'Locate now'**
  String get commandLocateNow;

  /// No description provided for @commandRulesUpdated.
  ///
  /// In en, this message translates to:
  /// **'Rules update'**
  String get commandRulesUpdated;

  /// No description provided for @commandConsentGranted.
  ///
  /// In en, this message translates to:
  /// **'Consent granted'**
  String get commandConsentGranted;

  /// No description provided for @commandConsentRevoked.
  ///
  /// In en, this message translates to:
  /// **'Consent revoked'**
  String get commandConsentRevoked;

  /// No description provided for @statusConfirmed.
  ///
  /// In en, this message translates to:
  /// **'Confirmed by device'**
  String get statusConfirmed;

  /// No description provided for @statusDelivered.
  ///
  /// In en, this message translates to:
  /// **'Delivered — awaiting device confirmation'**
  String get statusDelivered;

  /// No description provided for @statusFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed on device'**
  String get statusFailed;

  /// No description provided for @statusExpired.
  ///
  /// In en, this message translates to:
  /// **'Expired before delivery'**
  String get statusExpired;

  /// No description provided for @statusPending.
  ///
  /// In en, this message translates to:
  /// **'Pending — waiting for the device'**
  String get statusPending;

  /// No description provided for @alertsTitle.
  ///
  /// In en, this message translates to:
  /// **'Alerts'**
  String get alertsTitle;

  /// No description provided for @noAlertsYet.
  ///
  /// In en, this message translates to:
  /// **'No alerts yet'**
  String get noAlertsYet;

  /// No description provided for @loadMore.
  ///
  /// In en, this message translates to:
  /// **'Load more'**
  String get loadMore;

  /// No description provided for @acknowledgeFailed.
  ///
  /// In en, this message translates to:
  /// **'Acknowledge failed: {error}'**
  String acknowledgeFailed(String error);

  /// No description provided for @categoryLabel.
  ///
  /// In en, this message translates to:
  /// **'Category: {category}'**
  String categoryLabel(String category);

  /// No description provided for @severityLabel.
  ///
  /// In en, this message translates to:
  /// **'Severity: {severity}'**
  String severityLabel(String severity);

  /// No description provided for @timeLabel.
  ///
  /// In en, this message translates to:
  /// **'Time: {time}'**
  String timeLabel(String time);

  /// No description provided for @allowAction.
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get allowAction;

  /// No description provided for @blockThisApp.
  ///
  /// In en, this message translates to:
  /// **'Block this app'**
  String get blockThisApp;

  /// No description provided for @allowedSnack.
  ///
  /// In en, this message translates to:
  /// **'Allowed'**
  String get allowedSnack;

  /// No description provided for @appBlockedSnack.
  ///
  /// In en, this message translates to:
  /// **'App blocked'**
  String get appBlockedSnack;

  /// No description provided for @blockFailed.
  ///
  /// In en, this message translates to:
  /// **'Block failed: {error}'**
  String blockFailed(String error);

  /// No description provided for @severityCritical.
  ///
  /// In en, this message translates to:
  /// **'Critical'**
  String get severityCritical;

  /// No description provided for @severityWarning.
  ///
  /// In en, this message translates to:
  /// **'Warning'**
  String get severityWarning;

  /// No description provided for @severityInfo.
  ///
  /// In en, this message translates to:
  /// **'Info'**
  String get severityInfo;

  /// No description provided for @alertCategorySos.
  ///
  /// In en, this message translates to:
  /// **'SOS'**
  String get alertCategorySos;

  /// No description provided for @alertCategoryWebFilter.
  ///
  /// In en, this message translates to:
  /// **'Web filter'**
  String get alertCategoryWebFilter;

  /// No description provided for @alertCategoryScreenTime.
  ///
  /// In en, this message translates to:
  /// **'Screen time'**
  String get alertCategoryScreenTime;

  /// No description provided for @alertCategoryInstallRequest.
  ///
  /// In en, this message translates to:
  /// **'App install request'**
  String get alertCategoryInstallRequest;

  /// No description provided for @alertCategorySocialConcern.
  ///
  /// In en, this message translates to:
  /// **'Social concern'**
  String get alertCategorySocialConcern;

  /// No description provided for @alertCategoryLocation.
  ///
  /// In en, this message translates to:
  /// **'Location'**
  String get alertCategoryLocation;

  /// No description provided for @alertCategoryDevice.
  ///
  /// In en, this message translates to:
  /// **'Device'**
  String get alertCategoryDevice;

  /// No description provided for @alertCategorySafety.
  ///
  /// In en, this message translates to:
  /// **'Safety'**
  String get alertCategorySafety;

  /// No description provided for @tabScreenTime.
  ///
  /// In en, this message translates to:
  /// **'Screen time'**
  String get tabScreenTime;

  /// No description provided for @tabWebFilter.
  ///
  /// In en, this message translates to:
  /// **'Web filter'**
  String get tabWebFilter;

  /// No description provided for @tabRoutines.
  ///
  /// In en, this message translates to:
  /// **'Routines'**
  String get tabRoutines;

  /// No description provided for @dailyLimit.
  ///
  /// In en, this message translates to:
  /// **'Daily limit: {minutes} min'**
  String dailyLimit(int minutes);

  /// No description provided for @weekendLimit.
  ///
  /// In en, this message translates to:
  /// **'Weekend limit: {minutes} min'**
  String weekendLimit(int minutes);

  /// No description provided for @bedtime.
  ///
  /// In en, this message translates to:
  /// **'Bedtime'**
  String get bedtime;

  /// No description provided for @starts.
  ///
  /// In en, this message translates to:
  /// **'Starts'**
  String get starts;

  /// No description provided for @ends.
  ///
  /// In en, this message translates to:
  /// **'Ends'**
  String get ends;

  /// No description provided for @schoolHours.
  ///
  /// In en, this message translates to:
  /// **'School hours'**
  String get schoolHours;

  /// No description provided for @weekdayMon.
  ///
  /// In en, this message translates to:
  /// **'Mon'**
  String get weekdayMon;

  /// No description provided for @weekdayTue.
  ///
  /// In en, this message translates to:
  /// **'Tue'**
  String get weekdayTue;

  /// No description provided for @weekdayWed.
  ///
  /// In en, this message translates to:
  /// **'Wed'**
  String get weekdayWed;

  /// No description provided for @weekdayThu.
  ///
  /// In en, this message translates to:
  /// **'Thu'**
  String get weekdayThu;

  /// No description provided for @weekdayFri.
  ///
  /// In en, this message translates to:
  /// **'Fri'**
  String get weekdayFri;

  /// No description provided for @weekdaySat.
  ///
  /// In en, this message translates to:
  /// **'Sat'**
  String get weekdaySat;

  /// No description provided for @weekdaySun.
  ///
  /// In en, this message translates to:
  /// **'Sun'**
  String get weekdaySun;

  /// No description provided for @recommendedProtection.
  ///
  /// In en, this message translates to:
  /// **'Recommended protection'**
  String get recommendedProtection;

  /// No description provided for @recommendedProtectionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Block all 13 recommended categories'**
  String get recommendedProtectionSubtitle;

  /// No description provided for @disablingRecommended.
  ///
  /// In en, this message translates to:
  /// **'Disabling recommended categories reduces protection. Continue?'**
  String get disablingRecommended;

  /// No description provided for @blockedCategories.
  ///
  /// In en, this message translates to:
  /// **'Blocked categories'**
  String get blockedCategories;

  /// No description provided for @categoryPornography.
  ///
  /// In en, this message translates to:
  /// **'Pornography'**
  String get categoryPornography;

  /// No description provided for @categoryGambling.
  ///
  /// In en, this message translates to:
  /// **'Gambling'**
  String get categoryGambling;

  /// No description provided for @categoryDrugs.
  ///
  /// In en, this message translates to:
  /// **'Drugs'**
  String get categoryDrugs;

  /// No description provided for @categoryViolence.
  ///
  /// In en, this message translates to:
  /// **'Violence'**
  String get categoryViolence;

  /// No description provided for @categoryWeapons.
  ///
  /// In en, this message translates to:
  /// **'Weapons'**
  String get categoryWeapons;

  /// No description provided for @categoryHate.
  ///
  /// In en, this message translates to:
  /// **'Hate speech'**
  String get categoryHate;

  /// No description provided for @categorySelfHarm.
  ///
  /// In en, this message translates to:
  /// **'Self-harm'**
  String get categorySelfHarm;

  /// No description provided for @categoryDating.
  ///
  /// In en, this message translates to:
  /// **'Dating'**
  String get categoryDating;

  /// No description provided for @categorySocialMediaNsfw.
  ///
  /// In en, this message translates to:
  /// **'NSFW social media'**
  String get categorySocialMediaNsfw;

  /// No description provided for @categoryChatRandom.
  ///
  /// In en, this message translates to:
  /// **'Random chat'**
  String get categoryChatRandom;

  /// No description provided for @categoryProxiesVpn.
  ///
  /// In en, this message translates to:
  /// **'Proxies & VPN'**
  String get categoryProxiesVpn;

  /// No description provided for @categoryWarez.
  ///
  /// In en, this message translates to:
  /// **'Piracy'**
  String get categoryWarez;

  /// No description provided for @categoryAiChatbots.
  ///
  /// In en, this message translates to:
  /// **'AI chatbots'**
  String get categoryAiChatbots;

  /// No description provided for @categorySocialMedia.
  ///
  /// In en, this message translates to:
  /// **'Social media'**
  String get categorySocialMedia;

  /// No description provided for @categoryChat.
  ///
  /// In en, this message translates to:
  /// **'Chat'**
  String get categoryChat;

  /// No description provided for @allowedDomainsLabel.
  ///
  /// In en, this message translates to:
  /// **'Allowed domains (comma-separated)'**
  String get allowedDomainsLabel;

  /// No description provided for @blockedDomainsLabel.
  ///
  /// In en, this message translates to:
  /// **'Blocked domains (comma-separated)'**
  String get blockedDomainsLabel;

  /// No description provided for @enforceSafeSearch.
  ///
  /// In en, this message translates to:
  /// **'Enforce SafeSearch'**
  String get enforceSafeSearch;

  /// No description provided for @youtubeRestrictedMode.
  ///
  /// In en, this message translates to:
  /// **'YouTube Restricted Mode'**
  String get youtubeRestrictedMode;

  /// No description provided for @youtubeRestrictedDesc.
  ///
  /// In en, this message translates to:
  /// **'Filters out potentially mature content on YouTube across child devices.'**
  String get youtubeRestrictedDesc;

  /// No description provided for @strict.
  ///
  /// In en, this message translates to:
  /// **'Strict'**
  String get strict;

  /// No description provided for @moderate.
  ///
  /// In en, this message translates to:
  /// **'Moderate'**
  String get moderate;

  /// No description provided for @off.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get off;

  /// No description provided for @alwaysAllowed.
  ///
  /// In en, this message translates to:
  /// **'Always allowed'**
  String get alwaysAllowed;

  /// No description provided for @alwaysAllowedDesc.
  ///
  /// In en, this message translates to:
  /// **'These apps stay open during bedtime, school time, pause and routines.'**
  String get alwaysAllowedDesc;

  /// No description provided for @noAlwaysAllowedApps.
  ///
  /// In en, this message translates to:
  /// **'No always-allowed apps yet'**
  String get noAlwaysAllowedApps;

  /// No description provided for @addApp.
  ///
  /// In en, this message translates to:
  /// **'Add app'**
  String get addApp;

  /// No description provided for @addAppRule.
  ///
  /// In en, this message translates to:
  /// **'Add app rule'**
  String get addAppRule;

  /// No description provided for @addAlwaysAllowedTitle.
  ///
  /// In en, this message translates to:
  /// **'Add always-allowed app'**
  String get addAlwaysAllowedTitle;

  /// No description provided for @appNameLabel.
  ///
  /// In en, this message translates to:
  /// **'App name'**
  String get appNameLabel;

  /// No description provided for @packageIdLabel.
  ///
  /// In en, this message translates to:
  /// **'Package ID (e.g. com.example.app)'**
  String get packageIdLabel;

  /// No description provided for @limitPerDayLabel.
  ///
  /// In en, this message translates to:
  /// **'Limit (minutes/day)'**
  String get limitPerDayLabel;

  /// No description provided for @addRoutine.
  ///
  /// In en, this message translates to:
  /// **'Add routine'**
  String get addRoutine;

  /// No description provided for @editRoutine.
  ///
  /// In en, this message translates to:
  /// **'Edit routine'**
  String get editRoutine;

  /// No description provided for @nameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get nameLabel;

  /// No description provided for @startTimeButton.
  ///
  /// In en, this message translates to:
  /// **'Start {time}'**
  String startTimeButton(String time);

  /// No description provided for @endTimeButton.
  ///
  /// In en, this message translates to:
  /// **'End {time}'**
  String endTimeButton(String time);

  /// No description provided for @blockedAppsLabel.
  ///
  /// In en, this message translates to:
  /// **'Blocked apps (comma-separated)'**
  String get blockedAppsLabel;

  /// No description provided for @allowedAppsLabel.
  ///
  /// In en, this message translates to:
  /// **'Allowed apps (comma-separated)'**
  String get allowedAppsLabel;

  /// No description provided for @rulesSaved.
  ///
  /// In en, this message translates to:
  /// **'Rules saved'**
  String get rulesSaved;

  /// No description provided for @reportsTitle.
  ///
  /// In en, this message translates to:
  /// **'Reports'**
  String get reportsTitle;

  /// No description provided for @screenTimeWebHistoryTooltip.
  ///
  /// In en, this message translates to:
  /// **'Screen time & web history'**
  String get screenTimeWebHistoryTooltip;

  /// No description provided for @sevenDays.
  ///
  /// In en, this message translates to:
  /// **'7 days'**
  String get sevenDays;

  /// No description provided for @thirtyDays.
  ///
  /// In en, this message translates to:
  /// **'30 days'**
  String get thirtyDays;

  /// No description provided for @reportLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load report: {error}'**
  String reportLoadFailed(String error);

  /// No description provided for @noActivityDays.
  ///
  /// In en, this message translates to:
  /// **'{days, plural, =1{No activity recorded in the last day} other{No activity recorded in the last {days} days}}'**
  String noActivityDays(int days);

  /// No description provided for @appUsage.
  ///
  /// In en, this message translates to:
  /// **'App usage'**
  String get appUsage;

  /// No description provided for @totalAverage.
  ///
  /// In en, this message translates to:
  /// **'Total {total} min · avg {avg} min/day'**
  String totalAverage(int total, int avg);

  /// No description provided for @noAppUsage.
  ///
  /// In en, this message translates to:
  /// **'No app usage recorded'**
  String get noAppUsage;

  /// No description provided for @webSection.
  ///
  /// In en, this message translates to:
  /// **'Web'**
  String get webSection;

  /// No description provided for @urlVisits.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No URL visits} =1{1 URL visit} other{{count} URL visits}}'**
  String urlVisits(int count);

  /// No description provided for @noBlockedDomains.
  ///
  /// In en, this message translates to:
  /// **'No blocked domains'**
  String get noBlockedDomains;

  /// No description provided for @blockedTimes.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{blocked once} other{{count}× blocked}}'**
  String blockedTimes(int count);

  /// No description provided for @safeSearchForced.
  ///
  /// In en, this message translates to:
  /// **'YouTube search is forced to SafeSearch'**
  String get safeSearchForced;

  /// No description provided for @restrictedModeNote.
  ///
  /// In en, this message translates to:
  /// **'Restricted Mode needs HTTPS inspection on the child PC (see guide)'**
  String get restrictedModeNote;

  /// No description provided for @socialAndCommunication.
  ///
  /// In en, this message translates to:
  /// **'Social & communication'**
  String get socialAndCommunication;

  /// No description provided for @socialConcerns.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No social concerns} =1{1 social concern} other{{count} social concerns}}'**
  String socialConcerns(int count);

  /// No description provided for @callsCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No calls} =1{1 call} other{{count} calls}}'**
  String callsCount(int count);

  /// No description provided for @smsCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No SMS} =1{1 SMS} other{{count} SMS}}'**
  String smsCount(int count);

  /// No description provided for @screenTimeWebTitle.
  ///
  /// In en, this message translates to:
  /// **'Screen time & web'**
  String get screenTimeWebTitle;

  /// No description provided for @daysShort.
  ///
  /// In en, this message translates to:
  /// **'{days}d'**
  String daysShort(int days);

  /// No description provided for @couldNotLoadScreenTime.
  ///
  /// In en, this message translates to:
  /// **'Could not load screen time'**
  String get couldNotLoadScreenTime;

  /// No description provided for @noScreenTimeData.
  ///
  /// In en, this message translates to:
  /// **'{days, plural, =1{No screen time data in the last day} other{No screen time data in the last {days} days}}'**
  String noScreenTimeData(int days);

  /// No description provided for @noScreenTimeRecorded.
  ///
  /// In en, this message translates to:
  /// **'{days, plural, =1{No screen time recorded in the last day} other{No screen time recorded in the last {days} days}}'**
  String noScreenTimeRecorded(int days);

  /// No description provided for @totalOverDays.
  ///
  /// In en, this message translates to:
  /// **'Total {total} min over {count, plural, =1{1 day} other{{count} days}}'**
  String totalOverDays(int total, int count);

  /// No description provided for @fewerDaysReturned.
  ///
  /// In en, this message translates to:
  /// **'Only {returned} of the {requested} requested days were returned; showing those days as-is.'**
  String fewerDaysReturned(int returned, int requested);

  /// No description provided for @dayByDay.
  ///
  /// In en, this message translates to:
  /// **'Day by day'**
  String get dayByDay;

  /// No description provided for @browsingHistory.
  ///
  /// In en, this message translates to:
  /// **'Browsing history'**
  String get browsingHistory;

  /// No description provided for @blockedOnly.
  ///
  /// In en, this message translates to:
  /// **'Blocked only'**
  String get blockedOnly;

  /// No description provided for @showLabel.
  ///
  /// In en, this message translates to:
  /// **'Show'**
  String get showLabel;

  /// No description provided for @couldNotLoadBrowsing.
  ///
  /// In en, this message translates to:
  /// **'Could not load browsing history'**
  String get couldNotLoadBrowsing;

  /// No description provided for @noBlockedSites.
  ///
  /// In en, this message translates to:
  /// **'{days, plural, =1{No blocked sites in the last day} other{No blocked sites in the last {days} days}}'**
  String noBlockedSites(int days);

  /// No description provided for @noBrowsingHistory.
  ///
  /// In en, this message translates to:
  /// **'{days, plural, =1{No browsing history in the last day} other{No browsing history in the last {days} days}}'**
  String noBrowsingHistory(int days);

  /// No description provided for @showingLatestVisits.
  ///
  /// In en, this message translates to:
  /// **'Showing the latest {limit} visits — raise the limit to see more.'**
  String showingLatestVisits(int limit);

  /// No description provided for @blocked.
  ///
  /// In en, this message translates to:
  /// **'Blocked'**
  String get blocked;

  /// No description provided for @allowed.
  ///
  /// In en, this message translates to:
  /// **'Allowed'**
  String get allowed;

  /// No description provided for @dayTooltip.
  ///
  /// In en, this message translates to:
  /// **'{date}: {minutes} min'**
  String dayTooltip(String date, int minutes);

  /// No description provided for @scanQr.
  ///
  /// In en, this message translates to:
  /// **'Scan this QR code with the OSRA child app.'**
  String get scanQr;

  /// No description provided for @typeSixDigit.
  ///
  /// In en, this message translates to:
  /// **'If the camera cannot scan it, type the 6-digit code below on the child device.'**
  String get typeSixDigit;

  /// No description provided for @codeExpired.
  ///
  /// In en, this message translates to:
  /// **'Code expired'**
  String get codeExpired;

  /// No description provided for @generateNewCode.
  ///
  /// In en, this message translates to:
  /// **'Generate a new code to keep pairing.'**
  String get generateNewCode;

  /// No description provided for @pairingQrSemantics.
  ///
  /// In en, this message translates to:
  /// **'Pairing QR code for {code}'**
  String pairingQrSemantics(String code);

  /// No description provided for @expiresIn.
  ///
  /// In en, this message translates to:
  /// **'Expires in {time}'**
  String expiresIn(String time);

  /// No description provided for @regenerate.
  ///
  /// In en, this message translates to:
  /// **'Regenerate'**
  String get regenerate;

  /// No description provided for @copyCode.
  ///
  /// In en, this message translates to:
  /// **'Copy code'**
  String get copyCode;

  /// No description provided for @codeCopied.
  ///
  /// In en, this message translates to:
  /// **'Code copied'**
  String get codeCopied;

  /// No description provided for @codeWorksOnce.
  ///
  /// In en, this message translates to:
  /// **'{minutes, plural, =1{The code works once and expires after 1 minute.} other{The code works once and expires after {minutes} minutes.}}'**
  String codeWorksOnce(int minutes);

  /// No description provided for @pairCodeError.
  ///
  /// In en, this message translates to:
  /// **'The server did not return a usable pairing code. Try Regenerate.'**
  String get pairCodeError;

  /// No description provided for @pairCreateError.
  ///
  /// In en, this message translates to:
  /// **'Could not create a pairing code. Check the connection and try again.'**
  String get pairCreateError;

  /// No description provided for @appearanceTitle.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearanceTitle;

  /// No description provided for @themeLabel.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get themeLabel;

  /// No description provided for @appearanceDesc.
  ///
  /// In en, this message translates to:
  /// **'System follows this device. Light or Dark overrides it for OSRA only.'**
  String get appearanceDesc;

  /// No description provided for @followingDevice.
  ///
  /// In en, this message translates to:
  /// **'Following the device (currently {mode}).'**
  String followingDevice(String mode);

  /// No description provided for @lightAlwaysOn.
  ///
  /// In en, this message translates to:
  /// **'Light theme is always on.'**
  String get lightAlwaysOn;

  /// No description provided for @darkAlwaysOn.
  ///
  /// In en, this message translates to:
  /// **'Dark theme is always on.'**
  String get darkAlwaysOn;

  /// No description provided for @languageLabel.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get languageLabel;

  /// No description provided for @languageDesc.
  ///
  /// In en, this message translates to:
  /// **'System follows this device. English or Arabic overrides it for OSRA only.'**
  String get languageDesc;

  /// No description provided for @followingLanguage.
  ///
  /// In en, this message translates to:
  /// **'Following the device (currently {language}).'**
  String followingLanguage(String language);

  /// No description provided for @englishAlwaysOn.
  ///
  /// In en, this message translates to:
  /// **'English is always on.'**
  String get englishAlwaysOn;

  /// No description provided for @arabicAlwaysOn.
  ///
  /// In en, this message translates to:
  /// **'Arabic is always on.'**
  String get arabicAlwaysOn;

  /// No description provided for @monitoring.
  ///
  /// In en, this message translates to:
  /// **'Monitoring'**
  String get monitoring;

  /// No description provided for @monitoringSaved.
  ///
  /// In en, this message translates to:
  /// **'Monitoring saved'**
  String get monitoringSaved;

  /// No description provided for @saveFailed.
  ///
  /// In en, this message translates to:
  /// **'Save failed: {error}'**
  String saveFailed(String error);

  /// No description provided for @saveMonitoring.
  ///
  /// In en, this message translates to:
  /// **'Save monitoring'**
  String get saveMonitoring;

  /// No description provided for @concerns.
  ///
  /// In en, this message translates to:
  /// **'Concerns'**
  String get concerns;

  /// No description provided for @vaultTrustCopy.
  ///
  /// In en, this message translates to:
  /// **'Snippets are encrypted with your family key before leaving the device and stored encrypted on your server.'**
  String get vaultTrustCopy;

  /// No description provided for @noConcernsDetected.
  ///
  /// In en, this message translates to:
  /// **'No concerns detected'**
  String get noConcernsDetected;

  /// No description provided for @unknownContact.
  ///
  /// In en, this message translates to:
  /// **'Unknown contact'**
  String get unknownContact;

  /// No description provided for @unknownApp.
  ///
  /// In en, this message translates to:
  /// **'Unknown app'**
  String get unknownApp;

  /// No description provided for @noPreviewAvailable.
  ///
  /// In en, this message translates to:
  /// **'No preview available'**
  String get noPreviewAvailable;

  /// No description provided for @viewInDecryptionVault.
  ///
  /// In en, this message translates to:
  /// **'View in Decryption Vault'**
  String get viewInDecryptionVault;

  /// No description provided for @socialMessage.
  ///
  /// In en, this message translates to:
  /// **'Social message'**
  String get socialMessage;

  /// No description provided for @callsAndTexts.
  ///
  /// In en, this message translates to:
  /// **'Calls & texts'**
  String get callsAndTexts;

  /// No description provided for @iosNoCallMonitoring.
  ///
  /// In en, this message translates to:
  /// **'iOS does not support call/text monitoring.'**
  String get iosNoCallMonitoring;

  /// No description provided for @noCallsOrTexts.
  ///
  /// In en, this message translates to:
  /// **'No calls or texts yet'**
  String get noCallsOrTexts;

  /// No description provided for @unknownNumber.
  ///
  /// In en, this message translates to:
  /// **'Unknown number'**
  String get unknownNumber;

  /// No description provided for @trustedContacts.
  ///
  /// In en, this message translates to:
  /// **'Trusted contacts'**
  String get trustedContacts;

  /// No description provided for @trustedContactsDesc.
  ///
  /// In en, this message translates to:
  /// **'Numbers here never raise social concerns.'**
  String get trustedContactsDesc;

  /// No description provided for @phoneNumberLabel.
  ///
  /// In en, this message translates to:
  /// **'Phone number'**
  String get phoneNumberLabel;

  /// No description provided for @saveAllowlist.
  ///
  /// In en, this message translates to:
  /// **'Save allowlist'**
  String get saveAllowlist;

  /// No description provided for @allowlistSaved.
  ///
  /// In en, this message translates to:
  /// **'Allowlist saved'**
  String get allowlistSaved;

  /// No description provided for @relativeJustNow.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get relativeJustNow;

  /// No description provided for @relativeMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{count}m ago'**
  String relativeMinutesAgo(int count);

  /// No description provided for @relativeHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{count}h ago'**
  String relativeHoursAgo(int count);

  /// No description provided for @relativeDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'{count}d ago'**
  String relativeDaysAgo(int count);

  /// No description provided for @decryptedVaultContent.
  ///
  /// In en, this message translates to:
  /// **'Decrypted Vault Content'**
  String get decryptedVaultContent;

  /// No description provided for @encryptedFamilyVault.
  ///
  /// In en, this message translates to:
  /// **'Encrypted Family Vault'**
  String get encryptedFamilyVault;

  /// No description provided for @vaultEncryptionDesc.
  ///
  /// In en, this message translates to:
  /// **'Protected by AES-256-GCM encryption. Decrypted on-demand for authenticated guardians only.'**
  String get vaultEncryptionDesc;

  /// No description provided for @decryptedContent.
  ///
  /// In en, this message translates to:
  /// **'Decrypted content'**
  String get decryptedContent;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @contentCopied.
  ///
  /// In en, this message translates to:
  /// **'Content copied to clipboard'**
  String get contentCopied;

  /// No description provided for @noPreviewContent.
  ///
  /// In en, this message translates to:
  /// **'No preview content available'**
  String get noPreviewContent;

  /// No description provided for @detectedConcernTypes.
  ///
  /// In en, this message translates to:
  /// **'Detected concern types'**
  String get detectedConcernTypes;

  /// No description provided for @commandDeliveryTitle.
  ///
  /// In en, this message translates to:
  /// **'Command delivery'**
  String get commandDeliveryTitle;

  /// No description provided for @couldNotLoadChild.
  ///
  /// In en, this message translates to:
  /// **'Could not load this child'**
  String get couldNotLoadChild;

  /// No description provided for @noDevicesForChild.
  ///
  /// In en, this message translates to:
  /// **'No devices registered for this child'**
  String get noDevicesForChild;

  /// No description provided for @deliveryExplanation.
  ///
  /// In en, this message translates to:
  /// **'A command is confirmed only when the child device reports back. Delivered means the device collected it; it has not confirmed it ran.'**
  String get deliveryExplanation;

  /// No description provided for @couldNotLoadCommandHistory.
  ///
  /// In en, this message translates to:
  /// **'Could not load command history'**
  String get couldNotLoadCommandHistory;

  /// No description provided for @createdEvent.
  ///
  /// In en, this message translates to:
  /// **'Created {time}'**
  String createdEvent(String time);

  /// No description provided for @deliveredEvent.
  ///
  /// In en, this message translates to:
  /// **'Delivered {time}'**
  String deliveredEvent(String time);

  /// No description provided for @confirmedEvent.
  ///
  /// In en, this message translates to:
  /// **'Confirmed {time}'**
  String confirmedEvent(String time);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['ar', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return AppLocalizationsAr();
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
