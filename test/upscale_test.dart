import 'dart:io';

import 'package:aniview/upscale.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const a = 'Anime4K_';

List<String> names(List<String> short) => [for (final s in short) '$a$s.glsl'];

void main() {
  group('shaderChain on desktop', () {
    List<String> chain(Upscale tier, int height) =>
        shaderChain(tier, sourceHeight: height, mobile: false);

    test('off runs nothing', () {
      for (final h in [360, 720, 1080]) {
        expect(chain(Upscale.off, h), isEmpty);
      }
    });

    test('mode A from 900 up', () {
      for (final h in [900, 1080]) {
        expect(
          chain(Upscale.fast, h),
          names([
            'Clamp_Highlights', 'Restore_CNN_M', 'Upscale_CNN_x2_M', //
            'AutoDownscalePre_x2', 'AutoDownscalePre_x4', 'Upscale_CNN_x2_S',
          ]),
        );
        expect(
          chain(Upscale.quality, h),
          names([
            'Clamp_Highlights', 'Restore_CNN_VL', 'Upscale_CNN_x2_VL', //
            'AutoDownscalePre_x2', 'AutoDownscalePre_x4', 'Upscale_CNN_x2_M',
          ]),
        );
      }
    });

    test('mode B from 600 to 899 restores softly', () {
      for (final h in [600, 720, 899]) {
        expect(
          chain(Upscale.fast, h),
          names([
            'Clamp_Highlights', 'Restore_CNN_Soft_M', 'Upscale_CNN_x2_M', //
            'AutoDownscalePre_x2', 'AutoDownscalePre_x4', 'Upscale_CNN_x2_S',
          ]),
        );
        expect(
          chain(Upscale.quality, h),
          names([
            'Clamp_Highlights', 'Restore_CNN_Soft_VL', 'Upscale_CNN_x2_VL', //
            'AutoDownscalePre_x2', 'AutoDownscalePre_x4', 'Upscale_CNN_x2_M',
          ]),
        );
      }
    });

    test('mode C under 600 denoises while it upscales', () {
      for (final h in [360, 480, 599]) {
        expect(
          chain(Upscale.fast, h),
          names([
            'Clamp_Highlights', 'Upscale_Denoise_CNN_x2_M', //
            'AutoDownscalePre_x2', 'AutoDownscalePre_x4', 'Upscale_CNN_x2_S',
          ]),
        );
        expect(
          chain(Upscale.quality, h),
          names([
            'Clamp_Highlights', 'Upscale_Denoise_CNN_x2_VL', //
            'AutoDownscalePre_x2', 'AutoDownscalePre_x4', 'Upscale_CNN_x2_M',
          ]),
        );
      }
    });
  });

  test('mobile chains are short whatever the source', () {
    for (final h in [360, 599, 600, 899, 900, 1080]) {
      expect(shaderChain(Upscale.off, sourceHeight: h, mobile: true), isEmpty);
      expect(
        shaderChain(Upscale.fast, sourceHeight: h, mobile: true),
        names(['Clamp_Highlights', 'Upscale_CNN_x2_S']),
      );
      expect(
        shaderChain(Upscale.quality, sourceHeight: h, mobile: true),
        names(['Restore_CNN_S', 'Upscale_CNN_x2_M']),
      );
    }
  });

  group('shouldUpscale', () {
    const source = Size(1280, 720);

    test('needs the target 1.2× the source', () {
      expect(
        shouldUpscale(source, const Size(1536, 864)),
        isTrue,
      ); // exactly 1.2×
      expect(shouldUpscale(source, const Size(1920, 1080)), isTrue);
      expect(shouldUpscale(source, const Size(1535, 863)), isFalse);
      expect(shouldUpscale(source, source), isFalse);
      expect(shouldUpscale(source, const Size(640, 360)), isFalse);
    });

    test('in either width or height', () {
      expect(shouldUpscale(source, const Size(1536, 700)), isTrue);
      expect(shouldUpscale(source, const Size(1200, 864)), isTrue);
    });

    test('1080p on a 1080p screen does not upscale', () {
      expect(
        shouldUpscale(const Size(1920, 1080), const Size(1920, 1080)),
        isFalse,
      );
    });

    test('an unknown source does not upscale', () {
      expect(shouldUpscale(Size.zero, const Size(1920, 1080)), isFalse);
    });
  });

  test('restoreOnly restores lightly on mobile only', () {
    expect(restoreOnly(Upscale.off, mobile: true), isEmpty);
    expect(restoreOnly(Upscale.fast, mobile: true), names(['Restore_CNN_S']));
    expect(
      restoreOnly(Upscale.quality, mobile: true),
      names(['Restore_CNN_S']),
    );
    for (final t in Upscale.values) {
      expect(restoreOnly(t, mobile: false), isEmpty);
    }
  });

  group('upscaleTarget', () {
    test('fits 720p into a 4K box', () {
      expect(
        upscaleTarget(const Size(1280, 720), const Size(3840, 2160), 1),
        const Size(3840, 2160),
      );
    });

    test('times the pixel ratio', () {
      expect(
        upscaleTarget(const Size(1280, 720), const Size(960, 540), 2),
        const Size(1920, 1080),
      );
    });

    test('pillarboxes a 4:3 source', () {
      expect(
        upscaleTarget(const Size(640, 480), const Size(1920, 1080), 1),
        const Size(1440, 1080),
      );
    });

    test('letterboxes in a tall box', () {
      expect(
        upscaleTarget(const Size(1920, 1080), const Size(1080, 1920), 1),
        const Size(1080, 608),
      );
    });

    test('caps a box wider than 4K keeping the aspect', () {
      expect(
        upscaleTarget(const Size(1920, 1080), const Size(5120, 2880), 1),
        const Size(3840, 2160),
      );
      expect(
        upscaleTarget(const Size(1920, 800), const Size(2560, 1440), 2),
        const Size(3840, 1600),
      );
      expect(
        upscaleTarget(const Size(640, 480), const Size(3000, 2000), 1.5),
        const Size(2880, 2160),
      );
    });

    test('is empty for an unknown source', () {
      expect(upscaleTarget(Size.zero, const Size(1920, 1080), 1), Size.zero);
    });
  });

  test('stepDown goes quality, fast, off, then nothing', () {
    expect(stepDown(Upscale.quality), Upscale.fast);
    expect(stepDown(Upscale.fast), Upscale.off);
    expect(stepDown(Upscale.off), isNull);
  });

  test('tooSlow above 10% dropped', () {
    expect(tooSlow(dropped: 0, shown: 0), isFalse);
    expect(tooSlow(dropped: 0, shown: 100), isFalse);
    expect(tooSlow(dropped: 10, shown: 90), isFalse); // exactly 10%
    expect(tooSlow(dropped: 11, shown: 89), isTrue);
    expect(tooSlow(dropped: 5, shown: 0), isTrue);
  });

  test('tiers store by a stable name', () {
    expect(Upscale.values.map((t) => t.name), ['off', 'fast', 'quality']);
    for (final t in Upscale.values) {
      expect(Upscale.parse(t.name), t);
      expect(t.label, isNotEmpty);
    }
    expect(Upscale.parse(null), Upscale.off);
    expect(Upscale.parse('ultra'), Upscale.off);
  });

  group('bundled shaders', () {
    final chained = {
      for (final t in Upscale.values)
        for (final mobile in [false, true]) ...[
          ...restoreOnly(t, mobile: mobile),
          for (final h in [480, 720, 1080])
            ...shaderChain(t, sourceHeight: h, mobile: mobile),
        ],
    };

    test('every chained shader is bundled', () {
      expect(chained, isNotEmpty);
      expect(bundledShaders.toSet(), containsAll(chained));
      for (final name in bundledShaders) {
        final file = File('$shaderAssets/$name');
        expect(file.existsSync(), isTrue, reason: name);
        // Upstream's own headers, unmodified.
        expect(
          file.readAsStringSync(),
          startsWith(
            name.contains('AutoDownscalePre')
                ? '// This is free and unencumbered software released into the public domain.'
                : '// MIT License',
          ),
          reason: name,
        );
      }
      expect(
        File('$shaderAssets/LICENSE').readAsStringSync(),
        contains('Copyright (c) 2019 bloc97'),
      );
    });

    test('pubspec bundles the folder', () {
      final pubspec = File('pubspec.yaml')
          .readAsLinesSync()
          .map((l) => l.trim());
      expect(pubspec, contains('- $shaderAssets/'));
    });
  });

  group('installShaders', () {
    late Directory dir;
    var loads = <String>[];
    Future<ByteData> load(String key) async {
      loads.add(key);
      final bytes = await File(key).readAsBytes();
      return ByteData.sublistView(Uint8List.fromList(bytes));
    }

    setUp(() {
      dir = Directory.systemTemp.createTempSync('shaders');
      loads = [];
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('copies a chain once and returns its absolute paths', () async {
      final chain = shaderChain(
        Upscale.quality,
        sourceHeight: 720,
        mobile: false,
      );
      final paths = await installShaders(
        chain,
        load: load,
        supportDir: () async => dir,
      );

      expect(loads, [for (final n in chain) '$shaderAssets/$n']);
      expect(paths, [for (final n in chain) p.join(dir.path, shaderFolder, n)]);
      for (final (i, path) in paths.indexed) {
        expect(p.isAbsolute(path), isTrue);
        expect(
          File(path).readAsBytesSync(),
          File('$shaderAssets/${chain[i]}').readAsBytesSync(),
        );
      }
      expect(
        Directory(p.join(dir.path, shaderFolder))
            .listSync()
            .where((e) => e.path.endsWith('.part')),
        isEmpty,
      );

      // Set the clock back so a rewrite would show.
      for (final path in paths) {
        File(path).setLastModifiedSync(DateTime(2020));
      }
      expect(
        await installShaders(chain, load: load, supportDir: () async => dir),
        paths,
      );
      for (final path in paths) {
        expect(File(path).lastModifiedSync(), DateTime(2020));
      }
    });

    test('replaces a file of the wrong length', () async {
      final chain = shaderChain(Upscale.fast, sourceHeight: 1080, mobile: true);
      final target = File(p.join(dir.path, shaderFolder, chain.first))
        ..createSync(recursive: true)
        ..writeAsStringSync('truncated');
      await installShaders(chain, load: load, supportDir: () async => dir);
      expect(
        target.readAsBytesSync(),
        File('$shaderAssets/${chain.first}').readAsBytesSync(),
      );
    });

    test('off installs nothing', () async {
      expect(
        await installShaders(const [], load: load, supportDir: () async => dir),
        isEmpty,
      );
      expect(loads, isEmpty);
    });
  });
}
