// 검토 배너 문구: 사유와 안내를 점(·)으로 잇지 않고 두 문장으로(B3)
import 'package:challory/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('사유 + "72시간 안에…" 는 두 문장', () {
    final t = reviewBannerText(remote: true, review: const MyReview(id: 'r', type: 'source_unknown', status: 'open'));
    expect(t.spike, isFalse);
    expect('${t.lead}${t.rest}', isNot(contains(' · ')));
    expect(t.rest, '. 72시간 안에 설명을 남길 수 있어요.');
  });
}
