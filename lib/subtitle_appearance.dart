import 'package:flutter/material.dart';

class SubtitleAppearance {
  const SubtitleAppearance({
    this.size = 22,
    this.color = 0xffffffff,
    this.background = 0,
    this.edge = 'shadow',
    this.font = 'default',
    this.bold = false,
    this.bottom = 32,
  });

  final double size, background, bottom;
  final int color;
  final String edge, font;
  final bool bold;

  static const colors = {
    0xffffffff: 'White',
    0xffffff00: 'Yellow',
    0xff00ffff: 'Cyan',
  };
  static const edges = {
    'shadow': 'Shadow',
    'outline': 'Outline',
    'none': 'None',
  };
  static const fonts = {
    'default': 'Default',
    'serif': 'Serif',
    'monospace': 'Monospace',
  };
  static final positions = {
    16.0: 'Low',
    32.0: 'Normal',
    64.0: 'Raised',
    96.0: 'High',
  };
  static final backgrounds = {
    0.0: 'None',
    .5: 'Translucent black',
    .85: 'Dark black',
  };

  factory SubtitleAppearance.fromJson(Map data) => SubtitleAppearance(
    size: data['size'] is num
        ? (data['size'] as num).toDouble().clamp(14, 40)
        : 22,
    color: colors.containsKey(data['color'])
        ? data['color'] as int
        : 0xffffffff,
    background: backgrounds.containsKey(data['background'])
        ? (data['background'] as num).toDouble()
        : 0,
    edge: edges.containsKey(data['edge']) ? data['edge'] as String : 'shadow',
    font: fonts.containsKey(data['font']) ? data['font'] as String : 'default',
    bold: data['bold'] == true,
    bottom: positions.containsKey(data['bottom'])
        ? (data['bottom'] as num).toDouble()
        : 32,
  );

  Map<String, Object> toJson() => {
    'size': size,
    'color': color,
    'background': background,
    'edge': edge,
    'font': font,
    'bold': bold,
    'bottom': bottom,
  };

  SubtitleAppearance copyWith({
    double? size,
    int? color,
    double? background,
    String? edge,
    String? font,
    bool? bold,
    double? bottom,
  }) => SubtitleAppearance(
    size: size ?? this.size,
    color: color ?? this.color,
    background: background ?? this.background,
    edge: edge ?? this.edge,
    font: font ?? this.font,
    bold: bold ?? this.bold,
    bottom: bottom ?? this.bottom,
  );

  TextStyle style({double scale = 1}) => TextStyle(
    fontSize: size * scale,
    color: Color(color),
    backgroundColor: background == 0
        ? null
        : Colors.black.withValues(alpha: background),
    fontFamily: font == 'default' ? null : font,
    fontWeight: bold ? FontWeight.bold : FontWeight.normal,
    height: 1.3,
    shadows: switch (edge) {
      'outline' => const [
        Shadow(offset: Offset(-1, -1)),
        Shadow(offset: Offset(1, -1)),
        Shadow(offset: Offset(-1, 1)),
        Shadow(offset: Offset(1, 1)),
      ],
      'none' => const [],
      _ => const [Shadow(blurRadius: 8), Shadow(blurRadius: 2)],
    },
  );
}
