import 'package:baka/instance.dart';
import 'package:baka/models/ai_rule_authoring.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AiRuleSettingsService {
  AiRuleSettingsService._();

  static final AiRuleSettingsService instance = AiRuleSettingsService._();

  static const _baseUrlKey = 'ai_rule_base_url';
  static const _modelKey = 'ai_rule_model';
  static const _apiKeyKey = 'ai_rule_api_key';
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  Future<AiProviderConfig> load() async {
    return AiProviderConfig(
      baseUrl: Instances.sp.getString(_baseUrlKey) ?? '',
      model: Instances.sp.getString(_modelKey) ?? '',
      apiKey: await _secureStorage.read(key: _apiKeyKey) ?? '',
    );
  }

  Future<void> save(AiProviderConfig config) async {
    await Future.wait<void>([
      Instances.sp.setString(_baseUrlKey, config.baseUrl.trim()),
      Instances.sp.setString(_modelKey, config.model.trim()),
      if (config.apiKey.trim().isEmpty)
        _secureStorage.delete(key: _apiKeyKey)
      else
        _secureStorage.write(key: _apiKeyKey, value: config.apiKey.trim()),
    ]);
  }
}
