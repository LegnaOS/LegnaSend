import 'dart:io';

import 'package:localsend_app/config/brand.dart';
import 'package:localsend_app/gen/assets.gen.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/changelog_page.dart';
import 'package:localsend_app/pages/whats_new_page.dart';
import 'package:test/test.dart';

void main() {
  test('fork identity and every locale use LegnaSend', () async {
    expect(Brand.author, 'Legna');
    expect(Brand.version, '1.0.0');
    for (final locale in AppLocale.values) {
      final translations = await locale.build();
      expect(translations.aboutPage.title, contains(Brand.name), reason: locale.languageTag);
      expect(translations.aboutPage.description.first, contains(Brand.name));
      expect(translations.whatsNewPage.changes.v1_0_0.changes, isNotEmpty);
    }
  });
  test('fork navigation and donation removal are guarded in shipped entry points', () {
    expect(Brand.homepage, 'https://x.legna.cn/ls');
    expect(Brand.repositoryUrl, 'https://github.com/LegnaOS/LegnaSend');
    expect(File('pubspec.yaml').readAsStringSync(), contains('homepage: ${Brand.homepage}'));
    final installer = File('../support/scripts/compile_windows_exe-inno.iss').readAsStringSync();
    expect(installer, contains('#define MyAppURL "${Brand.homepage}"'));
    expect(installer, contains('AppUpdatesURL={#MyAppURL}'));
    expect(installer, contains('https://github.com/LegnaOS/LegnaSend/issues'));
    expect(File('../README.md').readAsStringSync(), contains(Brand.homepage));
    expect(Brand.repository, 'LegnaOS/LegnaSend');
    final about = File('lib/pages/about/about_page.dart').readAsStringSync();
    expect(about, contains('Uri.parse(Brand.homepage)'));
    expect(about, isNot(contains('https://github.com/localsend/localsend')));
    expect(about, contains('LocalSend · Copyright'));
    final settings = File('lib/pages/tabs/settings_tab.dart').readAsStringSync();
    expect(settings, isNot(contains('DonationPage')));
    expect(settings, isNot(contains('other.donate')));
    final donation = File('lib/pages/donation/donation_page.dart').readAsStringSync();
    expect(donation, isNot(contains('launchUrl')));
    expect(donation, isNot(contains('FetchPricesAndPurchasesAction')));
    expect(File('lib/config/init.dart').readAsStringSync(), isNot(contains('InitPurchaseStream')));
    expect(File('../.github/FUNDING.yml').existsSync(), false);
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.dart'))) {
      final content = file.readAsStringSync();
      expect(content, isNot(contains('github.com/sponsors/Tienisto')), reason: file.path);
      expect(content, isNot(contains('ko-fi.com/tienisto')), reason: file.path);
    }
  });
  test('removed donation feature does not register a native store SDK', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(RegExp(r'^\s+in_app_purchase\s*:', multiLine: true).hasMatch(pubspec), isFalse);
    expect(File('../pubspec.lock').readAsStringSync(), isNot(contains('in_app_purchase_storekit:')));
    expect(File('macos/Flutter/GeneratedPluginRegistrant.swift').readAsStringSync(), isNot(contains('in_app_purchase_storekit')));
    for (final platform in ['ios', 'macos']) {
      expect(File('$platform/Podfile.lock').readAsStringSync(), isNot(contains('in_app_purchase_storekit')));
    }
  });
  test('donation removal keeps paired FOSS markers and strips all remaining purchase imports', () {
    for (final path in ['lib/config/init.dart', 'lib/pages/donation/donation_page.dart', 'lib/pages/donation/donation_page_vm.dart']) {
      final source = File(path).readAsStringSync();
      expect(RegExp(r'\[FOSS_REMOVE_START\]').allMatches(source).length, RegExp(r'\[FOSS_REMOVE_END\]').allMatches(source).length, reason: path);
      final stripped = source.replaceAll(RegExp(r'// \[FOSS_REMOVE_START\][\s\S]*?// \[FOSS_REMOVE_END\]'), '');
      expect(stripped, isNot(contains("import 'package:localsend_app/provider/purchase_provider.dart'")), reason: path);
    }
  });
  test('fork release notes replace the upstream version prompt exactly once', () {
    expect(WhatsNewPage.fromLastVersion(lastVersion: null)?.version, Brand.version);
    expect(WhatsNewPage.fromLastVersion(lastVersion: '1.18.2')?.version, Brand.version);
    expect(WhatsNewPage.fromLastVersion(lastVersion: Brand.version), isNull);
  });
  test('app and distribution versions stay aligned', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('version: ${Brand.version}+1'));
    for (final path in [
      '../cli/Cargo.toml',
      '../support/scripts/compile_windows_exe-inno.iss',
      '../support/build/appimage/AppImageBuilder_arm_64.yml',
      '../support/build/appimage/AppImageBuilder_x86_64.yml',
    ]) {
      expect(File(path).readAsStringSync(), contains(Brand.version));
      expect(File(path).readAsStringSync(), isNot(contains('1.18.2')));
    }
    expect(File('../support/build/msix/content/AppxManifest.xml').readAsStringSync(), contains('Version="${Brand.version}.0"'));
  });
  test('changelog language routing covers every supported locale', () {
    for (final locale in AppLocale.values) {
      final expected = locale == AppLocale.zhTw || locale == AppLocale.zhHk
          ? Assets.changelogZhHant
          : locale.languageCode == 'zh'
          ? Assets.changelogZh
          : Assets.changelog;
      expect(changelogAssetForLocale(locale), expected);
    }
  });
  test('release notes stay concise and contain user changes rather than development evidence', () async {
    final internalDetail = RegExp(
      r'docs[/\\]|(?:^|[/\\])support[/\\]|\bbatch[-_]?\d+\b|\b(?:cargo|fvm|flutter_rust_bridge|FRB|TODO)\b|'
      r'\b(?:unit|integration|smoke) tests?\b|核心[证證][据據]|真[实實]回[环環]|[测測][试試](?:套件|通[过過]|[结結]果|流程)',
      caseSensitive: false,
      multiLine: true,
    );
    for (final asset in [Assets.changelog, Assets.changelogZh, Assets.changelogZhHant]) {
      expect(internalDetail.hasMatch(File(asset).readAsStringSync()), false, reason: asset);
    }
    for (final locale in AppLocale.values) {
      final translations = await locale.build();
      final releaseNotes = translations.whatsNewPage.changes.v1_0_0.changes;
      expect(releaseNotes.length, inInclusiveRange(1, 12), reason: locale.languageTag);
      for (final note in releaseNotes) {
        expect(internalDetail.hasMatch(note), false, reason: '${locale.languageTag}: $note');
        expect(note.length, lessThanOrEqualTo(350), reason: locale.languageTag);
      }
    }
  });
  test('bundled changelog contains fork changes, upstream history is archived', () {
    final changelog = File('assets/CHANGELOG.md').readAsStringSync();
    expect(changelog, contains('## ${Brand.version}'));
    expect(changelog, contains('Author: ${Brand.author}'));
    expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(changelog), isFalse);
    final chinese = File('assets/CHANGELOG_ZH.md').readAsStringSync();
    final traditional = File(Assets.changelogZhHant).readAsStringSync();
    expect(traditional, startsWith('# LegnaSend 更新日誌'));
    expect(traditional, contains('目錄工作區'));
    expect(RegExp(r'^##? .*', multiLine: true).allMatches(traditional).length, RegExp(r'^##? .*', multiLine: true).allMatches(chinese).length);
    expect(traditional.split('\n').where((line) => line.startsWith('- ')).length, chinese.split('\n').where((line) => line.startsWith('- ')).length);
    expect(chinese, contains('作者：${Brand.author}'));
    expect(chinese, contains('## ${Brand.version}'));
    expect(chinese, isNot(contains(' / Added')));
    expect(chinese, isNot(contains('## 1.18.')));
    expect(changelog, isNot(contains('## 1.18.')));
    expect(File('../docs/upstream/LOCALSEND_CHANGELOG.md').readAsStringSync(), contains('## 1.18.2'));
  });
}
