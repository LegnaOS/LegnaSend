import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:localsend_app/gen/assets.gen.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/ui/nav_bar_padding.dart';

enum ChangelogLanguage {
  english('English', Assets.changelog),
  simplifiedChinese('简体中文', Assets.changelogZh),
  traditionalChinese('繁體中文', Assets.changelogZhHant)
  ;

  final String label;
  final String asset;
  const ChangelogLanguage(this.label, this.asset);

  static ChangelogLanguage forLocale(AppLocale locale) {
    if (locale.languageCode != 'zh') return english;
    return locale == AppLocale.zhHk || locale == AppLocale.zhTw ? traditionalChinese : simplifiedChinese;
  }
}

String changelogAssetForLocale(AppLocale locale) => ChangelogLanguage.forLocale(locale).asset;

class ChangelogPage extends StatefulWidget {
  const ChangelogPage();

  @override
  State<ChangelogPage> createState() => _ChangelogPageState();
}

class _ChangelogPageState extends State<ChangelogPage> {
  ChangelogLanguage? _override;
  String? _asset;
  AssetBundle? _bundle;
  Future<String>? _content;

  void _load(String asset, AssetBundle bundle, {bool force = false}) {
    if (!force && asset == _asset && identical(bundle, _bundle)) return;
    _asset = asset;
    _bundle = bundle;
    // Cache per selection rather than starting disk I/O on every rebuild.
    _content = bundle.loadString(asset, cache: false);
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final locale = TranslationProvider.of(context).locale;
    final selected = _override ?? ChangelogLanguage.forLocale(locale);
    final bundle = DefaultAssetBundle.of(context);
    _load(selected.asset, bundle);
    final fallback = _override == null && locale.languageCode != 'en' && locale.languageCode != 'zh';
    return Scaffold(
      appBar: AppBar(title: Text(t.changelogPage.title)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: LayoutBuilder(
                  builder: (context, constraints) => Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    children: [
                      Text(t.changelogPage.language, style: Theme.of(context).textTheme.labelLarge),
                      SizedBox(
                        width: constraints.maxWidth.clamp(0, 250).toDouble(),
                        child: DropdownButton<int>(
                          isExpanded: true,
                          key: const ValueKey('changelog-language'),
                          value: _override == null ? -1 : _override!.index,
                          underline: const SizedBox.shrink(),
                          borderRadius: BorderRadius.circular(12),
                          items: [
                            DropdownMenuItem(value: -1, child: Text(t.changelogPage.followApp, maxLines: 1, overflow: TextOverflow.ellipsis)),
                            for (final language in ChangelogLanguage.values)
                              DropdownMenuItem(
                                value: language.index,
                                child: Text(language.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                              ),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            setState(() => _override = value == -1 ? null : ChangelogLanguage.values[value]);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (fallback)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(t.changelogPage.fallback(language: selected.label), style: Theme.of(context).textTheme.bodySmall),
                ),
              const Divider(height: 1),
              Expanded(
                child: FutureBuilder<String>(
                  key: ValueKey((_asset, _content)),
                  future: _content,
                  builder: (context, data) {
                    if (data.hasError) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(t.changelogPage.loadError, textAlign: TextAlign.center),
                              const SizedBox(height: 12),
                              TextButton.icon(
                                onPressed: () => setState(() => _load(selected.asset, bundle, force: true)),
                                icon: const Icon(Icons.refresh),
                                label: Text(t.changelogPage.retry),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    if (!data.hasData) return const Center(child: CircularProgressIndicator());
                    return Markdown(
                      key: ValueKey(_asset),
                      padding: EdgeInsets.only(left: 16, right: 16, top: 12, bottom: 16 + getNavBarPadding(context)),
                      data: data.data!,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
