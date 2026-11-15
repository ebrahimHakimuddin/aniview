/// A watch party's invite as a QR code: `aniview://party/<code>` for a phone's camera to open.
///
/// Drawn here from the `qr` package's module matrix, dark modules on a white quiet zone whatever the theme, so a
/// camera reads it off a dark TV the same as off a light phone.
library;

import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

/// Modules of white around the code, as the QR standard asks for.
const partyQrQuietZone = 4;

/// The module matrix for [data]: medium error correction, which survives a TV's glare and a slight angle, in the
/// smallest version that holds it.
QrImage partyQrImage(String data) => QrImage(
  QrCode(
    payload: QrPayload.fromString(data),
    errorCorrectLevel: QrErrorCorrectLevel.medium,
  ),
);

/// Paints [image] as a square filling the shorter side: a white [partyQrQuietZone] around black modules. Edges
/// aren't antialiased, so neighbouring modules never show a seam.
class PartyQrPainter extends CustomPainter {
  PartyQrPainter(this.image);

  final QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    final count = image.moduleCount;
    final side = size.shortestSide;
    final module = side / (count + 2 * partyQrQuietZone);
    final origin = Offset(
      (size.width - side) / 2 + module * partyQrQuietZone,
      (size.height - side) / 2 + module * partyQrQuietZone,
    );
    canvas.drawRect(
      Rect.fromLTWH(
        (size.width - side) / 2,
        (size.height - side) / 2,
        side,
        side,
      ),
      Paint()..color = Colors.white,
    );
    final dark = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (var row = 0; row < count; row++) {
      // A run of dark modules along the row is one rectangle.
      var start = -1;
      for (var col = 0; col <= count; col++) {
        final isDark = col < count && image.isDark(row, col);
        if (isDark && start < 0) start = col;
        if (!isDark && start >= 0) {
          canvas.drawRect(
            Rect.fromLTWH(
              origin.dx + start * module,
              origin.dy + row * module,
              (col - start) * module,
              module,
            ),
            dark,
          );
          start = -1;
        }
      }
    }
  }

  @override
  bool shouldRepaint(PartyQrPainter old) => !identical(old.image, image);
}

/// [data] as a QR code [size] logical pixels square, named for screen readers by [label].
class PartyQr extends StatefulWidget {
  const PartyQr(this.data, {super.key, required this.size, this.label});

  final String data;
  final double size;
  final String? label;

  @override
  State<PartyQr> createState() => _PartyQrState();
}

class _PartyQrState extends State<PartyQr> {
  late QrImage _image = partyQrImage(widget.data);

  @override
  void didUpdateWidget(PartyQr old) {
    super.didUpdateWidget(old);
    if (old.data != widget.data) _image = partyQrImage(widget.data);
  }

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: widget.label,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: PartyQrPainter(_image),
      ),
    ),
  );
}
