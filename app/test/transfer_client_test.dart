import 'package:easysave/services/transfer_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('easysave/transfer');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      calls.add(methodCall);
      switch (methodCall.method) {
        case 'enqueue':
          return (methodCall.arguments as Map)['jobId'] ?? 'mock_job_1';
        case 'pause':
        case 'resume':
        case 'cancel':
        case 'retry':
        case 'simulateNetwork':
        case 'clearSelfCheckJobs':
          return true;
        case 'snapshot':
          return [
            {
              'jobId': 'job_123',
              'direction': 'download',
              'state': 'running',
              'retryCount': 1,
              'batchId': 'batch_abc',
              'category': 'image',
              'createdAt': 1000,
              'updatedAt': 2000,
              'bytesRead': 512,
              'totalBytes': 1024,
              'fakePlan': 'success',
            }
          ];
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('TransferClient enqueue invokes method channel with correct arguments', () async {
    final client = TransferClient();
    final jobId = await client.enqueue(
      jobId: 'test_job_1',
      direction: 'download',
      category: 'image',
      batchId: 'batch_1',
      fakePlan: 'success',
    );

    expect(jobId, 'test_job_1');
    expect(calls.length, 1);
    expect(calls.first.method, 'enqueue');
    expect(calls.first.arguments, {
      'jobId': 'test_job_1',
      'direction': 'download',
      'category': 'image',
      'batchId': 'batch_1',
      'fakePlan': 'success',
    });
  });

  test('TransferClient pause, resume, cancel, retry invoke corresponding methods', () async {
    final client = TransferClient();
    expect(await client.pause('job_1'), isTrue);
    expect(await client.resume('job_1'), isTrue);
    expect(await client.cancel('job_1'), isTrue);
    expect(await client.retry('job_1'), isTrue);
    expect(await client.clearSelfCheckJobs(), isTrue);

    expect(calls.map((c) => c.method).toList(), ['pause', 'resume', 'cancel', 'retry', 'clearSelfCheckJobs']);
    for (final call in calls.take(4)) {
      expect((call.arguments as Map)['jobId'], 'job_1');
    }
    expect(calls.last.arguments, isNull);
  });

  test('TransferClient snapshot parses list of TransferJobSnapshot', () async {
    final client = TransferClient();
    final list = await client.snapshot();

    expect(list.length, 1);
    final job = list.first;
    expect(job.jobId, 'job_123');
    expect(job.direction, 'download');
    expect(job.state, 'running');
    expect(job.retryCount, 1);
    expect(job.batchId, 'batch_abc');
    expect(job.category, 'image');
    expect(job.createdAt, 1000);
    expect(job.updatedAt, 2000);
    expect(job.bytesRead, 512);
    expect(job.totalBytes, 1024);
    expect(job.fakePlan, 'success');
  });

  test('TransferStateChangeEvent formats log string with [XFER] prefix and shortId', () {
    const event = TransferStateChangeEvent(
      jobId: '0123456789abcdef',
      from: 'running',
      to: 'waiting_network',
      reason: 'network_error',
      retryCount: 0,
    );
    expect(event.shortId, '89abcdef');
    expect(
      event.toLogString(),
      '[XFER] job=89abcdef state=running->waiting_network reason=network_error retry=0',
    );
  });
}

