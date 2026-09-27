import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/source_end_provider.dart';
import 'package:localsend_app/util/source_end_strings.dart';
import 'package:localsend_isolates/util/file_size_helper.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

class SourceEndPage extends StatefulWidget {
  const SourceEndPage({super.key});
  @override
  State<SourceEndPage> createState() => _SourceEndPageState();
}

class _SourceEndPageState extends State<SourceEndPage> {
  final _busy = <String>{};

  Future<void> _showReceipt(Map<String, Object?> row, SourceEndStrings labels) => showDialog<void>(
    context: context,
    builder: (context) {
      final cleanup = row['cleanup'] as Map<String, Object?>?;
      return AlertDialog(
        title: Text(labels.receiptTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${row['name']} · ${row['peerLabel']}'),
              const SizedBox(height: 8),
              Text(labels.state(row['state']! as String)),
              const SizedBox(height: 16),
              if (cleanup == null)
                Text(labels.noReceipt)
              else ...[
                Text(labels.removedFiles(cleanup['removedFiles']! as int)),
                const SizedBox(height: 8),
                Text(labels.logicalBytes(cleanup['unlinkedBytes']! as int, (cleanup['unlinkedBytes']! as int).asReadableFileSize)),
                const SizedBox(height: 12),
                Text(labels.logicalBytesDetail),
                const SizedBox(height: 16),
                Text(labels.receiptId, style: Theme.of(context).textTheme.labelMedium),
                SelectableText(cleanup['receiptId']! as String),
              ],
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(MaterialLocalizations.of(context).closeButtonLabel))],
      );
    },
  );
  @override
  Widget build(BuildContext context) {
    final rows = context.watch(sourceEndProvider);
    final controller = context.notifier(sourceEndProvider);
    final labels = SourceEndStrings(LocaleSettings.currentLocale.languageTag);
    return Scaffold(
      appBar: AppBar(title: Text(labels.title)),
      body: Column(
        children: [
          ExpansionTile(
            title: Text(labels.help),
            children: [Padding(padding: const EdgeInsets.all(16), child: Text(labels.detail))],
          ),
          if (controller.capacityLimited) Padding(padding: const EdgeInsets.all(16), child: Text(labels.capacity)),
          Expanded(
            child: !controller.available || !controller.storageHealthy
                ? Center(
                    child: Padding(padding: const EdgeInsets.all(16), child: Text(labels.unavailable)),
                  )
                : rows.isEmpty
                ? Center(child: Text(labels.empty))
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      final id = row['id']! as String;
                      final state = row['state']! as String;
                      final cleanup = row['cleanup'] as Map<String, Object?>?;
                      return ListTile(
                        onTap: () => _showReceipt(row, labels),
                        trailing: const Icon(Icons.chevron_right),
                        title: Text('${row['name']} · ${row['peerLabel']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(labels.state(state)),
                            if (cleanup != null)
                              Text(labels.cleanupSummary(cleanup['removedFiles']! as int, (cleanup['unlinkedBytes']! as int).asReadableFileSize)),
                            if (labels.retryable(state))
                              TextButton(
                                onPressed: _busy.contains(id)
                                    ? null
                                    : () async {
                                        setState(() => _busy.add(id));
                                        try {
                                          await controller.retry(id, row['version']! as String, const Uuid().v4());
                                        } catch (_) {
                                          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.general.error)));
                                        } finally {
                                          if (mounted) setState(() => _busy.remove(id));
                                        }
                                      },
                                child: Text(labels.retry),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
