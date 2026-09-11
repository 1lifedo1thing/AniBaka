import 'package:baka/source/models/source_rule.dart';

/// Single prompt/validation-facing description of the anx-rule/2 language.
class RuleLanguageSpec {
  RuleLanguageSpec._();

  static const Map<String, String> operations = {
    'template': 'Render a string template with variables.',
    'setVar': 'Store a rendered value in a named variable.',
    'query': 'Build or transform URL query parameters.',
    'fetch': 'Perform an HTTP request and place its body in current.',
    'follow': 'Resolve and fetch a URL found in current content.',
    'select': 'Select HTML with css and extract text/html/attribute.',
    'regex': 'Extract a regex capture from current text.',
    'replace': 'Replace literal or regex text in current.',
    'json': 'Decode current text as JSON.',
    'pick': 'Read a JSON path or indexed value.',
    'crypto': 'Apply base64/hash/AES transformations.',
    'baseN': 'Encode or decode using a custom alphabet.',
    'ecPlayer': 'Resolve an EC player payload.',
    'maccmsVerify': 'Complete the supported MacCMS verification flow.',
    'first': 'Try branches in order and keep the first successful branch.',
    'searchList': 'Build Series items from HTML CSS/XPath selectors.',
    'jsonSeries': 'Build Series items from a JSON list.',
    'episodes': 'Build Source and Episode items from HTML.',
    'jsonEpisodes': 'Build Source and Episode items from JSON.',
    'maccmsApiEpisodes': 'Build episode lines from a MacCMS provide API.',
    'videoUrl': 'Extract a playable URL from current content.',
    'setMediaHeaders': 'Attach HTTP headers to the resolved media.',
    'playerAaaa': 'Parse the common player_aaaa bootstrap object.',
    'playerDecrypt': 'Decrypt the supported player payload.',
    'sniff': 'Use WebView to follow a page and sniff playable media.',
    'anime1Search': 'Run the built-in Anime1 search protocol.',
    'anime1Detail': 'Run the built-in Anime1 episode protocol.',
    'anime1Play': 'Run the built-in Anime1 playback protocol.',
    'hhPlayer': 'Resolve the supported HHPlayer bootstrap API.',
    'torrentRecords': 'Build torrent episodes from supported records.',
    'maccmsSuggest': 'Search through MacCMS suggest endpoints.',
  };

  static final Set<String> knownOps = Set.unmodifiable(operations.keys);

  static String get promptReference {
    final ops = operations.entries
        .map((entry) => '- ${entry.key}: ${entry.value}')
        .join('\n');
    return '''
Format: $kSourceRuleFormatV2
Root fields: id, name, baseUrl, optional iconUrl/description, and pipeline.
Pipeline fields: optional recipes, headers, search, detail, play, useWebview,
directConnection, mediaValidationTimeoutMs. Each stage is an array of objects
with an op field. Supported recipes: maccms, player_aaaa.

Supported operations:
$ops

The search stage must produce Series results, detail must produce playback
lines and episodes, and play must produce a direct media URL. Prefer generic
operations over inventing a new operation. Never return executable Dart code.
''';
  }
}
