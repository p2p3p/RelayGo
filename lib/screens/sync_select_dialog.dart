import 'package:flutter/material.dart';
import 'package:relaygo/app.dart';
import 'package:relaygo/l10n/app_strings.dart';
import 'package:relaygo/models/provider_config.dart';

/// 同步提供商选择对话框（需求 3）
///
/// 展示所有可同步的提供商（拥有 active key 的），
/// 支持逐个勾选 / 一键全部，返回选中的提供商显示名列表；
/// 空列表表示取消，null 表示一键全部。
class SyncSelectDialog extends StatefulWidget {
  final AppState app;
  final List<String> available; // 可同步的提供商显示名（providerId / provider 名）

  const SyncSelectDialog({Key? key, required this.app, required this.available})
      : super(key: key);

  @override
  State<SyncSelectDialog> createState() => _SyncSelectDialogState();
}

class _SyncSelectDialogState extends State<SyncSelectDialog> {
  late final Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.available.toSet();
  }

  String _displayName(String id) {
    final def = widget.app.getProvider(id);
    if (def != null) return def.name;
    return ProviderTypeX.fromString(id).displayName;
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.available;
    final allChecked = all.isNotEmpty && _selected.length == all.length;

    return AlertDialog(
      title: Text(L10n.tr('选择同步提供商')),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 一键全部
            CheckboxListTile(
              value: allChecked,
              title: Row(
                children: [
                  const Icon(Icons.cloud_done_outlined, size: 18),
                  const SizedBox(width: 8),
                  Text(L10n.tr('全部拉取')),
                ],
              ),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: (v) => setState(() {
                if (v == true) {
                  _selected.addAll(all);
                } else {
                  _selected.clear();
                }
              }),
            ),
            const Divider(height: 8),
            // 逐个提供商勾选
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: all.map((id) {
                    return CheckboxListTile(
                      value: _selected.contains(id),
                      title: Text(_displayName(id)),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          _selected.add(id);
                        } else {
                          _selected.remove(id);
                        }
                      }),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(L10n.tr('取消')),
        ),
        ElevatedButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(context, _selected.toList()),
          child: Text(L10n.fmt('同步（{n}）', {'n': '${_selected.length}'})),
        ),
      ],
    );
  }
}