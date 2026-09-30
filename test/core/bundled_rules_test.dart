import 'dart:io';

import 'package:test/test.dart';

import 'package:baka/services/source/source_codec.dart';
import 'package:baka/source/engine/rule_validator.dart';
import 'package:baka/source/models/source_rule.dart';
import 'package:baka/source/store/bundled_rule_store.dart';

void main() {
  final assetDirectory = Directory('assets/rules');
  final assetFiles = assetDirectory
      .listSync()
      .whereType<File>()
      .where((file) => file.path.toLowerCase().endsWith('.json'))
      .toList(growable: false);

  test('all built-in assets contain valid v2 pipeline rules', () {
    for (final file in assetFiles) {
      final name = file.uri.pathSegments.last;
      final decoded = SourceCodec.decode(file.readAsStringSync().trim());
      expect(decoded, isA<Map>(), reason: '$name must contain a JSON object');

      // Use the same parser as BundledRuleStore, without import normalization.
      final rule = SourceRule.fromJson(
        Map<String, dynamic>.from(decoded as Map),
      );
      expect(
        BundledRuleStore.builtinAssets[rule.id],
        file.path.replaceAll(r'\', '/'),
        reason: '$name registry mismatch',
      );
      expect(rule.baseUrl, isNotEmpty, reason: '$name missing baseUrl');
      expect(rule.search, isNotEmpty, reason: '$name missing search pipeline');
      expect(rule.detail, isNotEmpty, reason: '$name missing detail pipeline');
      expect(rule.play, isNotEmpty, reason: '$name missing play pipeline');

      final validation = RuleValidator.validate(rule);
      expect(
        validation.isValid,
        isTrue,
        reason: '$name invalid: ${validation.errors.join('; ')}',
      );
    }
  });
}
