import 'package:flutter/material.dart';
import 'registration_screen.dart';

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

// Theme
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF3F3B76), 
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 30),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),

              // Moon Icon
              Container(
                height: 150,
                width: 150,
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                child: const Icon(Icons.nightlight_round, size: 80, color: Color(0xFF3F3B76)),
              ),
              const SizedBox(height: 40),
              const Text("Welcome to i-Sleep", style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 10),
              const Text("Your Personal Sleep & Activity Monitor", style: TextStyle(fontSize: 16, color: Colors.white70)),
              const SizedBox(height: 20),
              const Text(
                "Track your sleep quality and daily activities with advanced IMU and heart rate monitoring powered by M5StickC",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const Spacer(),
              
              // Continue Button
              ElevatedButton(
                onPressed: () {
                   Navigator.push(
                   context,
                   MaterialPageRoute(builder: (context) => const RegistrationScreen()),
                  );
                 }, 
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF8E7CFF),
                  minimumSize: const Size(double.infinity, 60),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text("Continue", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                    SizedBox(width: 10),
                    Icon(Icons.arrow_forward_ios, size: 18, color: Colors.white),
                  ],
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );  
  }
}