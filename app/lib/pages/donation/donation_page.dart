import 'package:flutter/material.dart';
import 'package:localsend_app/pages/about/about_page.dart';

// [FOSS_REMOVE_START]
// No purchase imports or callbacks: retained markers support the FOSS script.
// [FOSS_REMOVE_END]

/// Legacy internal destination, retained for downstream route compatibility.
/// LegnaSend has no donation URL, store checkout or donation navigation entry.
class DonationPage extends StatelessWidget {
  const DonationPage({super.key});

  @override
  Widget build(BuildContext context) {
    // [FOSS_REMOVE_START]
    // Intentionally no upstream purchase query or restore side effect.
    // [FOSS_REMOVE_END]
    return const AboutPage();
  }
}
