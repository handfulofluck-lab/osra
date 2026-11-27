import '../../api/models.dart';

typedef SocialAppInfo = ({String appKey, String label, List<String> packageIds});

const kSocialApps = <SocialAppInfo>[
  (appKey: 'whatsapp', label: 'WhatsApp', packageIds: ['com.whatsapp', 'com.whatsapp.w4b']),
  (appKey: 'instagram', label: 'Instagram', packageIds: ['com.instagram.android']),
  (appKey: 'tiktok', label: 'TikTok', packageIds: ['com.zhiliaoapp.musically', 'com.ss.android.ugc.trill']),
  (appKey: 'snapchat', label: 'Snapchat', packageIds: ['com.snapchat.android']),
  (appKey: 'twitter', label: 'X', packageIds: ['com.twitter.android', 'com.x.android']),
  (appKey: 'discord', label: 'Discord', packageIds: ['com.discord']),
  (appKey: 'roblox', label: 'Roblox', packageIds: ['com.roblox.client']),
  (appKey: 'line', label: 'LINE', packageIds: ['jp.naver.line.android']),
  (appKey: 'youtube', label: 'YouTube', packageIds: ['com.google.android.youtube', 'com.google.android.apps.youtube.kids']),
  (appKey: 'telegram', label: 'Telegram', packageIds: ['org.telegram.messenger', 'org.telegram.plus']),
  (appKey: 'reddit', label: 'Reddit', packageIds: ['com.reddit.frontpage']),
  (appKey: 'messenger', label: 'Messenger', packageIds: ['com.facebook.orca']),
];

String? socialAppKeyForPackage(String packageId) {
  for (final app in kSocialApps) {
    if (app.packageIds.contains(packageId)) return app.appKey;
  }
  return null;
}

Map<String, InstalledApp> installedSocialAppsByKey(InstalledAppsReport report) {
  final installed = <String, InstalledApp>{};
  for (final app in report.apps) {
    final key = socialAppKeyForPackage(app.packageId);
    if (key != null) installed.putIfAbsent(key, () => app);
  }
  return installed;
}

bool socialMonitoringEnabled(Map<String, bool> monitoring, String appKey) {
  if (appKey == 'twitter' &&
      !monitoring.containsKey('twitter') &&
      monitoring.containsKey('x')) {
    return monitoring['x']!;
  }
  return monitoring[appKey] ?? true;
}

List<SocialAppInfo> sortedSocialApps(Iterable<SocialAppInfo> apps) {
  return apps.toList()
    ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
}
