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

    // Be tolerant of small label changes (e.g. extra suffixes like "for Status").
    expect(
      find.byWidgetPredicate(
        (w) {
          if (w is Text) {
            final s = (w.data ?? '').toLowerCase();
            return s.contains('trim') && s.contains('split');
          }
          if (w is RichText) {
            final txt = w.text.toPlainText().toLowerCase();
            return txt.contains('trim') && txt.contains('split');
          }
          return false;
        },
        description: 'Text widget containing "trim" and "split"',
      ),
      findsOneWidget,
    );

    expect(find.text('Theme mode'), findsNothing);
    expect(find.text('Navigation style'), findsNothing);
    expect(find.text('Appearance'), findsNothing);
    expect(find.text('AMOLED black'), findsNothing);
  });
}
