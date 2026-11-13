/// Anime upscaling with the bundled Anime4K v4.0.1 shaders: which shaders a tier runs, when to run them, and putting
/// them on disk for mpv.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// How hard to upscale. [name] is what gets stored.
enum Upscale {
  off('Off'),
  fast('Fast'),
  quality('Quality');

  const Upscale(this.label);

  final String label;

  /// The tier stored as [name], or [off] for anything unknown.
  static Upscale parse(String? name) =>
      values.firstWhere((t) => t.name == name, orElse: () => off);
}

/// Where the shaders are bundled.
const shaderAssets = 'assets/shaders';

const _clamp = 'Anime4K_Clamp_Highlights.glsl';
const _restoreS = 'Anime4K_Restore_CNN_S.glsl';
const _restoreM = 'Anime4K_Restore_CNN_M.glsl';
const _restoreVL = 'Anime4K_Restore_CNN_VL.glsl';
const _restoreSoftM = 'Anime4K_Restore_CNN_Soft_M.glsl';
const _restoreSoftVL = 'Anime4K_Restore_CNN_Soft_VL.glsl';
const _upS = 'Anime4K_Upscale_CNN_x2_S.glsl';
const _upM = 'Anime4K_Upscale_CNN_x2_M.glsl';
const _upVL = 'Anime4K_Upscale_CNN_x2_VL.glsl';
const _denoiseM = 'Anime4K_Upscale_Denoise_CNN_x2_M.glsl';
const _denoiseVL = 'Anime4K_Upscale_Denoise_CNN_x2_VL.glsl';
const _down2 = 'Anime4K_AutoDownscalePre_x2.glsl';
const _down4 = 'Anime4K_AutoDownscalePre_x4.glsl';

/// Every shader file bundled under [shaderAssets]. All are MIT but the two AutoDownscalePre, which upstream releases
/// into the public domain.
const bundledShaders = [
  _clamp, _restoreS, _restoreM, _restoreVL, _restoreSoftM, _restoreSoftVL, //
  _upS, _upM, _upVL, _denoiseM, _denoiseVL, _down2, _down4,
];

/// The shader files [tier] runs, in order, for a video [sourceHeight] pixels tall; empty for [Upscale.off].
///
/// Desktops get upstream's official chains: mode A for 1080p-like sources (900 and up), B for 720p-like (600–899)
/// with the softer restore, and C for SD (under 600), which denoises while it upscales. Phones and TV boxes have far
/// weaker GPUs, so [mobile] gets a short chain whatever the source.
List<String> shaderChain(
  Upscale tier, {
  required int sourceHeight,
  required bool mobile,
}) {
  if (tier == Upscale.off) return const [];
  final fast = tier == Upscale.fast;
  if (mobile) return fast ? const [_clamp, _upS] : const [_restoreS, _upM];
  final tail = fast
      ? const [_down2, _down4, _upS]
      : const [_down2, _down4, _upM];
  if (sourceHeight < 600) {
    return [_clamp, fast ? _denoiseM : _denoiseVL, ...tail];
  }
  final restore = sourceHeight < 900
      ? (fast ? _restoreSoftM : _restoreSoftVL)
      : (fast ? _restoreM : _restoreVL);
  return [_clamp, restore, fast ? _upM : _upVL, ...tail];
}

/// Whether the video is shown big enough to upscale: [target] (the on-screen video box in physical pixels) at least
/// 1.2× [source] in width or height, as Anime4K's own `OUTPUT.w MAIN.w / 1.200 >` gate. When it isn't, run no shaders
/// beyond [restoreOnly].
bool shouldUpscale(Size source, Size target) {
  if (source.width <= 0 || source.height <= 0) return false;
  return target.width >= source.width * 1.2 ||
      target.height >= source.height * 1.2;
}

/// The shaders to run when [shouldUpscale] says no, as a 1080p source on a 1080p screen: a light restore on [mobile]
/// for any tier but [Upscale.off], nothing on desktops.
List<String> restoreOnly(Upscale tier, {required bool mobile}) =>
    mobile && tier != Upscale.off ? const [_restoreS] : const [];

/// The largest output the shaders are asked for.
const maxUpscaleTarget = Size(3840, 2160);

/// The video's rectangle when [source] is fitted inside [box] (logical pixels) keeping its aspect, in physical pixels
/// at [devicePixelRatio], capped to [maxUpscaleTarget] keeping its aspect.
Size upscaleTarget(Size source, Size box, double devicePixelRatio) {
  if (source.isEmpty || box.isEmpty || devicePixelRatio <= 0) return Size.zero;
  final fit =
      math.min(box.width / source.width, box.height / source.height) *
      devicePixelRatio;
  var w = source.width * fit, h = source.height * fit;
  final cap = math.min(
    1.0,
    math.min(maxUpscaleTarget.width / w, maxUpscaleTarget.height / h),
  );
  w *= cap;
  h *= cap;
  return Size(w.roundToDouble(), h.roundToDouble());
}

/// The next cheaper tier when [tier] can't keep up: quality, then fast, then off, then nothing.
Upscale? stepDown(Upscale tier) => switch (tier) {
  Upscale.quality => Upscale.fast,
  Upscale.fast => Upscale.off,
  Upscale.off => null,
};

/// Whether more than 10% of the frames were [dropped], out of those dropped plus those [shown].
bool tooSlow({required int dropped, required int shown}) {
  final total = dropped + shown;
  return total > 0 && dropped * 10 > total;
}

/// The folder under the app's support folder the shaders are copied to; versioned so an update brings fresh files.
const shaderFolder = 'shaders/anime4k-4.0.1';

/// Copies [chain]'s bundled shaders to real files, which mpv needs, and returns their absolute paths in order.
///
/// Files go under [shaderFolder] in [supportDir] (the app's support folder by default), [load] reads an asset by its
/// key ([rootBundle] by default). A file already there with the asset's length is left alone.
Future<List<String>> installShaders(
  List<String> chain, {
  Future<ByteData> Function(String key)? load,
  Future<Directory> Function()? supportDir,
}) async {
  if (chain.isEmpty) return const [];
  load ??= rootBundle.load;
  final root = await (supportDir ?? getApplicationSupportDirectory)();
  final dir = Directory(p.join(root.path, shaderFolder));
  await dir.create(recursive: true);
  final paths = <String>[];
  for (final name in chain) {
    final file = File(p.join(dir.absolute.path, name));
    final data = await load('$shaderAssets/$name');
    if (!await file.exists() || await file.length() != data.lengthInBytes) {
      // Write beside it and rename, so a half-written file is never read as a shader.
      final part = File('${file.path}.part');
      await part.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      await part.rename(file.path);
    }
    paths.add(file.path);
  }
  return paths;
}

/// Lists Anime4K's MIT licence on the app's licences page.
void registerShaderLicense() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'Anime4K',
    ], await rootBundle.loadString('$shaderAssets/LICENSE'));
  });
}
