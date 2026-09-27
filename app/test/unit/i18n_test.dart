import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/i18n.dart';
import 'package:test/test.dart';

void main() {
  group('i18n', () {
    test('Every generated locale has a display name', () {
      for (final locale in AppLocale.values) {
        expect(locale.getLocaleName(), isNotEmpty);
      }
      expect(AppLocale.ky.getLocaleName(), 'Кыргызча');
    });

    test('Should compile', () {
      // The following test will fail if the i18n file is either not compiled
      // or there are compile-time errors.
      expect(AppLocale.en.translations.general.accept, 'Accept');
    });

    test('All locales should be supported by Flutter', () {
      for (final locale in AppLocale.values) {
        expect(kMaterialSupportedLanguages, contains(locale.languageCode));
      }
    });
  });
}
