import 'package:shared_preferences/shared_preferences.dart';

class UserPrefs {
  static const String _isRegisteredKey = 'is_registered';
  static const String _ageKey = 'user_age';
  static const String _weightKey = 'user_weight';
  static const String _genderKey = 'user_gender';

  // Save profile and mark as registered
  static Future<void> saveProfile(int age, int weight, String gender) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_isRegisteredKey, true);
    await prefs.setInt(_ageKey, age);
    await prefs.setInt(_weightKey, weight);
    await prefs.setString(_genderKey, gender);
  }

  // Check if setup is complete
  static Future<bool> isSetupComplete() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_isRegisteredKey) ?? false;
  }

  // Retrieve data for the "Change Profile" feature
  static Future<Map<String, dynamic>> getProfile() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'age': prefs.getInt(_ageKey) ?? 20,
      'weight': prefs.getInt(_weightKey) ?? 35,
      'gender': prefs.getString(_genderKey) ?? 'Male',
    };
  }
}