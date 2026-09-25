import 'package:aniview/library.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('counts the days in a row with activity up to today or yesterday', () {
    final today = DateTime(2026, 3, 1, 15); // across a month end
    DateTime day(int back) => DateTime(2026, 3, 1 - back);
    expect(activityStreak({day(0), day(1), day(2), day(4)}, today), 3);
    expect(activityStreak({day(1), day(2)}, today), 2); // nothing yet today
    expect(activityStreak({day(2)}, today), 0);
    expect(activityStreak({}, today), 0);
  });
}
