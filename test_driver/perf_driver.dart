// Host side of integration_test/perf_test.dart under `flutter drive --profile`: writes what the scenarios reported
// to $PERF_OUT/$PERF_RUN.json (default build/perf/perf.json), failed runs included, so a broken scenario still
// leaves the others' numbers.
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 30),
  writeResponseOnFailure: true,
  responseDataCallback: (data) => writeResponseData(
    data,
    testOutputFilename: Platform.environment['PERF_RUN'] ?? 'perf',
    destinationDirectory: Platform.environment['PERF_OUT'] ?? 'build/perf',
  ),
);
