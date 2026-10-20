// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Arabic (`ar`).
class AppLocalizationsAr extends AppLocalizations {
  AppLocalizationsAr([String locale = 'ar']) : super(locale);

  @override
  String get appName => 'OSRA';

  @override
  String get cancel => 'إلغاء';

  @override
  String get save => 'حفظ';

  @override
  String get add => 'إضافة';

  @override
  String get continueLabel => 'متابعة';

  @override
  String get close => 'إغلاق';

  @override
  String get tryAgain => 'المحاولة مرة أخرى';

  @override
  String get retry => 'إعادة المحاولة';

  @override
  String get dismiss => 'تجاهل';

  @override
  String get system => 'النظام';

  @override
  String get light => 'فاتح';

  @override
  String get dark => 'داكن';

  @override
  String get english => 'الإنجليزية';

  @override
  String get arabic => 'العربية';

  @override
  String get unknown => 'غير معروف';

  @override
  String get never => 'أبدًا';

  @override
  String get timeUnknown => 'الوقت غير معروف';

  @override
  String get saving => 'جارٍ الحفظ…';

  @override
  String minutesShort(int minutes) {
    return '$minutes دقيقة';
  }

  @override
  String get appTagline => 'أسرة — رقابة أبوية لعائلتك';

  @override
  String get serverLabel => 'الخادم';

  @override
  String get serverHint => 'http://host:port';

  @override
  String serverShown(String url) {
    return 'الخادم: $url';
  }

  @override
  String get invalidServer =>
      'أدخل عنوان خادم صالحًا، مثل http://192.168.1.5:3000';

  @override
  String get emailLabel => 'البريد الإلكتروني';

  @override
  String get passwordLabel => 'كلمة المرور';

  @override
  String get mfaCodeLabel => 'رمز المصادقة (عند تفعيل المصادقة الثنائية)';

  @override
  String get signIn => 'تسجيل الدخول';

  @override
  String get createAccount => 'إنشاء حساب';

  @override
  String get familyNameLabel => 'اسم العائلة';

  @override
  String get yourNameLabel => 'اسمك';

  @override
  String get regionLabel => 'المنطقة';

  @override
  String get regionUS => 'الولايات المتحدة';

  @override
  String get regionEU => 'الاتحاد الأوروبي';

  @override
  String get regionUK => 'المملكة المتحدة';

  @override
  String get regionOther => 'أخرى';

  @override
  String get register => 'تسجيل';

  @override
  String get familyMapTooltip => 'خريطة العائلة';

  @override
  String get alertsTooltip => 'التنبيهات';

  @override
  String get familyMembersMenu => 'أفراد العائلة';

  @override
  String get appearanceMenu => 'المظهر';

  @override
  String get digestPreferencesMenu => 'تفضيلات الملخص';

  @override
  String get signOutTooltip => 'تسجيل الخروج';

  @override
  String familyLoadFailed(String error) {
    return 'تعذّر تحميل العائلة: $error';
  }

  @override
  String get noChildrenYet => 'لا يوجد أطفال بعد — اضغط «إضافة طفل»';

  @override
  String get addChild => 'إضافة طفل';

  @override
  String get statusOnline => 'متصل';

  @override
  String get statusOffline => 'غير متصل';

  @override
  String get noLocationYet => 'لا يوجد موقع بعد';

  @override
  String get screenTime => 'وقت الشاشة';

  @override
  String screenTimeValue(int minutes, String limit) {
    return '$minutes / $limit دقيقة';
  }

  @override
  String liveActivityToday(String app, int minutes) {
    return '$app · $minutes دقيقة اليوم';
  }

  @override
  String wellbeingScore(int score) {
    return 'الرفاهية $score/100';
  }

  @override
  String get wellbeingUsage => 'الاستخدام';

  @override
  String get wellbeingSocial => 'التواصل';

  @override
  String get wellbeingSafety => 'السلامة';

  @override
  String get paused => 'موقوف';

  @override
  String get internet => 'الإنترنت';

  @override
  String pauseInternetTitle(String name) {
    return 'إيقاف الإنترنت مؤقتًا لـ$name؟';
  }

  @override
  String resumeInternetTitle(String name) {
    return 'استئناف الإنترنت لـ$name؟';
  }

  @override
  String get pauseInternetBody => 'تظل التطبيقات التعليمية تعمل.';

  @override
  String get resumeInternetBody => 'ستعمل جميع التطبيقات والمواقع مرة أخرى.';

  @override
  String get pause => 'إيقاف';

  @override
  String get resume => 'استئناف';

  @override
  String internetChangeFailed(String error) {
    return 'فشل تغيير حالة الإنترنت: $error';
  }

  @override
  String get parentalConsent => 'موافقة الوالدين';

  @override
  String get childDetails => 'بيانات الطفل';

  @override
  String get consentNotice =>
      'Verifiable parental consent is required before adding a child (COPPA/GDPR-K).';

  @override
  String get consentMethodLabel => 'طريقة الموافقة';

  @override
  String get consentMethodSmsPlus => 'رسالة نصية +';

  @override
  String get consentMethodKba => 'أسئلة معرفية';

  @override
  String get consentMethodFaceMatch => 'مطابقة الوجه';

  @override
  String get consentMethodCreditCard => 'بطاقة ائتمان';

  @override
  String get jurisdictionLabel => 'الاختصاص القضائي';

  @override
  String get childNameLabel => 'اسم الطفل';

  @override
  String get birthYearLabel => 'سنة الميلاد';

  @override
  String get childFallback => 'الطفل';

  @override
  String get tabOverview => 'نظرة عامة';

  @override
  String get tabApps => 'التطبيقات';

  @override
  String get tabSocial => 'التواصل';

  @override
  String get tabLocation => 'الموقع';

  @override
  String get tabAlerts => 'التنبيهات';

  @override
  String get reportsTooltip => 'التقارير';

  @override
  String get searchSafetyTooltip => 'أمان البحث والويب';

  @override
  String get editRules => 'تعديل القواعد';

  @override
  String bornYear(int year) {
    return 'مواليد $year';
  }

  @override
  String get socialMonitoringTitle => 'مراقبة التواصل الاجتماعي';

  @override
  String get devices => 'الأجهزة';

  @override
  String get pairADevice => 'إقران جهاز';

  @override
  String get noDevicesRegistered => 'لا توجد أجهزة مسجّلة';

  @override
  String lastSeenLabel(String time) {
    return 'آخر ظهور: $time';
  }

  @override
  String get deliveryStatus => 'حالة التسليم';

  @override
  String get ring => 'رن';

  @override
  String get lock => 'قفل';

  @override
  String get unlock => 'فتح القفل';

  @override
  String get pauseNet => 'إيقاف الشبكة';

  @override
  String get resumeNet => 'استئناف الشبكة';

  @override
  String get checkingCommandDelivery => 'جارٍ التحقق من تسليم الأمر…';

  @override
  String get commandDeliveryUnavailable => 'حالة تسليم الأوامر غير متاحة';

  @override
  String get noCommandsYet => 'لا توجد أوامر بعد';

  @override
  String latestCommand(String type, String status, String time) {
    return 'الأحدث: $type · $status · $time';
  }

  @override
  String get bonusTime => 'وقت إضافي';

  @override
  String get extraScreenTimeToday => 'وقت شاشة إضافي لليوم فقط';

  @override
  String bonusGranted(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: 'مُنحت $minutes دقيقة إضافية اليوم',
      many: 'مُنحت $minutes دقيقة إضافية اليوم',
      few: 'مُنحت $minutes دقائق إضافية اليوم',
      two: 'مُنحت دقيقتان إضافيتان اليوم',
      one: 'مُنحت دقيقة إضافية واحدة اليوم',
    );
    return '$_temp0';
  }

  @override
  String bonusFailed(String error) {
    return 'فشل منح الوقت الإضافي: $error';
  }

  @override
  String get windDown => 'الاسترخاء قبل النوم';

  @override
  String get windDownBody => 'يعرض الجهاز تنبيهًا لطيفًا للنوم، ثم يُقفل.';

  @override
  String get windDownSubtitle => 'تنبيه لطيف، ثم تُقفل الشاشة';

  @override
  String windDownConfirm(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: 'ستُقفل الشاشة على الجهاز بعد $minutes دقيقة',
      many: 'ستُقفل الشاشة على الجهاز بعد $minutes دقيقة',
      few: 'ستُقفل الشاشة على الجهاز بعد $minutes دقائق',
      two: 'ستُقفل الشاشة على الجهاز بعد دقيقتين',
      one: 'ستُقفل الشاشة على الجهاز بعد دقيقة واحدة',
    );
    return '$_temp0';
  }

  @override
  String windDownFailed(String error) {
    return 'فشل بدء الاسترخاء: $error';
  }

  @override
  String commandQueued(String command, String device) {
    return 'تم وضع «$command» في قائمة الانتظار لـ$device — لم يؤكّد الجهاز تنفيذه بعد.';
  }

  @override
  String netQueued(String action, String device) {
    return 'تم وضع «$action» في قائمة الانتظار لـ$device — لم يؤكّد الجهاز تنفيذه بعد.';
  }

  @override
  String commandFailed(String error) {
    return 'فشل الأمر: $error';
  }

  @override
  String commandRefusedBackgroundLocation(String command, String device) {
    return 'لم يُرسل «$command» إلى $device: لم يمنح الهاتف إذن الموقع «السماح دائمًا»، لذا لا يمكن لطلب تحديد الموقع وتنبيهات النطاقات الجغرافية الوصول إليه. اطلب من طفلك فتح OSRA ومنح الإذن.';
  }

  @override
  String commandRefusedLocationPermission(String command, String device) {
    return 'لم يُرسل «$command» إلى $device: لا يوجد إذن موقع على الهاتف. اطلب من طفلك فتح OSRA ومنح إذن الموقع.';
  }

  @override
  String rulesLoadFailed(String error) {
    return 'تعذّر تحميل القواعد: $error';
  }

  @override
  String get noPerAppRules => 'لا توجد قواعد لكل تطبيق';

  @override
  String get appActionBlock => 'حظر';

  @override
  String get appActionTimeLimit => 'حد زمني';

  @override
  String get appActionAllow => 'سماح';

  @override
  String locationLoadFailed(String error) {
    return 'تعذّر تحميل الموقع: $error';
  }

  @override
  String get noLocationReported => 'لم يُبلَّغ عن أي موقع بعد';

  @override
  String accuracyLabel(int meters, String time) {
    return 'الدقة ±$meters م · $time';
  }

  @override
  String get mapPreview => 'معاينة الخريطة';

  @override
  String locationHistoryLoadFailed(String error) {
    return 'تعذّر تحميل السجل: $error';
  }

  @override
  String get noLocationHistoryToday => 'لا يوجد سجل مواقع لليوم';

  @override
  String get todaysRoute => 'مسار اليوم';

  @override
  String get back15Tooltip => 'رجوع 15 دقيقة';

  @override
  String get forward15Tooltip => 'تقدّم 15 دقيقة';

  @override
  String get accuracyUnknown => 'الدقة غير معروفة';

  @override
  String alertsLoadFailed(String error) {
    return 'تعذّر تحميل التنبيهات: $error';
  }

  @override
  String get noRecentAlerts => 'لا توجد تنبيهات حديثة';

  @override
  String get acknowledgeTooltip => 'تأكيد الاستلام';

  @override
  String ageRating(String rating) {
    return 'التصنيف العمري: $rating';
  }

  @override
  String get risks => 'المخاطر';

  @override
  String get saferAlternatives => 'بدائل أكثر أمانًا';

  @override
  String get noInsightsYet => 'لا توجد رؤى لهذا التطبيق بعد';

  @override
  String insightsLoadFailed(String error) {
    return 'تعذّر تحميل الرؤى: $error';
  }

  @override
  String get commandLock => 'قفل';

  @override
  String get commandUnlock => 'فتح القفل';

  @override
  String get commandRing => 'رن';

  @override
  String get commandStopRing => 'إيقاف الرنين';

  @override
  String get commandClearSos => 'مسح نداء الاستغاثة';

  @override
  String get commandPauseDevice => 'إيقاف الجهاز';

  @override
  String get commandResumeDevice => 'استئناف الجهاز';

  @override
  String get commandPauseInternet => 'إيقاف الإنترنت';

  @override
  String get commandResumeInternet => 'استئناف الإنترنت';

  @override
  String get commandBonusTime => 'وقت إضافي';

  @override
  String get commandWindDown => 'الاسترخاء قبل النوم';

  @override
  String get commandLocateNow => 'تحديد الموقع الآن';

  @override
  String get commandRulesUpdated => 'تحديث القواعد';

  @override
  String get commandConsentGranted => 'منح الموافقة';

  @override
  String get commandConsentRevoked => 'سحب الموافقة';

  @override
  String get statusConfirmed => 'أكّده الجهاز';

  @override
  String get statusDelivered => 'تم التسليم — بانتظار تأكيد الجهاز';

  @override
  String get statusFailed => 'فشل على الجهاز';

  @override
  String get statusExpired => 'انتهت صلاحيته قبل التسليم';

  @override
  String get statusPending => 'قيد الانتظار — في انتظار الجهاز';

  @override
  String get alertsTitle => 'التنبيهات';

  @override
  String get noAlertsYet => 'لا توجد تنبيهات بعد';

  @override
  String get loadMore => 'تحميل المزيد';

  @override
  String acknowledgeFailed(String error) {
    return 'فشل تأكيد الاستلام: $error';
  }

  @override
  String categoryLabel(String category) {
    return 'الفئة: $category';
  }

  @override
  String severityLabel(String severity) {
    return 'الخطورة: $severity';
  }

  @override
  String timeLabel(String time) {
    return 'الوقت: $time';
  }

  @override
  String get allowAction => 'سماح';

  @override
  String get blockThisApp => 'حظر هذا التطبيق';

  @override
  String get allowedSnack => 'تم السماح';

  @override
  String get appBlockedSnack => 'تم حظر التطبيق';

  @override
  String blockFailed(String error) {
    return 'فشل الحظر: $error';
  }

  @override
  String get severityCritical => 'حرج';

  @override
  String get severityWarning => 'تحذير';

  @override
  String get severityInfo => 'معلومة';

  @override
  String get alertCategorySos => 'استغاثة';

  @override
  String get alertCategoryWebFilter => 'تصفية الويب';

  @override
  String get alertCategoryScreenTime => 'وقت الشاشة';

  @override
  String get alertCategoryInstallRequest => 'طلب تثبيت تطبيق';

  @override
  String get alertCategorySocialConcern => 'مخاوف اجتماعية';

  @override
  String get alertCategoryLocation => 'الموقع';

  @override
  String get alertCategoryDevice => 'الجهاز';

  @override
  String get alertCategorySafety => 'السلامة';

  @override
  String get tabScreenTime => 'وقت الشاشة';

  @override
  String get tabWebFilter => 'تصفية الويب';

  @override
  String get tabRoutines => 'الروتين';

  @override
  String dailyLimit(int minutes) {
    return 'الحد اليومي: $minutes دقيقة';
  }

  @override
  String weekendLimit(int minutes) {
    return 'حد عطلة نهاية الأسبوع: $minutes دقيقة';
  }

  @override
  String get bedtime => 'وقت النوم';

  @override
  String get starts => 'يبدأ';

  @override
  String get ends => 'ينتهي';

  @override
  String get schoolHours => 'الساعات المدرسية';

  @override
  String get weekdayMon => 'الاثنين';

  @override
  String get weekdayTue => 'الثلاثاء';

  @override
  String get weekdayWed => 'الأربعاء';

  @override
  String get weekdayThu => 'الخميس';

  @override
  String get weekdayFri => 'الجمعة';

  @override
  String get weekdaySat => 'السبت';

  @override
  String get weekdaySun => 'الأحد';

  @override
  String get recommendedProtection => 'الحماية الموصى بها';

  @override
  String get recommendedProtectionSubtitle =>
      'حظر جميع الفئات الـ13 الموصى بها';

  @override
  String get disablingRecommended =>
      'تعطيل الفئات الموصى بها يقلّل الحماية. هل تريد المتابعة؟';

  @override
  String get blockedCategories => 'الفئات المحظورة';

  @override
  String get categoryPornography => 'الإباحية';

  @override
  String get categoryGambling => 'المقامرة';

  @override
  String get categoryDrugs => 'المخدرات';

  @override
  String get categoryViolence => 'العنف';

  @override
  String get categoryWeapons => 'الأسلحة';

  @override
  String get categoryHate => 'خطاب الكراهية';

  @override
  String get categorySelfHarm => 'إيذاء النفس';

  @override
  String get categoryDating => 'المواعدة';

  @override
  String get categorySocialMediaNsfw => 'وسائل تواصل غير لائقة';

  @override
  String get categoryChatRandom => 'دردشة عشوائية';

  @override
  String get categoryProxiesVpn => 'الوكلاء وشبكات VPN';

  @override
  String get categoryWarez => 'القرصنة';

  @override
  String get categoryAiChatbots => 'روبوتات الدردشة بالذكاء الاصطناعي';

  @override
  String get categorySocialMedia => 'وسائل التواصل الاجتماعي';

  @override
  String get categoryChat => 'الدردشة';

  @override
  String get allowedDomainsLabel => 'النطاقات المسموح بها (مفصولة بفواصل)';

  @override
  String get blockedDomainsLabel => 'النطاقات المحظورة (مفصولة بفواصل)';

  @override
  String get enforceSafeSearch => 'فرض البحث الآمن';

  @override
  String get youtubeRestrictedMode => 'الوضع المقيّد في يوتيوب';

  @override
  String get youtubeRestrictedDesc =>
      'يزيل المحتوى غير المناسب المحتمل على يوتيوب عبر أجهزة الأطفال.';

  @override
  String get strict => 'صارم';

  @override
  String get moderate => 'متوسط';

  @override
  String get off => 'إيقاف';

  @override
  String get alwaysAllowed => 'مسموح دائمًا';

  @override
  String get alwaysAllowedDesc =>
      'تظل هذه التطبيقات مفتوحة أثناء وقت النوم والساعات المدرسية والإيقاف والروتين.';

  @override
  String get noAlwaysAllowedApps => 'لا توجد تطبيقات مسموح بها دائمًا بعد';

  @override
  String get addApp => 'إضافة تطبيق';

  @override
  String get addAppRule => 'إضافة قاعدة تطبيق';

  @override
  String get chooseInstalledApp => 'اختيار من تطبيقات الطفل';

  @override
  String get installedAppsTitle => 'التطبيقات المثبتة';

  @override
  String get searchApps => 'البحث في التطبيقات';

  @override
  String get showSystemApps => 'إظهار تطبيقات النظام';

  @override
  String get alreadyRuled => 'له قاعدة بالفعل';

  @override
  String get installedAppsEmpty => 'لم يتم الإبلاغ عن أي تطبيقات بعد';

  @override
  String get installedAppsEmptyHint =>
      'تظهر القائمة بعد تسجيل جهاز الطفل في المرة التالية (خلال 15 دقيقة كحد أقصى).';

  @override
  String get installedAppsNoMatch => 'لا توجد تطبيقات تطابق بحثك.';

  @override
  String installedAppsLoadFailed(String error) {
    return 'تعذّر تحميل التطبيقات: $error';
  }

  @override
  String installedAppsTruncated(int count) {
    return 'عرض أول $count تطبيقًا.';
  }

  @override
  String get addAlwaysAllowedTitle => 'إضافة تطبيق مسموح دائمًا';

  @override
  String get appNameLabel => 'اسم التطبيق';

  @override
  String get packageIdLabel => 'معرّف الحزمة (مثل com.example.app)';

  @override
  String get limitPerDayLabel => 'الحد (دقائق/يوم)';

  @override
  String get addRoutine => 'إضافة روتين';

  @override
  String get editRoutine => 'تعديل الروتين';

  @override
  String get nameLabel => 'الاسم';

  @override
  String startTimeButton(String time) {
    return 'البداية $time';
  }

  @override
  String endTimeButton(String time) {
    return 'النهاية $time';
  }

  @override
  String get blockedAppsLabel => 'التطبيقات المحظورة (مفصولة بفواصل)';

  @override
  String get allowedAppsLabel => 'التطبيقات المسموح بها (مفصولة بفواصل)';

  @override
  String get rulesSaved => 'تم حفظ القواعد';

  @override
  String get reportsTitle => 'التقارير';

  @override
  String get screenTimeWebHistoryTooltip => 'وقت الشاشة وسجل الويب';

  @override
  String get sevenDays => '7 أيام';

  @override
  String get thirtyDays => '30 يومًا';

  @override
  String reportLoadFailed(String error) {
    return 'تعذّر تحميل التقرير: $error';
  }

  @override
  String noActivityDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'لم يُسجَّل أي نشاط خلال آخر $days يوم',
      many: 'لم يُسجَّل أي نشاط خلال آخر $days يومًا',
      few: 'لم يُسجَّل أي نشاط خلال آخر $days أيام',
      two: 'لم يُسجَّل أي نشاط خلال آخر يومين',
      one: 'لم يُسجَّل أي نشاط خلال آخر يوم',
    );
    return '$_temp0';
  }

  @override
  String get appUsage => 'استخدام التطبيقات';

  @override
  String totalAverage(int total, int avg) {
    return 'الإجمالي $total دقيقة · المتوسط $avg دقيقة/يوم';
  }

  @override
  String get noAppUsage => 'لم يُسجَّل أي استخدام للتطبيقات';

  @override
  String get webSection => 'الويب';

  @override
  String urlVisits(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count زيارة لموقع',
      many: '$count زيارة لموقع',
      few: '$count زيارات لمواقع',
      two: 'زيارتان لموقعين',
      one: 'زيارة واحدة لموقع',
      zero: 'لا زيارات لمواقع',
    );
    return '$_temp0';
  }

  @override
  String get noBlockedDomains => 'لا توجد نطاقات محظورة';

  @override
  String blockedTimes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'حُظر $count مرة',
      many: 'حُظر $count مرة',
      few: 'حُظر $count مرات',
      two: 'حُظر مرتين',
      one: 'حُظر مرة واحدة',
    );
    return '$_temp0';
  }

  @override
  String get safeSearchForced => 'يُفرض البحث الآمن في بحث يوتيوب';

  @override
  String get restrictedModeNote =>
      'يتطلب الوضع المقيّد فحص HTTPS على حاسوب الطفل (راجع الدليل)';

  @override
  String get socialAndCommunication => 'التواصل والاتصالات';

  @override
  String socialConcerns(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count مخوّف اجتماعي',
      many: '$count مخوّفًا اجتماعيًا',
      few: '$count مخاوف اجتماعية',
      two: 'مخوّفان اجتماعيان',
      one: 'مخوّف اجتماعي واحد',
      zero: 'لا مخاوف اجتماعية',
    );
    return '$_temp0';
  }

  @override
  String callsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count مكالمة',
      many: '$count مكالمة',
      few: '$count مكالمات',
      two: 'مكالمتان',
      one: 'مكالمة واحدة',
      zero: 'لا مكالمات',
    );
    return '$_temp0';
  }

  @override
  String smsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count رسالة نصية',
      many: '$count رسالة نصية',
      few: '$count رسائل نصية',
      two: 'رسالتان نصيتان',
      one: 'رسالة نصية واحدة',
      zero: 'لا رسائل نصية',
    );
    return '$_temp0';
  }

  @override
  String get screenTimeWebTitle => 'وقت الشاشة والويب';

  @override
  String daysShort(int days) {
    return '$days ي';
  }

  @override
  String get couldNotLoadScreenTime => 'تعذّر تحميل وقت الشاشة';

  @override
  String noScreenTimeData(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'لا توجد بيانات وقت شاشة خلال آخر $days يوم',
      many: 'لا توجد بيانات وقت شاشة خلال آخر $days يومًا',
      few: 'لا توجد بيانات وقت شاشة خلال آخر $days أيام',
      two: 'لا توجد بيانات وقت شاشة خلال آخر يومين',
      one: 'لا توجد بيانات وقت شاشة خلال آخر يوم',
    );
    return '$_temp0';
  }

  @override
  String noScreenTimeRecorded(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'لم يُسجَّل وقت شاشة خلال آخر $days يوم',
      many: 'لم يُسجَّل وقت شاشة خلال آخر $days يومًا',
      few: 'لم يُسجَّل وقت شاشة خلال آخر $days أيام',
      two: 'لم يُسجَّل وقت شاشة خلال آخر يومين',
      one: 'لم يُسجَّل وقت شاشة خلال آخر يوم',
    );
    return '$_temp0';
  }

  @override
  String totalOverDays(int total, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count يوم',
      many: '$count يومًا',
      few: '$count أيام',
      two: 'يومين',
      one: 'يوم واحد',
    );
    return 'الإجمالي $total دقيقة خلال $_temp0';
  }

  @override
  String fewerDaysReturned(int returned, int requested) {
    return 'أُعيد $returned فقط من أصل $requested يومًا مطلوبًا؛ تُعرض تلك الأيام كما هي.';
  }

  @override
  String get dayByDay => 'يومًا بيوم';

  @override
  String get browsingHistory => 'سجل التصفح';

  @override
  String get blockedOnly => 'المحظور فقط';

  @override
  String get showLabel => 'عرض';

  @override
  String get couldNotLoadBrowsing => 'تعذّر تحميل سجل التصفح';

  @override
  String noBlockedSites(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'لا توجد مواقع محظورة خلال آخر $days يوم',
      many: 'لا توجد مواقع محظورة خلال آخر $days يومًا',
      few: 'لا توجد مواقع محظورة خلال آخر $days أيام',
      two: 'لا توجد مواقع محظورة خلال آخر يومين',
      one: 'لا توجد مواقع محظورة خلال آخر يوم',
    );
    return '$_temp0';
  }

  @override
  String noBrowsingHistory(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'لا يوجد سجل تصفح خلال آخر $days يوم',
      many: 'لا يوجد سجل تصفح خلال آخر $days يومًا',
      few: 'لا يوجد سجل تصفح خلال آخر $days أيام',
      two: 'لا يوجد سجل تصفح خلال آخر يومين',
      one: 'لا يوجد سجل تصفح خلال آخر يوم',
    );
    return '$_temp0';
  }

  @override
  String showingLatestVisits(int limit) {
    return 'تُعرض آخر $limit زيارة — ارفع الحد لرؤية المزيد.';
  }

  @override
  String get blocked => 'محظور';

  @override
  String get allowed => 'مسموح';

  @override
  String dayTooltip(String date, int minutes) {
    return '$date: $minutes دقيقة';
  }

  @override
  String get scanQr => 'امسح رمز QR هذا بتطبيق OSRA للطفل.';

  @override
  String get typeSixDigit =>
      'إذا تعذّرت المسح بالكاميرا، فأدخل الرمز المكوّن من 6 أرقام أدناه على جهاز الطفل.';

  @override
  String get codeExpired => 'انتهت صلاحية الرمز';

  @override
  String get generateNewCode => 'أنشئ رمزًا جديدًا لمتابعة الإقران.';

  @override
  String pairingQrSemantics(String code) {
    return 'رمز QR للإقران $code';
  }

  @override
  String expiresIn(String time) {
    return 'تنتهي الصلاحية خلال $time';
  }

  @override
  String get regenerate => 'إعادة الإنشاء';

  @override
  String get copyCode => 'نسخ الرمز';

  @override
  String get codeCopied => 'تم نسخ الرمز';

  @override
  String codeWorksOnce(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: 'يعمل الرمز مرة واحدة وتنتهي صلاحيته بعد $minutes دقيقة.',
      many: 'يعمل الرمز مرة واحدة وتنتهي صلاحيته بعد $minutes دقيقة.',
      few: 'يعمل الرمز مرة واحدة وتنتهي صلاحيته بعد $minutes دقائق.',
      two: 'يعمل الرمز مرة واحدة وتنتهي صلاحيته بعد دقيقتين.',
      one: 'يعمل الرمز مرة واحدة وتنتهي صلاحيته بعد دقيقة واحدة.',
    );
    return '$_temp0';
  }

  @override
  String get pairCodeError =>
      'لم يُرجع الخادم رمز إقران صالحًا. جرّب إعادة الإنشاء.';

  @override
  String get pairCreateError =>
      'تعذّر إنشاء رمز الإقران. تحقق من الاتصال وحاول مرة أخرى.';

  @override
  String get pairConsentError =>
      'يحتاج الخادم إلى موافقة الوالدين لهذا الطفل قبل إنشاء رمز الإقران. ارجع وأضف الطفل مرة أخرى ثم حاول مجددًا.';

  @override
  String get appearanceTitle => 'المظهر';

  @override
  String get themeLabel => 'نمط العرض';

  @override
  String get appearanceDesc =>
      'النظام يتبع هذا الجهاز. يُطبَّق الفاتح أو الداكن على OSRA فقط.';

  @override
  String followingDevice(String mode) {
    return 'يتبع الجهاز (حاليًا $mode).';
  }

  @override
  String get lightAlwaysOn => 'المظهر الفاتح مفعّل دائمًا.';

  @override
  String get darkAlwaysOn => 'المظهر الداكن مفعّل دائمًا.';

  @override
  String get languageLabel => 'اللغة';

  @override
  String get languageDesc =>
      'النظام يتبع هذا الجهاز. تُطبَّق الإنجليزية أو العربية على OSRA فقط.';

  @override
  String followingLanguage(String language) {
    return 'تتبع الجهاز (حاليًا $language).';
  }

  @override
  String get englishAlwaysOn => 'اللغة الإنجليزية مفعّلة دائمًا.';

  @override
  String get arabicAlwaysOn => 'اللغة العربية مفعّلة دائمًا.';

  @override
  String get monitoring => 'المراقبة';

  @override
  String get monitoringSaved => 'تم حفظ المراقبة';

  @override
  String saveFailed(String error) {
    return 'فشل الحفظ: $error';
  }

  @override
  String get saveMonitoring => 'حفظ المراقبة';

  @override
  String get concerns => 'المخاوف';

  @override
  String get vaultTrustCopy =>
      'تُشفَّر المقاطع بمفتاح عائلتك قبل مغادرة الجهاز وتُخزَّن مشفّرة على خادمك.';

  @override
  String get noConcernsDetected => 'لم تُكتشف أي مخاوف';

  @override
  String get unknownContact => 'جهة اتصال غير معروفة';

  @override
  String get unknownApp => 'تطبيق غير معروف';

  @override
  String get noPreviewAvailable => 'لا تتوفر معاينة';

  @override
  String get viewInDecryptionVault => 'عرض في خزنة فك التشفير';

  @override
  String get socialMessage => 'رسالة اجتماعية';

  @override
  String get callsAndTexts => 'المكالمات والرسائل';

  @override
  String get iosNoCallMonitoring => 'لا يدعم iOS مراقبة المكالمات والرسائل.';

  @override
  String get noCallsOrTexts => 'لا توجد مكالمات أو رسائل بعد';

  @override
  String get unknownNumber => 'رقم غير معروف';

  @override
  String get trustedContacts => 'جهات اتصال موثوقة';

  @override
  String get trustedContactsDesc =>
      'الأرقام هنا لا تُثير مخاوف اجتماعية أبدًا.';

  @override
  String get phoneNumberLabel => 'رقم الهاتف';

  @override
  String get saveAllowlist => 'حفظ القائمة المسموح بها';

  @override
  String get allowlistSaved => 'تم حفظ القائمة المسموح بها';

  @override
  String get relativeJustNow => 'الآن';

  @override
  String relativeMinutesAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'قبل $count دقيقة',
      many: 'قبل $count دقيقة',
      few: 'قبل $count دقائق',
      two: 'قبل دقيقتين',
      one: 'قبل دقيقة',
    );
    return '$_temp0';
  }

  @override
  String relativeHoursAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'قبل $count ساعة',
      many: 'قبل $count ساعة',
      few: 'قبل $count ساعات',
      two: 'قبل ساعتين',
      one: 'قبل ساعة',
    );
    return '$_temp0';
  }

  @override
  String relativeDaysAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'قبل $count يوم',
      many: 'قبل $count يومًا',
      few: 'قبل $count أيام',
      two: 'قبل يومين',
      one: 'قبل يوم',
    );
    return '$_temp0';
  }

  @override
  String get decryptedVaultContent => 'محتوى الخزنة بعد فك التشفير';

  @override
  String get encryptedFamilyVault => 'خزنة العائلة المشفّرة';

  @override
  String get vaultEncryptionDesc =>
      'محميّ بتشفير AES-256-GCM. يُفكّ التشفير عند الطلب للأوصياء الموثّقين فقط.';

  @override
  String get decryptedContent => 'المحتوى بعد فك التشفير';

  @override
  String get copy => 'نسخ';

  @override
  String get contentCopied => 'تم نسخ المحتوى إلى الحافظة';

  @override
  String get noPreviewContent => 'لا يوجد محتوى معاينة متاح';

  @override
  String get detectedConcernTypes => 'أنواع المخاوف المكتشفة';

  @override
  String get commandDeliveryTitle => 'تسليم الأوامر';

  @override
  String get couldNotLoadChild => 'تعذّر تحميل هذا الطفل';

  @override
  String get noDevicesForChild => 'لا توجد أجهزة مسجّلة لهذا الطفل';

  @override
  String get deliveryExplanation =>
      'لا يُعدّ الأمر مؤكدًا إلا عندما يردّ جهاز الطفل. يعني «تم التسليم» أن الجهاز استلمه، ولم يؤكّد تنفيذه.';

  @override
  String get couldNotLoadCommandHistory => 'تعذّر تحميل سجل الأوامر';

  @override
  String createdEvent(String time) {
    return 'أُنشئ $time';
  }

  @override
  String deliveredEvent(String time) {
    return 'سُلّم $time';
  }

  @override
  String confirmedEvent(String time) {
    return 'أُكّد $time';
  }

  @override
  String get mfaMenu => 'التحقق بخطوتين';

  @override
  String get mfaSettingsTitle => 'التحقق بخطوتين';

  @override
  String get mfaStatusOn => 'مفعّل';

  @override
  String get mfaStatusOff => 'غير مفعّل';

  @override
  String get mfaSettingsStatusOn => 'التحقق بخطوتين مفعّل.';

  @override
  String get mfaSettingsStatusOff => 'التحقق بخطوتين غير مفعّل.';

  @override
  String get mfaSettingsExplanation =>
      'عند تفعيله، يتطلب تسجيل الدخول رمزًا من تطبيق المصادقة بالإضافة إلى كلمة المرور.';

  @override
  String get mfaSetupAuthenticator => 'إعداد تطبيق المصادقة';

  @override
  String get mfaReplaceAuthenticator => 'استبدال تطبيق المصادقة';

  @override
  String get mfaRecoveryCodesTitle => 'رموز الاسترداد';

  @override
  String get mfaRecoveryCodesExplanation =>
      'عشرة رموز للاستخدام مرة واحدة. كل رمز يتيح لك تسجيل الدخول مرة واحدة إذا فقدت تطبيق المصادقة.';

  @override
  String get mfaRegenerateCodes => 'إنشاء رموز استرداد جديدة';

  @override
  String get mfaRegenerateWarning =>
      'إنشاء رموز جديدة يستبدل الرموز القديمة، وتتوقف القديمة عن العمل فورًا.';

  @override
  String get mfaSessionNotice =>
      'انتهت جلستك عند تفعيل التحقق بخطوتين. سجّل الدخول مجددًا باستخدام تطبيق المصادقة الجديد.';

  @override
  String get mfaReauthTitle => 'أكّد هويتك';

  @override
  String get mfaReauthExplanation =>
      'أدخل كلمة المرور أو رمزًا حاليًا من تطبيق المصادقة.';

  @override
  String get mfaReauthCode => 'رمز تطبيق المصادقة';

  @override
  String get mfaReauthRequired =>
      'أدخل كلمة المرور أو رمزًا حاليًا من تطبيق المصادقة.';

  @override
  String get mfaReauthFailed => 'لم يتم قبول كلمة المرور أو الرمز.';

  @override
  String get mfaEnrollTitle => 'إعداد التحقق بخطوتين';

  @override
  String get mfaEnrollIntro =>
      'امسح هذا الرمز بتطبيق المصادقة، ثم أدخل الرمز المكوّن من ستة أرقام الذي يعرضه.';

  @override
  String get mfaEnrollManual => 'تعذّر المسح؟ أدخل هذا المفتاح في التطبيق:';

  @override
  String get mfaSecretCopied => 'تم نسخ المفتاح';

  @override
  String get mfaSecretSemantics => 'مفتاح إعداد تطبيق المصادقة';

  @override
  String get mfaEnrollAfterRecovery =>
      'أعد إعداد تطبيق مصادقة جديد لهذا الحساب. إلى أن تتحقق منه، يبقى التحقق بخطوتين غير مفعّل.';

  @override
  String get mfaCodeFieldLabel => 'رمز من ستة أرقام';

  @override
  String get mfaVerify => 'تفعيل التحقق بخطوتين';

  @override
  String get mfaVerifying => 'جارٍ التحقق…';

  @override
  String get mfaInvalidCode =>
      'لم يتم قبول هذا الرمز. تحقّق من ساعة هاتفك وجرّب الرمز التالي.';

  @override
  String get mfaNotEnrolled =>
      'ابدأ الإعداد من جديد — لا يوجد تطبيق مصادقة مسجّل بعد.';

  @override
  String get mfaSessionError =>
      'انتهت جلستك. سجّل الدخول مجددًا ثم أعد المحاولة.';

  @override
  String get mfaRecoveryExpired =>
      'انتهت جلسة الاسترداد. ابدأ الاسترداد من جديد.';

  @override
  String get mfaTooManyAttempts =>
      'محاولات كثيرة جدًا. انتظر دقيقة ثم حاول مجددًا.';

  @override
  String get mfaNetworkError =>
      'تعذّر الوصول إلى الخادم. تحقّق من اتصالك ثم حاول مجددًا.';

  @override
  String get mfaRequestFailed => 'لم ينجح ذلك. حاول مجددًا.';

  @override
  String get mfaEnrollError => 'تعذّر إنشاء مفتاح المصادقة. حاول مجددًا.';

  @override
  String get mfaNoRecoveryCodes =>
      'لم يُرجع الخادم رموز الاسترداد. حاول مجددًا قبل مغادرة هذه الشاشة.';

  @override
  String get mfaCodesTitle => 'احفظ رموز الاسترداد';

  @override
  String get mfaCodesIntro =>
      'لن تُعرض هذه الرموز العشرة مرة أخرى. اكتبها أو انسخها إلى مكان آمن.';

  @override
  String get mfaCopyAllCodes => 'نسخ كل الرموز';

  @override
  String get mfaCodesCopied => 'تم نسخ رموز الاسترداد';

  @override
  String get mfaCodesSavedCheckbox => 'لقد حفظت هذه الرموز';

  @override
  String get mfaCodesConfirm => 'لقد حفظت هذه الرموز';

  @override
  String get mfaCodesLeaveTitle => 'المغادرة دون حفظ؟';

  @override
  String get mfaCodesLeaveBody =>
      'لا يمكن عرض هذه الرموز مرة أخرى. إذا غادرت الآن، فستحتاج إلى إنشاء مجموعة جديدة من الإعدادات.';

  @override
  String get mfaCodesStay => 'البقاء';

  @override
  String get mfaCodesLeave => 'المغادرة على أي حال';

  @override
  String mfaCodesIssuedAt(String date) {
    return 'أُنشئت في $date';
  }

  @override
  String mfaRecoveryCodeSemantics(int index) {
    return 'رمز الاسترداد $index';
  }

  @override
  String get mfaRecoveryLink => 'هل فقدت تطبيق المصادقة؟';

  @override
  String get mfaRecoveryTitle => 'استرداد حسابك';

  @override
  String get mfaRecoveryIntro =>
      'أدخل البريد الإلكتروني وكلمة المرور وأحد رموز الاسترداد غير المستخدمة لهذا الحساب. سيؤدي هذا إلى إيقاف التحقق بخطوتين كي تتمكن من إعداده من جديد.';

  @override
  String get mfaRecoveryCodeLabel => 'رمز الاسترداد';

  @override
  String get mfaRecoveryCodeHint => 'XXXX-XXXX-XXXX-XXXX';

  @override
  String get mfaRecoverySubmit => 'استرداد الحساب';

  @override
  String get mfaRecoveryInvalid =>
      'البريد الإلكتروني أو كلمة المرور أو رمز الاسترداد غير صحيح.';

  @override
  String get mfaRecoveryNoToken => 'لم يُرجع الخادم جلسة استرداد. حاول مجددًا.';

  @override
  String get mfaFieldsRequired =>
      'املأ البريد الإلكتروني وكلمة المرور ورمز الاسترداد.';

  @override
  String get onboardingWelcomeTitle => 'مرحبًا بك في OSRA';

  @override
  String get onboardingWelcomeBody =>
      'أعدّ الحماية لطفلك في ثلاث خطوات قصيرة. يستغرق الأمر نحو خمس دقائق.';

  @override
  String get onboardingGetStarted => 'ابدأ';

  @override
  String get onboardingSignInTitle => 'سجّل الدخول أو أنشئ حسابًا';

  @override
  String get onboardingSignInBody =>
      'هذا الحساب يتحكم في حماية طفلك. سجّل الدخول، أو أنشئ حساب عائلتك أدناه.';

  @override
  String get onboardingWrongPassword =>
      'البريد الإلكتروني أو كلمة المرور غير صحيحة. تحقق منها وحاول مجددًا.';

  @override
  String get onboardingInvalidMfaCode =>
      'لم يُقبل رمز التحقق. تحقق من الرمز وحاول مجددًا.';

  @override
  String get onboardingNoNetwork =>
      'تعذّر الوصول إلى الخادم. تحقق من عنوان الخادم واتصال الإنترنت ثم حاول مجددًا.';

  @override
  String get onboardingChildTitle => 'أضف طفلك';

  @override
  String get onboardingChildIntro =>
      'أدخل اسم طفلك وسنة ميلاده. اختر طريقة موافقة الوالدين — يحتاج الخادم إلى الموافقة قبل إضافة الطفل.';

  @override
  String get onboardingChildNameRequired => 'أدخل اسم طفلك.';

  @override
  String get onboardingBirthYearInvalid =>
      'أدخل سنة ميلاد بين 1900 وهذا العام.';

  @override
  String get onboardingAddChildContinue => 'أضف الطفل وتابع';

  @override
  String get onboardingChildPrivacy =>
      'يُخزَّن اسم طفلك وسنة ميلاده على خادم عائلتك. يُستخدمان فقط للحماية والتقارير.';

  @override
  String get onboardingExistingChildren =>
      'لدى حسابك أطفال بالفعل. تابع لإقران جهاز.';

  @override
  String get onboardingConsentRequired =>
      'يحتاج الخادم إلى موافقة الوالدين لهذا الطفل. تحقق من بيانات الموافقة وحاول مجددًا.';

  @override
  String get onboardingOwnerOnly =>
      'مالك العائلة وحده يمكنه إضافة طفل. سجّل الدخول بحساب المالك أو اطلب من المالك إضافة هذا الطفل.';

  @override
  String get onboardingChildInvalid =>
      'تعذّر على الخادم إضافة هذا الطفل. تحقق من الاسم وسنة الميلاد ثم حاول مجددًا.';

  @override
  String get onboardingChildFailed =>
      'تعذّرت إضافة طفلك. تحقق من اتصالك وحاول مجددًا.';

  @override
  String get onboardingLeaveTitle => 'العودة إلى تسجيل الدخول؟';

  @override
  String get onboardingLeaveBody =>
      'سيتم تسجيل خروجك. أي شيء أضفته بالفعل يبقى على حسابك.';

  @override
  String get onboardingLeaveStay => 'ابقَ';

  @override
  String get onboardingLeaveConfirm => 'تسجيل الخروج';

  @override
  String get onboardingPairTitle => 'إقران جهازه';

  @override
  String onboardingPairIntro(String childName) {
    return 'افتح OSRA على هاتف $childName واختر الإقران برمز.';
  }

  @override
  String get onboardingPairSteps =>
      'امسح رمز QR هذا، أو اكتب الأرقام الستة أدناه إذا تعذّر على الكاميرا مسحه. لا حاجة إلى إعطاء كلمة المرور لمن يحمل الهاتف.';

  @override
  String get onboardingPairConfirm => 'انتهى طفلي من الإقران';

  @override
  String get onboardingPairWaiting =>
      'لم يتم الإقران بعد. اطلب من طفلك إكمال الخطوة على هاتفه ثم اضغط مجددًا.';

  @override
  String get onboardingPairCheckFailed =>
      'تعذّر التحقق من الإقران بعد. تحقق من اتصالك واضغط مجددًا.';

  @override
  String get onboardingPairLater => 'الإعداد لاحقًا';

  @override
  String get onboardingPairLaterNote =>
      'يمكنك الإقران من لوحة التحكم متى كان الهاتف جاهزًا. تبدأ الحماية بعد الإقران.';

  @override
  String pairingCodeSemantics(String code) {
    return 'رمز الإقران $code';
  }

  @override
  String get onboardingDoneStepTitle => 'الإعداد';

  @override
  String get onboardingDoneTitle => 'كل شيء جاهز';

  @override
  String get onboardingDoneBody =>
      'تمت إضافة طفلك وإقران جهازه. افتح لوحة التحكم لعرض حالته.';

  @override
  String get onboardingDonePendingTitle => 'بقيت خطوة واحدة';

  @override
  String get onboardingDonePendingBody =>
      'تمت إضافة طفلك، لكن هاتفه غير مقرون بعد. يمكنك إقرانه في أي وقت من لوحة التحكم.';

  @override
  String get onboardingGoToDashboard => 'الانتقال إلى لوحة التحكم';

  @override
  String get onboardingFinishSetupTitle => 'أكمل الإعداد';

  @override
  String onboardingFinishSetupBody(String childName) {
    return 'أقرن هاتف $childName لتبدأ الحماية.';
  }

  @override
  String get onboardingPairNow => 'أقرن الآن';

  @override
  String get consentRecordSummary => 'الطريقة والتواريخ وسحب الموافقة';

  @override
  String consentStatusSubtitle(String childName) {
    return 'ما هو مسجّل حاليًا لدى الخادم عن $childName.';
  }

  @override
  String get consentStateActive => 'سارية';

  @override
  String get consentStateExpiring => 'تنتهي قريبًا';

  @override
  String get consentStateExpired => 'منتهية';

  @override
  String get consentStateRevoked => 'مسحوبة';

  @override
  String get consentStateMismatch => 'منطقة غير مطابقة';

  @override
  String get consentStateNone => 'لا يوجد سجل موافقة';

  @override
  String get consentStateActiveDetail =>
      'المراقبة وجمع البيانات مسموحان بموجب هذا السجل.';

  @override
  String consentStateExpiringDetail(String date) {
    return 'ينتهي هذا السجل في $date. يتوقف الجمع والتنبيهات بعد ذلك التاريخ ما لم تُمنح الموافقة مجددًا.';
  }

  @override
  String consentStateExpiredDetail(String date) {
    return 'انتهى هذا السجل في $date. المراقبة وجمع البيانات متوقفان حتى تُمنح الموافقة مجددًا.';
  }

  @override
  String consentStateRevokedDetail(String date) {
    return 'سُحبت الموافقة في $date. المراقبة وجمع البيانات متوقفان حتى تُمنح الموافقة مجددًا.';
  }

  @override
  String consentStateMismatchDetail(String record, String family) {
    return 'اختصاص السجل ($record) لا يطابق منطقة عائلتك ($family)، لذلك لا يمكنه السماح بالمراقبة.';
  }

  @override
  String get consentStateNoneDetail =>
      'لا توجد موافقة والدين مسجّلة لهذا الطفل. المراقبة وجمع البيانات تتطلبان سجلًا ساريًا.';

  @override
  String get consentJurisdictionLabel => 'الاختصاص القضائي';

  @override
  String get consentGrantedLabel => 'تاريخ المنح';

  @override
  String get consentExpiryLabel => 'تاريخ الانتهاء';

  @override
  String get consentNoExpiry => 'بلا تاريخ انتهاء';

  @override
  String get consentThirdPartyLabel => 'المشاركة مع أطراف ثالثة';

  @override
  String get consentSharingOn => 'مفعّلة';

  @override
  String get consentSharingOff => 'معطّلة';

  @override
  String get consentRevokedLabel => 'تاريخ السحب';

  @override
  String get consentNotRevoked => 'غير مسحوبة';

  @override
  String get consentCurrentRecord => 'السجل الحالي';

  @override
  String get consentHistorySection => 'سجلات سابقة';

  @override
  String consentHistoryGranted(String method, String date) {
    return '$method · مُنحت في $date';
  }

  @override
  String consentHistoryRevoked(String date) {
    return 'مسحوبة في $date';
  }

  @override
  String consentHistoryExpired(String date) {
    return 'منتهية في $date';
  }

  @override
  String get consentHistoryActive => 'سارية';

  @override
  String get consentLoadFailed =>
      'تعذّر تحميل سجل الموافقة. تحقّق من اتصالك وحاول مجددًا.';

  @override
  String get consentWithdrawAction => 'سحب الموافقة';

  @override
  String get consentWithdrawOnlyOwner => 'مالك العائلة فقط يمكنه سحب الموافقة.';

  @override
  String get consentWithdrawUnavailable => 'لا يوجد سجل موافقة سارٍ لسحبه.';

  @override
  String get consentWithdrawNote =>
      'سحب الموافقة يوقف المراقبة. لا يحذف البيانات التي جُمعت بالفعل.';

  @override
  String get consentRevokeTitle => 'سحب الموافقة؟';

  @override
  String consentRevokeWarning(String childName) {
    return 'سيؤدي هذا إلى إيقاف المراقبة لـ $childName. يبقى الجهاز مقترنًا، ويمكن منح الموافقة مجددًا لاحقًا.';
  }

  @override
  String get consentRevokeStopsTitle => 'ما الذي يتوقف فورًا';

  @override
  String get consentRevokeStopsCollection =>
      'يتوقف جمع البيانات الجديد: الموقع والنشاط في التطبيقات والويب وفحص المحادثات.';

  @override
  String get consentRevokeStopsAlerts =>
      'تتوقف تنبيهات السلامة، بما فيها SOS ووقت الشاشة والمواقع المحظورة.';

  @override
  String get consentRevokeStopsRules =>
      'تتوقف المراقبة على كل الأجهزة. تبقى القواعد المحفوظة لكنها لا تُطبّق حتى تُمنح الموافقة مجددًا.';

  @override
  String get consentRevokeKeepsSafe =>
      'يبقى فتح قفل جهاز طفلك واستئناف استخدامه متاحين أثناء سحب الموافقة.';

  @override
  String get consentRevokeDataTitle => 'ماذا يحدث للبيانات المجمّعة بالفعل';

  @override
  String get consentRevokeDataRetained =>
      'لا يُحذف أي شيء أو يُخفى الآن. تبقى التقارير والتنبيهات وسجل المواقع المجمّعة في حساب عائلتك.';

  @override
  String get consentRevokeDataRetention =>
      'تُحذف بيانات الموقع والتطبيقات والويب والمحادثات الخام بواسطة مهمة الاحتفاظ بعد 90 يومًا افتراضيًا. تُحفظ ملخصات الاستخدام لمدة 365 يومًا. تبقى التنبيهات حتى تُحذف بيانات الطفل.';

  @override
  String get consentRevokeDataErase =>
      'حذف ملف طفلك إجراء منفصل يزيل كل بياناته فورًا. وهو ليس جزءًا من سحب الموافقة.';

  @override
  String consentRevokeTypePrompt(String childName) {
    return 'اكتب $childName للتأكيد';
  }

  @override
  String get consentRevokeTypeHint => 'يجب أن يطابق الاسم.';

  @override
  String consentRevokeMismatch(String childName) {
    return 'هذا لا يطابق $childName.';
  }

  @override
  String get consentRevokeSubmit => 'سحب الموافقة الآن';

  @override
  String get consentRevokeCancel => 'الاحتفاظ بالموافقة';

  @override
  String get consentRevokeBusy => 'جارٍ السحب…';

  @override
  String get consentRevokeFailed =>
      'تعذّر سحب الموافقة. لم يتغيّر شيء. تحقّق من اتصالك وحاول مجددًا.';

  @override
  String get consentRevokeForbidden =>
      'مالك العائلة فقط يمكنه سحب الموافقة. لم يتغيّر شيء.';

  @override
  String get consentRevokeDone => 'تم سحب الموافقة. أُوقفت المراقبة.';

  @override
  String get consentRevokeNoActive =>
      'لم يكن هناك سجل موافقة سارٍ. لم يتغيّر شيء.';

  @override
  String consentRevokeDevices(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'أُضيفت إشارة الإيقاف لـ $count أجهزة.',
      one: 'أُضيفت إشارة الإيقاف لجهاز واحد.',
      zero: 'لم يكن أي جهاز متصلًا.',
    );
    return '$_temp0';
  }

  @override
  String get consentChildNameMissing =>
      'تعذّر تحميل اسم طفلك. ارجع وحاول مجددًا.';
}
