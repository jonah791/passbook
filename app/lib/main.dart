import 'package:flutter/material.dart';

import 'core/vault_controller.dart';
import 'pages/home_page.dart';

/// 全局唯一的库控制器（这个应用只开一个库）。
final vault = VaultController();

void main() {
  runApp(const PassbookApp());
}

class PassbookApp extends StatelessWidget {
  const PassbookApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Passbook',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D6F)),
        useMaterial3: true,
      ),
      home: HomePage(vault: vault),
    );
  }
}
