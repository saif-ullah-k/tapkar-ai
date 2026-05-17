import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/chat_screen.dart';
import 'state/app_state.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.bg,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const TapKarApp());
}

class TapKarApp extends StatefulWidget {
  const TapKarApp({super.key});

  @override
  State<TapKarApp> createState() => _TapKarAppState();
}

class _TapKarAppState extends State<TapKarApp> {
  final AppState _state = AppState();

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'TapKar AI',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: ChatScreen(state: _state),
      );
}
