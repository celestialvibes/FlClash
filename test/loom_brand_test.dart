import 'package:fl_clash/models/clash_config.dart';
import 'package:fl_clash/views/loom.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LOOM adblock is one GEOSITE reject rule', () {
    final rule = createLoomAdblockRule();

    expect(loomAccent.toARGB32(), 0xFFFF3300);
    expect(rule.rawValue, 'GEOSITE,category-ads-all,REJECT');
    expect(isLoomAdblockRule(rule), isTrue);
    expect(isLoomAdblockRule(Rule.parse('GEOSITE,private,DIRECT')), isFalse);
  });
}
