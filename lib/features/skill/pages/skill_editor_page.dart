
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/skill.dart';
import '../../../core/providers/skill_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';

/// SKILL.md 编辑器 — 在 App 内编辑技能的元数据、正文和子文件
class SkillEditorPage extends StatefulWidget {
  const SkillEditorPage({super.key, required this.skillName});

  final String skillName;

  @override
  State<SkillEditorPage> createState() => _SkillEditorPageState();
}

class _SkillEditorPageState extends State<SkillEditorPage> {
  late TextEditingController _nameCtrl;
  late TextEditingController _descCtrl;
  late TextEditingController _versionCtrl;
  late TextEditingController _authorCtrl;
  late TextEditingController _triggersCtrl;
  late TextEditingController _bodyCtrl;

  Skill? _original;
  bool _hasChanges = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _original = context.read<SkillProvider>().getByName(widget.skillName);
    _initControllers();
  }

  void _initControllers() {
    final s = _original;
    _nameCtrl = TextEditingController(text: s?.name ?? widget.skillName);
    _descCtrl = TextEditingController(text: s?.description ?? '');
    _versionCtrl = TextEditingController(text: s?.version ?? '1.0.0');
    _authorCtrl = TextEditingController(text: s?.author ?? '');
    _triggersCtrl = TextEditingController(text: s?.triggers.join(', ') ?? '');
    _bodyCtrl = TextEditingController(text: s?.content ?? '');

    _nameCtrl.addListener(_onChange);
    _descCtrl.addListener(_onChange);
    _versionCtrl.addListener(_onChange);
    _authorCtrl.addListener(_onChange);
    _triggersCtrl.addListener(_onChange);
    _bodyCtrl.addListener(_onChange);
  }

  void _onChange() {
    if (!_hasChanges) setState(() => _hasChanges = true);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _versionCtrl.dispose();
    _authorCtrl.dispose();
    _triggersCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final provider = context.read<SkillProvider>();
    setState(() => _saving = true);

    final triggers = _triggersCtrl.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);

    final updated = (_original ?? Skill(
      name: _nameCtrl.text.trim(),
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    )).copyWith(
      name: _nameCtrl.text.trim(),
      description: _descCtrl.text.trim(),
      version: _versionCtrl.text.trim().isEmpty ? '1.0.0' : _versionCtrl.text.trim(),
      author: _authorCtrl.text.trim(),
      triggers: triggers,
      content: _bodyCtrl.text,
      updatedAt: DateTime.now(),
    );

    try {
      await provider.update(updated);
      if (mounted) {
        setState(() {
          _original = updated;
          _hasChanges = false;
          _saving = false;
        });
        showAppSnackBar(
          context,
          message: '已保存: ${updated.name}',
          type: NotificationType.success,
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showAppSnackBar(
          context,
          message: '保存失败: $e',
          type: NotificationType.error,
        );
      }
    }
  }

  Future<bool> _onWillPop() async {
    if (!_hasChanges) return true;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).colorScheme.surface,
        title: const Text('未保存的更改'),
        content: const Text('你有未保存的修改，是否保存后再离开？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('discard'),
            child: const Text('不保存'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == 'save') {
      await _save();
      return true;
    }
    return result == 'discard';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return PopScope(
      canPop: !_hasChanges,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop) { if (!context.mounted) return; Navigator.of(context).pop(); }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IosIconButton(
            icon: Lucide.ArrowLeft,
            onTap: () async {
              if (_hasChanges) {
                final shouldPop = await _onWillPop();
                if (!context.mounted) return;
                if (shouldPop) Navigator.of(context).maybePop();
              } else {
                Navigator.of(context).maybePop();
              }
            },
          ),
          title: Text('编辑: ${_original?.name ?? widget.skillName}',
              style: const TextStyle(fontSize: 16)),
          actions: [
            _saving
                ? const Padding(
                    padding: EdgeInsets.only(right: 16),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IosIconButton(
                    icon: _hasChanges ? Lucide.Check : Lucide.Check,
                    onTap: _hasChanges ? _save : null,
                    color: _hasChanges ? null : cs.onSurface.withValues(alpha: 0.3),
                  ),
            const SizedBox(width: 12),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            // ── 元数据编辑 ──
            _SectionHeader(cs: cs, title: '元数据'),
            const SizedBox(height: 8),
            _FieldCard(
              cs: cs,
              isDark: isDark,
              label: '技能名称',
              icon: Lucide.Hash,
              controller: _nameCtrl,
            ),
            const SizedBox(height: 10),
            _FieldCard(
              cs: cs,
              isDark: isDark,
              label: '描述',
              icon: Lucide.FileText,
              controller: _descCtrl,
              maxLines: 2,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _FieldCard(
                    cs: cs,
                    isDark: isDark,
                    label: '版本',
                    icon: Lucide.Hash,
                    controller: _versionCtrl,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _FieldCard(
                    cs: cs,
                    isDark: isDark,
                    label: '作者',
                    icon: Lucide.User,
                    controller: _authorCtrl,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _FieldCard(
              cs: cs,
              isDark: isDark,
              label: '触发关键词（逗号分隔）',
              icon: Lucide.Zap,
              controller: _triggersCtrl,
              hint: 'keyword1, keyword2, ...',
            ),

            const SizedBox(height: 20),
            // ── 正文编辑 ──
            _SectionHeader(cs: cs, title: '正文（Markdown）'),
            const SizedBox(height: 8),
            _BodyEditor(cs: cs, isDark: isDark, controller: _bodyCtrl),

            // ── 子文件 ──
            if ((_original?.files ?? []).isNotEmpty) ...[
              const SizedBox(height: 20),
              _SectionHeader(
                cs: cs,
                title: '子文件 (${_original!.files.length})',
              ),
              const SizedBox(height: 8),
              ...(_original!.files).map((f) => _SubFileTile(
                file: f,
                cs: cs,
                isDark: isDark,
              )),
            ],
          ],
        ),
      ),
    );
  }
}

// ── 子组件 ──

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.cs, required this.title});
  final ColorScheme cs;
  final String title;
  @override
  Widget build(BuildContext context) => Text(
    title,
    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: cs.primary),
  );
}

class _FieldCard extends StatelessWidget {
  const _FieldCard({
    required this.cs,
    required this.isDark,
    required this.label,
    required this.icon,
    required this.controller,
    this.maxLines = 1,
    this.hint,
  });

  final ColorScheme cs;
  final bool isDark;
  final String label;
  final dynamic icon;
  final TextEditingController controller;
  final int maxLines;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: isDark ? 0.1 : 0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: cs.primary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            maxLines: maxLines,
            style: TextStyle(fontSize: 14, color: cs.onSurface),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.zero,
              border: InputBorder.none,
              hintText: hint,
              hintStyle: TextStyle(
                fontSize: 14,
                color: cs.onSurface.withValues(alpha: 0.3),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BodyEditor extends StatelessWidget {
  const _BodyEditor({
    required this.cs,
    required this.isDark,
    required this.controller,
  });

  final ColorScheme cs;
  final bool isDark;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? Colors.black12 : const Color(0xFFF7F7F9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.2)),
      ),
      child: TextField(
        controller: controller,
        maxLines: 20,
        minLines: 10,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: cs.onSurface,
          height: 1.5,
        ),
        decoration: InputDecoration(
          border: InputBorder.none,
          isCollapsed: true,
          hintText: '# 在此输入 Markdown 内容...',
          hintStyle: TextStyle(
            fontSize: 12,
            color: cs.onSurface.withValues(alpha: 0.25),
          ),
        ),
      ),
    );
  }
}

class _SubFileTile extends StatelessWidget {
  const _SubFileTile({
    required this.file,
    required this.cs,
    required this.isDark,
  });

  final SkillFile file;
  final ColorScheme cs;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: isDark ? 0.1 : 0.08),
        ),
      ),
      child: Row(
        children: [
          Icon(Lucide.FileText, size: 14, color: cs.onSurface.withValues(alpha: 0.5)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              file.relativePath,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: cs.primary,
              ),
            ),
          ),
          Text(
            _formatSize(file.sizeBytes),
            style: TextStyle(
              fontSize: 11,
              color: cs.onSurface.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

// ignore: unused_element
String? _subFileContent(BuildContext context, SkillFile file) {
  // 子文件内容预览在当前页面不做编辑，
  // 用户可以从技能详情页的 ReadOnly 视图查看
  return null;
}
