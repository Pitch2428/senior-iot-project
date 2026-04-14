import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart'; 
import 'package:isleep/screens/Welcome_Page.dart';
import 'package:isleep/screens/journal_screen.dart';
import 'package:isleep/screens/recording_screen.dart'; 
import 'package:isleep/screens/history_screen.dart';
import 'package:isleep/screens/settings_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  final prefs = await SharedPreferences.getInstance();
  bool isRegistered = prefs.getBool('isRegistered') ?? false;

  runApp(MyApp(startScreen: isRegistered ? const MainNavigation() : const WelcomePage()));
}

class MyApp extends StatelessWidget {
  final Widget startScreen;
  const MyApp({super.key, required this.startScreen});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'i-Sleep',
      theme: ThemeData(
        useMaterial3: true,
        primaryColor: const Color(0xFF3F3B76),
      ),
      home: startScreen, 
    );
  }
}

class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _currentIndex = 1; 
  String? _selectedDateFromHistory;
  // NEW: Holds the full session data to show in History Analysis
  Map<String, dynamic>? _selectedSessionForAnalysis;

  // Handles: History Chart Bar -> Jump to Journal
  void _handleHistoryTap(String dateLabel) {
    setState(() {
      _selectedDateFromHistory = dateLabel; 
      _currentIndex = 0; 
    });
  }

  // NEW Handles: Journal Card Click -> Jump to History Analysis
  void _handleJournalTap(Map<String, dynamic> session) {
    setState(() {
      _selectedSessionForAnalysis = session;
      _currentIndex = 2; // Index of HistoryScreen
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> _pages = [
      // Pass the tap handler to Journal
      JournalScreen(
        highlightDate: _selectedDateFromHistory,
        onSessionTap: _handleJournalTap, 
      ),   
      const BleHome(), 
      // Pass the selected session to History
      HistoryScreen(
        onBarTapped: _handleHistoryTap,
        initialSession: _selectedSessionForAnalysis,
      ), 
      const SettingsScreen(),
    ];

    return Scaffold(
      backgroundColor: const Color(0xFF3F3B76),
      body: IndexedStack( 
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        type: BottomNavigationBarType.fixed,
        backgroundColor: Colors.white,
        selectedItemColor: const Color(0xFF3F3B76),
        unselectedItemColor: Colors.grey,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
            // Clear temporary selections when navigating manually
            if (index != 0) _selectedDateFromHistory = null;
            if (index != 2) _selectedSessionForAnalysis = null;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.book_outlined), 
            activeIcon: Icon(Icons.book), 
            label: "Journal"
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.radio_button_checked_outlined), 
            activeIcon: Icon(Icons.radio_button_checked), 
            label: "Record"
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.bar_chart_outlined), 
            activeIcon: Icon(Icons.bar_chart), 
            label: "History"
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined), 
            activeIcon: Icon(Icons.settings), 
            label: "Settings"
          ),
        ],
      ),
    );
  }
}





