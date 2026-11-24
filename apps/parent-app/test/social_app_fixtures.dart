import 'dart:convert';
import 'dart:io';

import 'fake_api_client.dart';

const socialPackageFixtures = <String, String>{
  'whatsapp': 'com.whatsapp',
  'instagram': 'com.instagram.android',
  'tiktok': 'com.zhiliaoapp.musically',
  'snapchat': 'com.snapchat.android',
  'twitter': 'com.twitter.android',
  'discord': 'com.discord',
  'roblox': 'com.roblox.client',
  'line': 'jp.naver.line.android',
  'youtube': 'com.google.android.youtube',
  'telegram': 'org.telegram.messenger',
  'reddit': 'com.reddit.frontpage',
  'messenger': 'com.facebook.orca',
};

// Review-frame fixtures: Icons8 color icons, https://icons8.com/license.
String? socialIconData(String appKey) {
  if (appKey != 'whatsapp' && appKey != 'youtube') return null;
  final bytes =
      File('test/fixtures/social_icons/$appKey.png').readAsBytesSync();
  return 'data:image/png;base64,${base64Encode(bytes)}';
}

List<Map<String, dynamic>> socialInventory([
  Set<String>? keys,
  bool withIcons = false,
]) =>
    [
      for (final entry in socialPackageFixtures.entries)
        if (keys == null || keys.contains(entry.key))
          installedAppJson(
            entry.value,
            entry.key,
            iconUrl: withIcons ? socialIconData(entry.key) : null,
          ),
    ];
