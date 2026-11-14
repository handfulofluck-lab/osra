import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:familyshield_parent/api/models.dart';

/// ADR-0037 PR B3c (part 1): the parent app reads the iPhone's app groups and carries the parent's group blocks
/// through every read-modify-write. A screen that rebuilt the ruleset without them would clear a block the
/// parent set (the server keeps them only when the field is absent, #580).
void main() {
  const g1 = '6F1C2B8E-3D4A-4E5F-9A0B-1C2D3E4F5A6B';

  group('RuleSet.appGroupRules', () {
    test('a GET then PUT round trip keeps the group blocks', () {
      final rules = RuleSet.fromJson({
        'appRules': [],
        'appGroupRules': [
          {'groupId': g1, 'action': 'block'},
        ],
      });
      expect(rules.appGroupRules.map((r) => r.groupId), [g1]);
      expect(rules.toJson()['appGroupRules'], [
        {'groupId': g1, 'action': 'block'},
      ]);
    });

    test('a server before B3a sends none, and the PUT then sends an empty list', () {
      final rules = RuleSet.fromJson({'appRules': []});
      expect(rules.appGroupRules, isEmpty);
      expect(rules.toJson()['appGroupRules'], isEmpty);
    });

    test('an entry this app does not understand is dropped, the others kept', () {
      final rules = RuleSet.fromJson({
        'appGroupRules': [
          {'groupId': g1, 'action': 'block'},
          {'groupId': 'x', 'action': 'limit'},
          {'action': 'block'},
          'junk',
        ],
      });
      expect(rules.appGroupRules.map((r) => r.groupId), [g1]);
    });

    test('copyWith keeps the group blocks unless given', () {
      final rules = RuleSet(appGroupRules: const [AppGroupRule(groupId: g1)]);
      expect(rules.copyWith(alwaysAllowedApps: ['a']).appGroupRules.map((r) => r.groupId), [g1]);
      expect(rules.copyWith(appGroupRules: const []).appGroupRules, isEmpty);
    });

    test('every rules-editor rebuild of the draft carries the group blocks', () {
      final src = File('lib/features/rules/rules_editor_screen.dart').readAsStringSync();
      final rebuilds = RegExp(r'_draft = RuleSet\(([^;]*)\)').allMatches(src).toList();
      expect(rebuilds, isNotEmpty);
      for (final m in rebuilds) {
        expect(m.group(1), contains('appGroupRules: _draft.appGroupRules'), reason: m.group(0));
      }
    });
  });

  group('DeviceSetup.groups', () {
    test('the iPhone\'s groups are read as id, label and counts', () {
      final setup = DeviceSetup.fromJson({
        'groups': [
          {'id': g1, 'label': 'Games', 'apps': 3, 'categories': 1, 'sites': 2},
          {'id': '', 'label': 'no id'},
        ],
      });
      expect(setup.groups, hasLength(1));
      final g = setup.groups!.single;
      expect([g.id, g.label, g.apps, g.categories, g.sites], [g1, 'Games', 3, 1, 2]);
    });

    test('no report of groups is null, an empty report is an empty list', () {
      expect(DeviceSetup.fromJson({}).groups, isNull);
      expect(DeviceSetup.fromJson({'groups': []}).groups, isEmpty);
    });
  });
}
