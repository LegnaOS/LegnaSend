import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/util/api/api_history_export.dart';

class ApiHistoryExportButton extends StatefulWidget {
  final String language;
  final bool enabled;
  final Future<ApiHistorySnapshot> Function() load;
  final ValueChanged<bool> onBusy;
  final Future<String?> Function(Uint8List bytes, String fileName)? save;
  const ApiHistoryExportButton({super.key, required this.language, required this.enabled, required this.load, required this.onBusy, this.save});
  @override
  State<ApiHistoryExportButton> createState() => _ApiHistoryExportButtonState();
}

class _ApiHistoryExportButtonState extends State<ApiHistoryExportButton> {
  bool _busy = false;
  String copy(String en, String cn, String tw) => !widget.language.startsWith('zh')
      ? en
      : widget.language.contains('TW') || widget.language.contains('HK')
      ? tw
      : cn;
  Future<void> run() async {
    if (_busy || !widget.enabled) return;
    setState(() => _busy = true);
    widget.onBusy(true);
    try {
      final snapshot = await widget.load();
      if (!mounted) return;
      final format = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const ValueKey('api-history-export-confirm'),
          title: Text(copy('Export redacted request history', '导出脱敏请求记录', '匯出已脫敏請求記錄')),
          content: Text(
            '${snapshot.entries.length} ${copy('records · JSON or CSV. Credentials, paths and request/response bodies are excluded.', '条记录 · JSON 或 CSV。不包含凭据、路径及请求／响应正文。', '筆記錄 · JSON 或 CSV。不包含憑據、路徑及請求／回應內容。')}\n${snapshot.incomplete ? copy('Some records were replaced while reading; the export is marked incomplete.', '读取时部分记录已被替换，导出文件会标记不完整。', '讀取時部分記錄已被替換，匯出檔案會標記不完整。') : ''}',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(copy('Cancel', '取消', '取消'))),
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('JSON')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('CSV')),
          ],
        ),
      );
      if (format == null || !mounted) return;
      final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[^0-9TZ]'), '');
      final name = 'legnasend-api-history-$timestamp.${format ? 'csv' : 'json'}';
      final bytes = snapshot.encode(csv: format);
      final result = await (widget.save ?? (bytes, name) => FilePicker.saveFile(fileName: name, bytes: bytes))(bytes, name);
      if (mounted && result != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(copy('History saved', '记录已保存', '記錄已儲存'))));
    } catch (_) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(copy('Export failed', '导出失败', '匯出失敗')),
            content: Text(
              copy(
                'Check service access and the selected save destination. No success is reported for an incomplete save.',
                '请检查服务访问权限及保存位置，保存失败不会提示成功。',
                '請檢查服務存取權限及儲存位置，儲存失敗不會提示成功。',
              ),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(copy('Close', '关闭', '關閉')))],
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        widget.onBusy(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('api-history-export'),
    onPressed: widget.enabled && !_busy ? run : null,
    tooltip: copy('Export request history', '导出请求记录', '匯出請求記錄'),
    icon: _busy
        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, value: 0.5))
        : const Icon(Icons.download_outlined),
  );
}
