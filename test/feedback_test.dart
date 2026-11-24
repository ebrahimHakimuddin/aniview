import 'package:aniview/feedback.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a refused ticket says which field the hub objected to', () {
    const invalid = '{"error":"invalid","fields":{"title":["Enter a title"]}}';
    expect(sendProblem(400, invalid), 'Enter a title');
    expect(sendProblem(400, 'not json'), contains('error (400)'));
    expect(sendProblem(429, ''), contains('Try again in a minute'));
  });

  test('the hub\'s triage is laid over what was sent, matched by token', () {
    final sent = [
      {'id': 1, 'token': 'a', 'type': 'bug', 'title': 'One', 'status': 'new'},
      {'id': 2, 'token': 'b', 'type': 'feature', 'title': 'Two'},
    ];
    final merged = withTriage(sent, [
      {'token': 'b', 'status': 'released', 'releasedIn': '2.8.0'},
    ]);
    expect(merged[0]['status'], 'new');
    expect(merged[1]['status'], 'released');
    expect(merged[1]['title'], 'Two');
    expect(triageLabel(merged[1]), 'Added in version 2.8.0');
    final duplicate = {...merged[0], 'status': 'duplicate', 'duplicateOfId': 7};
    expect(triageLabel(duplicate), 'Already reported, as #7');
  });
}
