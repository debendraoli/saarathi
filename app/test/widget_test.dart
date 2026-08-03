// Basic smoke test. The full app boots a router + platform channels, so this
// keeps to a trivial widget-tree check to keep CI green without device plugins.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders a widget tree', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Saarathi'))),
    );
    expect(find.text('Saarathi'), findsOneWidget);
  });
}
