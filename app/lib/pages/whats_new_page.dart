import 'package:flutter/material.dart';
import 'package:localsend_app/config/brand.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/changelog_page.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';

class WhatsNewPage extends StatelessWidget {
  final String version;

  const WhatsNewPage({
    super.key,
    required this.version,
  });

  static WhatsNewPage? fromLastVersion({required String? lastVersion}) {
    if (lastVersion == Brand.version) return null;
    return const WhatsNewPage(version: Brand.version);
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final strings = t.whatsNewPage.changes.v1_0_0;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.whatsNewPage.title(version: version)),
      ),
      body: ResponsiveListView(
        padding: const EdgeInsets.symmetric(horizontal: 15),
        children: [
          for (final change in strings.changes)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('- $change'),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () async {
                await context.global.dispatchAsync(NavigateAction.push(const ChangelogPage()));
              },
              icon: const Icon(Icons.history),
              label: Text(t.changelogPage.title),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: () => context.global.dispatch(NavigateAction.pop()),
              icon: Icon(Icons.done),
              label: Text(t.general.done),
            ),
          ),
        ],
      ),
    );
  }
}
