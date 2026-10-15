import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:statushd/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Status HD opens with the studio and navigation', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(StatusHdApp(preferences: preferences));
    await tester.pumpAndSettle();

    expect(find.text('STATUS HD'), findsOneWidget);
    expect(find.text('Make your status\nlook its best.'), findsOneWidget);
    expect(find.text('Studio'), findsOneWidget);
    expect(find.text('Tools'), findsOneWidget);
    expect(find.text('Settings'), findsNothing);
    expect(find.byTooltip('Open movie player'), findsOneWidget);
    expect(find.text('Movie Player'), findsOneWidget);

    await tester.tap(find.text('Tools'));
    await tester.pumpAndSettle();
    expect(find.text('Studio tools'), findsOneWidget);
    expect(find.text('Movie Player'), findsOneWidget);
    expect(find.text('Quality studio'), findsOneWidget);

    // The trim/split card is lower in the scrollable tools list and may not
    // be mounted until it is brought into view.
    final trimSplit = find.text('Trim & split');
    await tester.scrollUntilVisible(trimSplit, 300);
    expect(trimSplit, findsOneWidget);

    expect(find.text('Theme mode'), findsNothing);
    expect(find.text('Navigation style'), findsNothing);
    expect(find.text('Appearance'), findsNothing);
    expect(find.text('AMOLED black'), findsNothing);
  });
}
