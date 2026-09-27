import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:url_launcher/url_launcher.dart';

enum PrivacyPolicyLanguage {
  english('English', 'assets/privacy/PRIVACY.md'),
  simplifiedChinese('简体中文', 'assets/privacy/PRIVACY_ZH.md'),
  traditionalChinese('繁體中文', 'assets/privacy/PRIVACY_ZH_HANT.md')
  ;

  final String label;
  final String asset;
  const PrivacyPolicyLanguage(this.label, this.asset);

  static PrivacyPolicyLanguage forLocale(AppLocale locale) {
    if (locale.languageCode != 'zh') return english;
    return locale == AppLocale.zhHk || locale == AppLocale.zhTw ? traditionalChinese : simplifiedChinese;
  }
}

/// Reading policy text does not start networking or request system permissions.
class PrivacyPolicyPage extends StatefulWidget {
  const PrivacyPolicyPage({super.key});

  @override
  State<PrivacyPolicyPage> createState() => _PrivacyPolicyPageState();
}

class _PrivacyPolicyPageState extends State<PrivacyPolicyPage> {
  PrivacyPolicyLanguage? _selected;
  AssetBundle? _bundle;
  String? _asset;
  Future<String>? _content;

  void _load(AssetBundle bundle, String asset, {bool force = false}) {
    if (!force && identical(bundle, _bundle) && asset == _asset) return;
    _bundle = bundle;
    _asset = asset;
    _content = bundle.loadString(asset, cache: false);
  }

  Future<void> _openLink(String? href) async {
    final uri = href == null ? null : Uri.tryParse(href);
    if (uri == null || uri.scheme != 'https' || uri.host != 'github.com' || uri.userInfo.isNotEmpty) return;
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) throw StateError('link');
    } catch (_) {
      if (mounted) context.showSnackBar(Translations.of(context).general.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = Translations.of(context);
    final locale = TranslationProvider.of(context).locale;
    final selected = _selected ?? PrivacyPolicyLanguage.forLocale(locale);
    final bundle = DefaultAssetBundle.of(context);
    _load(bundle, selected.asset);
    return Scaffold(
      appBar: AppBar(title: Text(strings.settingsTab.other.privacyPolicy)),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: DropdownButton<int>(
                    isExpanded: true,
                    value: _selected == null ? -1 : _selected!.index,
                    items: [
                      DropdownMenuItem(value: -1, child: Text('${strings.changelogPage.followApp} · ${selected.label}')),
                      for (final language in PrivacyPolicyLanguage.values) DropdownMenuItem(value: language.index, child: Text(language.label)),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _selected = value == -1 ? null : PrivacyPolicyLanguage.values[value]);
                    },
                  ),
                ),
                if (_selected == null && locale.languageCode != 'en' && locale.languageCode != 'zh')
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(strings.changelogPage.fallback(language: selected.label)),
                  ),
                const Divider(height: 1),
                Expanded(
                  child: FutureBuilder<String>(
                    key: ValueKey((_asset, _content)),
                    future: _content,
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(strings.general.error),
                              TextButton.icon(
                                onPressed: () => setState(() => _load(bundle, selected.asset, force: true)),
                                icon: const Icon(Icons.refresh),
                                label: Text(strings.changelogPage.retry),
                              ),
                            ],
                          ),
                        );
                      }
                      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                      return Markdown(
                        key: ValueKey(selected.asset),
                        data: snapshot.data!,
                        selectable: true,
                        padding: const EdgeInsets.all(16),
                        imageBuilder: (_, _, alt) => Text(alt ?? ''),
                        onTapLink: (_, href, _) => _openLink(href),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
