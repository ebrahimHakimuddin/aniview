import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 30),
  responseDataCallback: (data) async {
    await writeResponseData(data);
    // The binding can omit a timeout from its failure details. Only a suite
    // that reached the final assertion is a completed native test run.
    if (data?['native_completed'] != true) {
      throw StateError('Native suite did not finish; reject the driver pass');
    }
  },
);
