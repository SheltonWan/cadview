import 'package:flutter_test/flutter_test.dart';
import 'package:prop_os_cad/main.dart';

void main() {
  testWidgets('App launches smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const PropOsCadApp());
    expect(find.byType(PropOsCadApp), findsOneWidget);
  });
}
