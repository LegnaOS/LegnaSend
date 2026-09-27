import 'package:flutter/material.dart';
import 'package:localsend_app/config/brand.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/model/persistence/color_mode.dart';
import 'package:localsend_app/util/ui/dynamic_colors.dart';
import 'package:test/test.dart';

void main() {
  test('brand has the exact requested color in both brightness modes', () {
    final dynamic = DynamicColors(
      light: ColorScheme.fromSeed(seedColor: Colors.purple),
      dark: ColorScheme.fromSeed(seedColor: Colors.purple, brightness: Brightness.dark),
    );
    for (final brightness in Brightness.values) {
      final theme = getTheme(ColorMode.localsend, Colors.blue, brightness, dynamic);
      expect(theme.colorScheme.primary, const Color(0xFF54B865));
      expect(theme.colorScheme.onPrimary, Brand.onGreen);
      final contrast = (Brand.green.computeLuminance() + 0.05) / (Brand.onGreen.computeLuminance() + 0.05);
      expect(contrast, greaterThanOrEqualTo(4.5));
    }
  });
  test('explicit custom palette is preserved', () {
    expect(getTheme(ColorMode.custom, Colors.purple, Brightness.light, null).colorScheme.primary, isNot(Brand.green));
  });
}
