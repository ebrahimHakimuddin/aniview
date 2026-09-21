import 'package:aniview/pairing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('phone and TV derive the same code and key, and only that key opens the token', () {
    final phone = PairKeys(), tv = PairKeys();
    final a = phone.agree(tv.publicKey), b = tv.agree(phone.publicKey);
    expect(a.code, b.code);
    expect(a.code, matches(RegExp(r'^\d{3} \d{3}$')));
    expect(unseal(b.key, seal(a.key, 'token')), 'token');

    // A device in the middle ends up with a different code and can't open it.
    final middle = PairKeys();
    final spoofed = phone.agree(middle.publicKey);
    expect(spoofed.code, isNot(b.code));
    expect(() => unseal(b.key, seal(spoofed.key, 'token')), throwsA(anything));
  });
}
