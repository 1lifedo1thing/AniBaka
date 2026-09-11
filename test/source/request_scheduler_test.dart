import 'package:baka/source/runtime/request_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'eligible hosts preserve priority and FIFO across saturated hosts',
    () async {
      final scheduler = RequestScheduler(maxConcurrent: 2, maxPerHost: 1);
      await scheduler.acquire('a');
      await scheduler.acquire('b');
      final starts = <String>[];
      Future<void> enqueue(
        String host,
        String label,
        RequestPriority priority,
      ) => scheduler.run(
        () async {
          starts.add(label);
        },
        host: host,
        priority: priority,
      );
      final jobs = [
        enqueue('a', 'a-search', RequestPriority.search),
        enqueue('c', 'c-play', RequestPriority.play),
        enqueue('b', 'b-play', RequestPriority.play),
        enqueue('c', 'c-search', RequestPriority.search),
      ];
      scheduler.release('b');
      await Future<void>.delayed(Duration.zero);
      expect(starts, ['c-play', 'b-play', 'c-search']);
      scheduler.release('a');
      await Future.wait(jobs);
      expect(starts.last, 'a-search');
    },
  );

  test('mass cancellation releases listeners and allows host reuse', () async {
    final scheduler = RequestScheduler(maxConcurrent: 2, maxPerHost: 1);
    await scheduler.acquire('a');
    final token = RequestCancelToken();
    var cancelled = 0;
    final jobs = [
      for (var i = 0; i < 2000; i++)
        scheduler
            .acquire('a', cancelToken: token)
            .then<void>(
              (_) => fail('cancelled request started'),
              onError: (Object e) {
                expect(e, isA<RequestCancelledException>());
                cancelled++;
              },
            ),
    ];
    token.cancel();
    await Future.wait(jobs);
    expect(cancelled, 2000);
    scheduler.release('a');
    await scheduler.run(() async {}, host: 'a');
  });

  test('exceptions and cancellation after acquire return the slot', () async {
    final scheduler = RequestScheduler(maxConcurrent: 1);
    final token = RequestCancelToken();
    final cancelled = scheduler.run(
      () async => fail('cancelled task ran'),
      host: 'a',
      cancelToken: token,
    );
    token.cancel();
    await expectLater(cancelled, throwsA(isA<RequestCancelledException>()));
    await expectLater(
      scheduler.run(() async => throw StateError('test'), host: 'a'),
      throwsStateError,
    );
    expect(await scheduler.run(() async => 42, host: 'b'), 42);
  });
}
