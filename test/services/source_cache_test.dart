import 'package:baka/source/models/source_rule.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

class _Resolver extends PipelineSourceAdapter {
  _Resolver(String id, this.url)
    : super(
        SourceRule(
          id: id,
          name: 'Same name',
          baseUrl: 'https://fixture.invalid',
        ),
      );
  String url;
  int calls = 0;
  @override
  Future<String> getDownloadUrl(String id) async {
    calls++;
    return url;
  }
}

void main() {
  test('episode invalidation forces one fresh parse, then caches it', () async {
    final adapter = _Resolver('refresh', 'https://fixture.invalid/old.mp4');
    addTearDown(adapter.dispose);
    await adapter.resolveDownloadUrl('1', skipValidation: true);
    adapter.url = 'https://fixture.invalid/new.mp4';
    adapter.invalidateDownloadUrl('1');
    expect(
      await adapter.resolveDownloadUrl('1', skipValidation: true),
      adapter.url,
    );
    expect(
      await adapter.resolveDownloadUrl('1', skipValidation: true),
      adapter.url,
    );
    expect(adapter.calls, 2);
  });
}
