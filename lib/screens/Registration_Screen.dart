import 'package:flutter/material.dart';
import 'package:isleep/main.dart'; 
import 'package:shared_preferences/shared_preferences.dart';

class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final TextEditingController _nameController = TextEditingController();
  
  String selectedGender = "Male";
  int age = 20;
  int weight = 60;
  int height = 170; // Added height initial state

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _saveProfileAndStart() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setBool('isRegistered', true);
    await prefs.setString('userName', _nameController.text.isEmpty ? "User" : _nameController.text);
    await prefs.setInt('userAge', age);
    await prefs.setInt('userWeight', weight);
    await prefs.setInt('userHeight', height); // Saving height
    await prefs.setString('userGender', selectedGender);

    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const MainNavigation()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF3F3B76),
      body: SafeArea(
        child: SingleChildScrollView( 
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 30),
            child: Column(
              children: [
                const SizedBox(height: 40),
                const Text("PROFILE SETUP",
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                const Text("Body Metrics",
                    style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
                const SizedBox(height: 30),

                _buildLabel("FULL NAME"),
                TextField(
                  controller: _nameController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: "Enter your name",
                    hintStyle: const TextStyle(color: Colors.white24),
                    filled: true,
                    fillColor: Colors.white10,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(15),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                  ),
                ),
                const SizedBox(height: 25),

                _buildLabel("GENDER"),
                _buildGenderToggle(),
                const SizedBox(height: 25),

                // ROW FOR AGE AND HEIGHT
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        children: [
                          _buildLabel("AGE"),
                          _buildAgeSelector(),
                        ],
                      ),
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: Column(
                        children: [
                          _buildLabel("HEIGHT (CM)"),
                          _buildHeightSelector(),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 25),

                _buildLabel("WEIGHT (KG)"),
                _buildWeightSelector(),

                const SizedBox(height: 40),

                ElevatedButton(
                  onPressed: _saveProfileAndStart, 
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF8E7CFF),
                    minimumSize: const Size(double.infinity, 60),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20)),
                  ),
                  child: const Text("Start i-Sleep",
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white)),
                ),
                const SizedBox(height: 15),
                const Text("Data is stored locally. No cloud sync used.",
                    style: TextStyle(color: Colors.white38, fontSize: 10)),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLabel(String text) => Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(text, style: const TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold)),
        ),
      );

  Widget _buildGenderToggle() {
    return Container(
      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(15)),
      child: Row(
        children: ["Male", "Female"]
            .map((g) => Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => selectedGender = g),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      decoration: BoxDecoration(
                        color: selectedGender == g
                            ? const Color(0xFF8E7CFF).withOpacity(0.6)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: Center(
                          child: Text(g,
                              style: const TextStyle(color: Colors.white))),
                    ),
                  ),
                ))
            .toList(),
      ),
    );
  }

  // Shared builder for Age and Height to keep UI consistent
  Widget _buildAgeSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          GestureDetector(onTap: () => setState(() => age--), child: const Icon(Icons.remove, color: Colors.white, size: 18)),
          Text("$age", style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
          GestureDetector(onTap: () => setState(() => age++), child: const Icon(Icons.add, color: Colors.white, size: 18)),
        ],
      ),
    );
  }

  Widget _buildHeightSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          GestureDetector(onTap: () => setState(() => height--), child: const Icon(Icons.remove, color: Colors.white, size: 18)),
          Text("$height", style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
          GestureDetector(onTap: () => setState(() => height++), child: const Icon(Icons.add, color: Colors.white, size: 18)),
        ],
      ),
    );
  }

  Widget _buildWeightSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
              onPressed: () => setState(() => weight--),
              icon: const Icon(Icons.remove_circle_outline, color: Colors.white, size: 30)),
          Text("$weight", style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white)),
          IconButton(
              onPressed: () => setState(() => weight++),
              icon: const Icon(Icons.add_circle_outline, color: Colors.white, size: 30)),
        ],
      ),
    );
  }
}