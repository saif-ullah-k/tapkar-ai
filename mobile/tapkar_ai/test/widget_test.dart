// Smoke test — verifies TapKarApp boots without exceptions.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tapkar_ai/main.dart';

void main() {
  testWidgets('App boots without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const TapKarApp());
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
