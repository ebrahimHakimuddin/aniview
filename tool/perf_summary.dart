// Summarizes integration_test/perf_test.dart runs: per scenario, the median over runs (and the min–max spread) of
// UI build and raster average, p90, p99, worst frame and frames over 16.6 ms (one 60 Hz frame) and over 8.3 ms (one
// 120 Hz frame), side by side for two sets of runs.
//
//   dart run tool/perf_summary.dart <baseline dir> <current dir> [summary.md]
//
// Each dir holds one JSON per run, as test_driver/perf_driver.dart writes them. With one dir, it summarizes that
// set alone. Writes the Markdown table to stdout and, when given, to the file, with summary.json beside it.
import 'dart:convert';
import 'dart:io';

/// One frame budget at 60 Hz.
const budgetMicros = 16667;

/// One frame budget at 120 Hz.
const budget120Micros = 8333;

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/perf_summary.dart <baseline dir> [<current dir>] [summary.md]',
    );
    exit(64);
  }
  final dirs = args.where((a) => !a.endsWith('.md')).toList();
  final out = args.where((a) => a.endsWith('.md')).firstOrNull;
  final sides = {for (final d in dirs) _name(d): _load(d)};
  final scenarios = <String>{
    for (final runs in sides.values)
      for (final run in runs) ...run.keys.where((k) => k != 'meta'),
  };

  final json = <String, Object?>{};
  // scenario → check → side → each run's result.
  final passes = <String, Map<String, Map<String, List<String>>>>{};
  final md = StringBuffer()
    ..writeln('# Frame timings')
    ..writeln()
    ..writeln(
      'Median over runs, with [min–max] across runs. Times in ms; "over 16.6" / "over 8.3" = frames slower than '
      'one 60 Hz / 120 Hz frame. '
      'Runs per side: ${sides.map((k, v) => MapEntry(k, v.length))}.',
    )
    ..writeln();
  for (final scenario in scenarios) {
    final perSide = <String, Map<String, List<num>>>{};
    final skipped = <String, String>{};
    for (final MapEntry(key: side, value: runs) in sides.entries) {
      final stats = <String, List<num>>{};
      for (final run in runs) {
        final data = run[scenario];
        if (data is! Map) continue;
        if (data['skipped'] case final String why) {
          skipped[side] = why;
          continue;
        }
        // A scenario of checks alone records no frames.
        if (data['frame_build_times'] is List) {
          _frameStats(data).forEach((k, v) => (stats[k] ??= []).add(v));
        }
        if (data['checks'] case final Map checks) {
          checks.forEach((k, v) {
            final tally = (passes[scenario] ??= {})[k] ??= {};
            tally[side] = [...?tally[side], v == 'pass' ? 'pass' : '$v'];
          });
        }
        if (data['extra'] case final Map extra) {
          extra.forEach((k, v) {
            if (v is num) (stats['extra.$k'] ??= []).add(v);
          });
        }
      }
      perSide[side] = stats;
    }
    json[scenario] = {
      for (final MapEntry(:key, :value) in perSide.entries)
        key: {
          for (final MapEntry(key: metric, value: runs) in value.entries)
            metric: {
              'median': _median(runs),
              'min': _min(runs),
              'max': _max(runs),
              'runs': runs,
            },
        },
      if (skipped.isNotEmpty) 'skipped': skipped,
    };
    md
      ..writeln('## $scenario')
      ..writeln();
    if (perSide.values.every((s) => s.isEmpty)) {
      md
        ..writeln('Skipped: ${skipped.values.toSet().join('; ')}')
        ..writeln();
      continue;
    }
    md
      ..writeln('| metric | ${perSide.keys.join(' | ')} |')
      ..writeln('|---|${perSide.keys.map((_) => '---').join('|')}|');
    final metrics = <String>{for (final s in perSide.values) ...s.keys};
    for (final metric in metrics) {
      final cells = [
        for (final s in perSide.values)
          switch (s[metric]) {
            final runs? when runs.isNotEmpty => _cell(runs),
            _ => '–',
          },
      ];
      md.writeln('| $metric | ${cells.join(' | ')} |');
    }
    md.writeln();
    if (passes[scenario] case final checks?) {
      md
        ..writeln('| check | ${perSide.keys.join(' | ')} |')
        ..writeln('|---|${perSide.keys.map((_) => '---').join('|')}|');
      checks.forEach((check, bySide) {
        final cells = [
          for (final side in perSide.keys)
            switch (bySide[side]) {
              final runs? =>
                '${runs.where((r) => r == 'pass').length}/${runs.length} pass'
                    '${runs.where((r) => r != 'pass').toSet().map((r) => '; $r').join()}',
              _ => '–',
            },
        ];
        md.writeln('| $check | ${cells.join(' | ').replaceAll('\n', ' ')} |');
      });
      md.writeln();
      (json[scenario] as Map)['checks'] = checks;
    }
  }
  stdout.write(md);
  if (out != null) {
    File(out).writeAsStringSync(md.toString());
    File('${File(out).parent.path}/summary.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
  }
}

String _name(String dir) =>
    dir.split(Platform.pathSeparator).where((s) => s.isNotEmpty).last;

/// Every run in [dir]: its JSON files, oldest name first.
List<Map<String, dynamic>> _load(String dir) {
  final files =
      Directory(dir)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final f in files)
      jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
  ];
}

/// The scenario's frames, from the raw per-frame times (µs), so the budget is 16.6 ms rather than the
/// summarizer's 16.
Map<String, num> _frameStats(Map data) {
  final build = [for (final t in data['frame_build_times'] as List) t as int]
    ..sort();
  final raster = [
    for (final t in data['frame_rasterizer_times'] as List) t as int,
  ]..sort();
  Map<String, num> of(String name, List<int> t) => {
    '$name avg': _ms(t.isEmpty ? 0 : t.reduce((a, b) => a + b) / t.length),
    '$name p90': _ms(_pct(t, .9)),
    '$name p99': _ms(_pct(t, .99)),
    '$name worst': _ms(t.isEmpty ? 0 : t.last),
    '$name over 16.6': t.where((x) => x > budgetMicros).length,
    '$name over 8.3': t.where((x) => x > budget120Micros).length,
    '$name total': _ms(t.isEmpty ? 0 : t.reduce((a, b) => a + b)),
  };
  return {
    'frames': build.length,
    ...of('build', build),
    ...of('raster', raster),
  };
}

num _ms(num micros) => (micros / 1000 * 100).round() / 100;

/// As FrameTimingSummarizer picks it.
num _pct(List<int> sorted, double p) =>
    sorted.isEmpty ? 0 : sorted[((sorted.length - 1) * p).round()];

num _median(List<num> v) {
  final s = [...v]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

num _min(List<num> v) => v.reduce((a, b) => a < b ? a : b);
num _max(List<num> v) => v.reduce((a, b) => a > b ? a : b);

String _fmt(num v) => v is int || v == v.roundToDouble() && v.abs() >= 100
    ? '${v.round()}'
    : v.toStringAsFixed(2);

String _cell(List<num> runs) => runs.length == 1
    ? _fmt(runs.single)
    : '${_fmt(_median(runs))} [${_fmt(_min(runs))}–${_fmt(_max(runs))}]';
