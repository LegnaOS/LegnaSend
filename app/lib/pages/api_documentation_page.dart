import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_app/widget/status_tag.dart';
import 'package:url_launcher/url_launcher.dart';

/// Shipped, offline developer documentation. Opening it never enables the API.
class ApiDocumentationPage extends StatefulWidget {
  const ApiDocumentationPage({super.key});
  @override
  State<ApiDocumentationPage> createState() => _ApiDocumentationPageState();
}

class _ApiDocumentationPageState extends State<ApiDocumentationPage> {
  bool? _chinese;
  String _document = 'INTEGRATION_API';
  String? _asset;
  Future<String>? _content;

  Future<void> _link(String label, String? href, String title) async {
    if (href == null) return;
    final name = Uri.tryParse(href)?.path.split('/').last;
    final guide = [
      'INTEGRATION_API',
      'DIRECTORY_API',
      'API_RECEIVE_RETENTION',
      'NATIVE_DURABLE_RESUME',
      'NATIVE_RESUME_PROTOCOL',
      'SOURCE_END_CLEANUP_RECEIPTS',
    ].where((guide) => name == '$guide.md' || name == '${guide}_ZH.md').firstOrNull;
    if (guide != null) {
      setState(() {
        _chinese = name!.contains('_ZH');
        _document = guide;
      });
      return;
    }
    if (name != null && RegExp(r'^integration-openapi-(en|zh-CN|zh-TW|zh-HK)\.json$').hasMatch(name)) {
      setState(() => _document = name);
      return;
    }
    final uri = Uri.tryParse(href);
    if (uri?.scheme == 'https' || uri?.scheme == 'http') {
      try {
        await launchUrl(uri!, mode: LaunchMode.externalApplication);
      } catch (_) {
        if (mounted) context.showSnackBar(t.general.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = Translations.of(context).integrationApi;
    final chinese = _chinese ?? TranslationProvider.of(context).locale.languageCode == 'zh';
    final json = _document.endsWith('.json');
    final asset = 'assets/api_docs/${json ? _document : '$_document${chinese ? '_ZH' : ''}.md'}';
    if (_asset != asset) {
      _asset = asset;
      _content = DefaultAssetBundle.of(context).loadString(asset, cache: false);
    }
    return Scaffold(
      appBar: AppBar(title: Text(strings.documentation)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    StatusTag(
                      label: 'English',
                      onTap: () => setState(() {
                        _chinese = false;
                        _document = 'INTEGRATION_API';
                      }),
                    ),
                    StatusTag(
                      label: '简体中文',
                      onTap: () => setState(() {
                        _chinese = true;
                        _document = 'INTEGRATION_API';
                      }),
                    ),
                    StatusTag(label: strings.documentation, onTap: () => setState(() => _document = 'INTEGRATION_API')),
                    StatusTag(label: strings.directoryContract, onTap: () => setState(() => _document = 'DIRECTORY_API')),
                    StatusTag(label: chinese ? '接收保留策略' : 'Receive retention', onTap: () => setState(() => _document = 'API_RECEIVE_RETENTION')),
                    StatusTag(label: chinese ? '原生续传协议' : 'Native recovery', onTap: () => setState(() => _document = 'NATIVE_DURABLE_RESUME')),
                    StatusTag(label: chinese ? '清理回执' : 'Cleanup receipts', onTap: () => setState(() => _document = 'SOURCE_END_CLEANUP_RECEIPTS')),
                    StatusTag(label: 'OpenAPI 3.1', onTap: () => setState(() => _document = 'integration-openapi-${chinese ? 'zh-CN' : 'en'}.json')),
                    StatusTag(
                      label: json
                          ? _document
                          : chinese
                          ? '简体中文'
                          : 'English',
                      icon: Icons.offline_bolt_outlined,
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: FutureBuilder<String>(
                  key: ValueKey(asset),
                  future: _content,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Center(
                        child: TextButton.icon(
                          onPressed: () => setState(() => _asset = null),
                          icon: const Icon(Icons.refresh),
                          label: Text(t.changelogPage.retry),
                        ),
                      );
                    }
                    if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                    if (json) {
                      // Render lazily by line rather than creating one huge selectable paragraph.
                      final lines = snapshot.data!.split('\n');
                      return Column(
                        children: [
                          TextButton.icon(
                            onPressed: () async {
                              try {
                                await Clipboard.setData(ClipboardData(text: snapshot.data!));
                                if (context.mounted) context.showSnackBar(strings.copied);
                              } catch (_) {
                                if (context.mounted) context.showSnackBar(strings.copyFailed);
                              }
                            },
                            icon: const Icon(Icons.copy),
                            label: Text(strings.copy),
                          ),
                          Expanded(
                            child: ListView.builder(
                              key: ValueKey(asset),
                              padding: const EdgeInsets.all(16),
                              itemCount: lines.length,
                              itemBuilder: (context, index) =>
                                  SelectableText(lines[index], style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                            ),
                          ),
                        ],
                      );
                    }
                    return Markdown(
                      key: ValueKey(asset),
                      selectable: true,
                      data: snapshot.data!,
                      onTapLink: _link,
                      padding: const EdgeInsets.all(16),
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
