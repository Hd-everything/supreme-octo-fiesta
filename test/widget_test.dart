import 'package:flutter_test/flutter_test.dart';
import 'package:statushd/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Vyntra opens the redesigned project studio', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(VyntraApp(preferences: preferences));
    await tester.pumpAndSettle();

    expect(find.text('VYNTRA'), findsOneWidget);
    expect(find.text('Make something\nworth watching.'), findsOneWidget);
    expect(find.text('Your projects'), findsOneWidget);
    expect(find.text('Create new project'), findsOneWidget);
    expect(find.text('Your timeline is waiting'), findsOneWidget);
    expect(find.text('Appearance'), findsNothing);
    expect(find.text('Navigation style'), findsNothing);
  });
}
