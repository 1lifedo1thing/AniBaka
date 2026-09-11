import 'dart:async';

import 'package:baka/services/matching/probe_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProbeScheduler', () {
    test('runs jobs with bounded concurrency', () async {
      final started = <int>[];
      final gates = <int, Completer<void>>{};
      final scheduler = ProbeScheduler<int>(
        concurrency: 2,
        keyOf: (job) => '$job',
        run: (job) {
          started.add(job);
          return (gates[job] = Completer<void>()).future;
        },
      );

      for (var job = 1; job <= 5; job++) {
        expect(scheduler.add(job), isTrue);
      }
      expect(started, [1, 2]);
      expect(scheduler.activeCount, 2);
      expect(scheduler.queuedCount, 3);

      gates[1]!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(started, [1, 2, 3]);

      gates[2]!.complete();
      gates[3]!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(started, [1, 2, 3, 4, 5]);

      gates[4]!.complete();
      gates[5]!.complete();
      await scheduler.drained;
      expect(scheduler.isBusy, isFalse);
      expect(scheduler.activeCount, 0);
      expect(scheduler.queuedCount, 0);
    });

    test('accepts each key once per run and again after reset', () async {
      final runs = <String>[];
      final scheduler = ProbeScheduler<String>(
        concurrency: 2,
        keyOf: (job) => job,
        run: (job) async => runs.add(job),
      );

      expect(scheduler.add('a'), isTrue);
      expect(scheduler.add('a'), isFalse);
      expect(scheduler.contains('a'), isTrue);
      await scheduler.drained;
      expect(runs, ['a']);

      scheduler.reset();
      expect(scheduler.contains('a'), isFalse);
      expect(scheduler.add('a'), isTrue);
      await scheduler.drained;
      expect(runs, ['a', 'a']);
    });

    test('close discards queued work and lets in-flight jobs settle', () async {
      final started = <int>[];
      final gate = Completer<void>();
      final scheduler = ProbeScheduler<int>(
        concurrency: 1,
        keyOf: (job) => '$job',
        run: (job) async {
          started.add(job);
          await gate.future;
        },
      );

      scheduler.add(1);
      scheduler.add(2);
      scheduler.close();
      expect(scheduler.isClosed, isTrue);
      expect(scheduler.add(3), isFalse);

      gate.complete();
      await scheduler.drained;
      expect(started, [1]);
      expect(scheduler.isBusy, isFalse);
    });

    test('a failing job does not stop the remaining queue', () async {
      final runs = <int>[];
      final scheduler = ProbeScheduler<int>(
        concurrency: 2,
        keyOf: (job) => '$job',
        run: (job) async {
          if (job == 1) throw StateError('boom');
          runs.add(job);
        },
      );

      scheduler.add(1);
      scheduler.add(2);
      await scheduler.drained;
      expect(runs, [2]);
      expect(scheduler.isBusy, isFalse);
    });

    test('drained completes once and reports a fresh busy cycle', () async {
      final gate = Completer<void>();
      final scheduler = ProbeScheduler<int>(
        concurrency: 1,
        keyOf: (job) => '$job',
        run: (job) async => gate.future,
      );

      expect(scheduler.isBusy, isFalse);
      await scheduler.drained;

      scheduler.add(1);
      final first = scheduler.drained;
      gate.complete();
      await first;
      expect(scheduler.isBusy, isFalse);

      scheduler.add(2);
      scheduler.close();
      await scheduler.drained;
      expect(scheduler.isBusy, isFalse);
    });
  });
}
