import 'package:flutter_test/flutter_test.dart';
import 'package:the_guardian/main.dart';

void main() {
  testWidgets('App boots test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const TheGuardianApp());
  });
}
