import 'dart:io';

import 'package:test/test.dart';

import 'package:baka/models/custom_source_config.dart';
import 'package:baka/services/source/source_codec.dart';
import 'package:baka/source/engine/rule_validator.dart';
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

      final config = CustomSourceConfig.fromJson(
        Map<String, dynamic>.from(decoded as Map),
      );
      expect(
        BundledRuleStore.builtinAssets[config.id],
        file.path.replaceAll(r'\', '/'),
        reason: '$name registry mismatch',
      );
      expect(config.baseUrl, isNotEmpty, reason: '$name missing baseUrl');

      final validation = RuleValidator.validate(config.rule);
      expect(
        validation.isValid,
        isTrue,
        reason: '$name invalid: ${validation.errors.join('; ')}',
      );
    }
  });
}
