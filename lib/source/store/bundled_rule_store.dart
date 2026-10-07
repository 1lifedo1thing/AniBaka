import 'dart:convert';

import 'package:flutter/services.dart';

import 'package:baka/models/custom_source_config.dart';
import 'package:baka/models/rule_hub.dart';
import 'package:baka/source/engine/rule_validator.dart';
import 'package:baka/source/models/source_rule.dart';

/// Loads the former built-in sources from bundled `anx-rule/2` assets.
///
/// Built-in rules live under `assets/rules/`. Community rules are maintained
/// by AniBakaRule and are fetched by Rule Hub instead of being duplicated in
/// the application repository.
class BundledRuleStore {
  BundledRuleStore._();

  static const Map<String, String> builtinAssets = <String, String>{
    '2kdm': 'assets/rules/2kdm.json',
    '7sefun': 'assets/rules/7sefun.json',
    'akianime': 'assets/rules/akianime.json',
    'dm84': 'assets/rules/dm84.json',
    'fsdm02': 'assets/rules/fsdm02.json',
    'girigirilove': 'assets/rules/girigirilove.json',
    'girigirilove_beta': 'assets/rules/girigirilove_beta.json',
    'lm6': 'assets/rules/lm6.json',
    'mgnacg': 'assets/rules/mgnacg.json',
    'ios_mifun': 'assets/rules/ios_mifun.json',
    'xifanacg': 'assets/rules/xifanacg.json',
    'tvtfun': 'assets/rules/tvtfun.json',
    'moonci': 'assets/rules/moonci.json',
    'silisili': 'assets/rules/silisili.json',
  };

  /// Generated together with the rule files by tool/sync_bundled_rules.dart.
  /// Uses the repository's anx-rulehub/2 rev, never the application version.
  static const indexAsset = 'assets/rules/index.json';
  static Map<String, int> _versions = const {};

  static Map<String, SourceRule> _rules = const <String, SourceRule>{};
  static Future<void>? _loading;

  static Future<void> load() => _loading ??= _load();

  static SourceRule? ruleFor(String key) => _rules[key];

  static int versionFor(String key) => _versions[key] ?? 0;

  static Future<void> _load() async {
    final index = RuleHubIndex.fromJson(
      jsonDecode(await rootBundle.loadString(indexAsset))
          as Map<String, dynamic>,
      sourceUrl: 'asset://$indexAsset',
    );
    final loaded = await Future.wait(
      builtinAssets.entries.map((entry) async {
        final raw = await rootBundle.loadString(entry.value);
        final decoded = jsonDecode(raw);
        if (decoded is! Map) {
          throw FormatException('${entry.value}: rule root must be an object');
        }
        final rule = CustomSourceConfig.fromJson(
          decoded.cast<String, dynamic>(),
        ).rule;
        assert(() {
          final validation = RuleValidator.validate(rule);
          if (!validation.isValid) {
            throw FormatException(
              '${entry.value}: ${validation.errors.join('; ')}',
            );
          }
          if (rule.id != entry.key) {
            throw FormatException(
              '${entry.value}: asset id ${rule.id} does not match '
              'registry key ${entry.key}',
            );
          }
          return true;
        }());
        return MapEntry(entry.key, rule);
      }),
    );
    _rules = Map<String, SourceRule>.unmodifiable(
      Map<String, SourceRule>.fromEntries(loaded),
    );
    _versions = Map.unmodifiable({
      for (final item in index.rules) item.id: item.version,
    });
  }
}
