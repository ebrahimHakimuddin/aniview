import 'package:aniview/feedback.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a refused ticket says which field the hub objected to', () {
    const invalid = '{"error":"invalid","fields":{"title":["Enter a title"]}}';
    expect(sendProblem(400, invalid), 'Enter a title');
    expect(sendProblem(400, 'not json'), contains('error (400)'));
    expect(sendProblem(429, ''), contains('Try again in a minute'));
  });

  test('each problem in a refused ticket is matched to its field', () {
    const invalid =
        '{"error":"invalid","fields":{"title":["Enter a title"],"reporterEmail":["Enter a valid email"]}}';
    expect(fieldProblems(400, invalid), {
      'title': 'Enter a title',
      'reporterEmail': 'Enter a valid email',
    });
    expect(fieldProblems(400, 'not json'), isEmpty);
    expect(fieldProblems(429, invalid), isEmpty);
  });
}
