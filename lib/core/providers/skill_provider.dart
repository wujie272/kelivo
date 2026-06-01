/// SkillProvider — 技能管理器
///
/// 持久化：文件系统为主（~/skills/<name>/），SharedPreferences 缓存加速启动。
/// 写入：原子写入（tmp → rename），避免写半崩溃。
/// 绑定：Assistant.enabledSkills。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/skill.dart';
import '../services/skill/skill_parser.dart';
import '../../utils/app_directories.dart';

/// 内存缓存，mtime 自动失效
class _CacheEntry {
  final String content;
  final DateTime fileModifiedAt;
  const _CacheEntry({required this.content, required this.fileModifiedAt});
}

/// 技能使用统计
class SkillUsage {
  int totalCalls;
  DateTime lastUsed;
  Map<String, int> dailyCalls;

  SkillUsage({
    this.totalCalls = 0,
    DateTime? lastUsed,
    Map<String, int>? dailyCalls,
  }) : lastUsed = lastUsed ?? DateTime.now(),
       dailyCalls = dailyCalls ?? {};
}

class SkillProvider extends ChangeNotifier {
  static const String _prefsKey = 'savedSkills_v1';

  List<Skill> _skills = [];
  bool _initialized = false;
  String _skillsBasePath = ''; // 由 initialize() 初始化

  // ── 内容缓存（避免重复读盘） ──
  final Map<String, _CacheEntry> _bodyCache = {};
  final Map<String, Map<String, _CacheEntry>> _fileCache = {};

  List<Skill> get skills => List.unmodifiable(_skills);
  bool get initialized => _initialized;

  /// 技能根目录路径
  String _skillsDirPath() {
    if (_skillsBasePath.isNotEmpty) return _skillsBasePath;
    // 备用路径
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) return '$home/skills';
    return '${Directory.systemTemp.path}/skills';
  }

  Directory get skillsDir => Directory(_skillsDirPath());
  String get skillsDirPath => _skillsDirPath();

  /// 解析技能根目录路径（HOME → AppDocuments → tmp）
  Future<void> _resolveSkillsBasePath() async {
    try {
      final skillsDir = await AppDirectories.getSkillsDirectory();
      _skillsBasePath = skillsDir.path;
    } catch (_) {
      // 回退：HOME 环境变量（Termux）
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        _skillsBasePath = '$home/skills';
        return;
      }
      _skillsBasePath = '${Directory.systemTemp.path}/skills';
    }
  }

  Future<Directory> ensureSkillsDir() async {
    final dir = Directory(_skillsDirPath());
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  // ============================================================================
  // 工具支持方法（供 use_skill tool 调用）
  // ============================================================================

  /// 读技能正文（不含 frontmatter），供 use_skill
  /// 优先级：内存缓存(mtime) → 文件系统 → SharedPreferences
  String? readSkillBody(String name) {
    // 1. 查内存缓存
    final cached = _bodyCache[name];
    if (cached != null) {
      final file = File('${_skillsDirPath()}/$name/SKILL.md');
      if (file.existsSync()) {
        try {
          final mtime = file.statSync().modified;
          if (cached.fileModifiedAt == mtime) {
            return cached.content;
          }
        } catch (_) {}
      }
    }

    // 2. 读文件系统（主源）
    final skillDir = Directory('${_skillsDirPath()}/$name');
    final file = File('${skillDir.path}/SKILL.md');
    if (file.existsSync()) {
      try {
        final raw = file.readAsStringSync();
        final result = SkillParser.parseString(raw, sourcePath: file.path);
        if (result.isSuccess && result.meta.name == name) {
          final mtime = file.statSync().modified;
          _bodyCache[name] = _CacheEntry(content: result.content, fileModifiedAt: mtime);
          return result.content;
        }
      } catch (_) {}
    }

    // 3. 回退到 SharedPreferences 缓存
    final fallback = _skills.cast<Skill?>().firstWhere(
      (s) => s?.name == name,
      orElse: () => null,
    );
    return fallback?.content;
  }

  /// 读技能子文件，供 use_skill
  String? readSkillFile(String name, String relativePath) {
    // 1. 先查内存缓存
    final fileCache = _fileCache[name];
    if (fileCache != null) {
      final cached = fileCache[relativePath];
      if (cached != null) {
        final file = File('${_skillsDirPath()}/$name/$relativePath');
        if (file.existsSync()) {
          try {
            final mtime = file.statSync().modified;
            if (cached.fileModifiedAt == mtime) {
              return cached.content;
            }
          } catch (_) {}
        }
      }
    }

    // 2. 读文件系统
    final skillDir = Directory('${_skillsDirPath()}/$name');
    final file = File('${skillDir.path}/$relativePath');

    // 路径穿越保护
    try {
      final canonicalDir = skillDir.resolveSymbolicLinksSync();
      final canonicalFile = file.resolveSymbolicLinksSync();
      if (!canonicalFile.startsWith(canonicalDir)) return null;
    } catch (_) {
      return null;
    }

    if (!file.existsSync()) return null;
    try {
      final content = file.readAsStringSync();
      final mtime = file.statSync().modified;
      _fileCache.putIfAbsent(name, () => {})[relativePath] = _CacheEntry(content: content, fileModifiedAt: mtime);
      return content;
    } catch (_) {
      return null;
    }
  }

  /// 列出已启用的技能元数据（供 systemPrompt 生成）
  List<({String name, String description})> listEnabledMetadata(
    Set<String> enabledSkillNames,
  ) {
    final result = <({String name, String description})>[];
    for (final name in enabledSkillNames) {
      // 优先文件系统
      final file = File('${_skillsDirPath()}/$name/SKILL.md');
      if (file.existsSync()) {
        try {
          final parsed = SkillParser.parseString(file.readAsStringSync());
          if (parsed.isSuccess && parsed.meta.name == name) {
            result.add((name: name, description: parsed.meta.description));
            continue;
          }
        } catch (_) {}
      }
      // 回退到缓存
      final cached = _skills.cast<Skill?>().firstWhere(
        (s) => s?.name == name,
        orElse: () => null,
      );
      if (cached != null) {
        result.add((name: name, description: cached.description));
      }
    }
    return result;
  }

  /// 使内存缓存失效
  void _invalidateCache(String name) {
    _bodyCache.remove(name);
    _fileCache.remove(name);
  }

  // =========================== 使用统计 ===========================

  static const String _usagePrefsKey = 'skillUsage_v1';
  final Map<String, SkillUsage> _usageRecords = {};

  /// 记录一次技能使用
  Future<void> recordUsage(String skillName) async {
    final now = DateTime.now();
    final today = _todayKey(now);

    final record = _usageRecords.putIfAbsent(skillName, () => SkillUsage());
    record.totalCalls++;
    record.lastUsed = now;
    record.dailyCalls[today] = (record.dailyCalls[today] ?? 0) + 1;

    await _persistUsage();
    notifyListeners();
  }

  /// 获取技能使用统计
  SkillUsage? getSkillUsage(String skillName) => _usageRecords[skillName];

  /// 获取所有技能的总调用次数
  int get totalUsageCalls =>
      _usageRecords.values.fold(0, (sum, r) => sum + r.totalCalls);

  /// 获取使用最多的技能（前 N）
  List<(String name, int calls)> mostUsedSkills({int limit = 5}) {
    final sorted = _usageRecords.entries.toList()
      ..sort((a, b) => b.value.totalCalls.compareTo(a.value.totalCalls));
    return sorted.take(limit).map((e) => (e.key, e.value.totalCalls)).toList();
  }

  String _todayKey(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  Future<void> _persistUsage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonData = <String, Map<String, dynamic>>{};
      for (final e in _usageRecords.entries) {
        jsonData[e.key] = {
          'totalCalls': e.value.totalCalls,
          'lastUsed': e.value.lastUsed.toIso8601String(),
          'dailyCalls': e.value.dailyCalls,
        };
      }
      await prefs.setString(_usagePrefsKey, jsonEncode(jsonData));
    } catch (e) {
      debugPrint('[SkillProvider] persist usage error: $e');
    }
  }

  Future<void> _loadUsage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_usagePrefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in decoded.entries) {
        final data = entry.value as Map<String, dynamic>;
        final dc = <String, int>{};
        if (data['dailyCalls'] is Map) {
          for (final de in (data['dailyCalls'] as Map).entries) {
            dc[de.key.toString()] = (de.value as num).toInt();
          }
        }
        _usageRecords[entry.key] = SkillUsage(
          totalCalls: (data['totalCalls'] as num?)?.toInt() ?? 0,
          lastUsed: DateTime.tryParse(data['lastUsed']?.toString() ?? '') ?? DateTime.now(),
          dailyCalls: dc,
        );
      }
    } catch (e) {
      debugPrint('[SkillProvider] load usage error: $e');
    }
  }

  // ======================== 技能依赖解析 ========================

  /// 解析依赖链（BFS 防环）
  List<Skill> resolveDependencies(Skill skill, {Set<String>? visited}) {
    visited ??= <String>{};
    final result = <Skill>[];
    final queue = List<String>.from(skill.dependencies);
    visited.add(skill.name);

    while (queue.isNotEmpty) {
      final depName = queue.removeAt(0);
      if (visited.contains(depName)) {
        debugPrint('[SkillProvider] circular dependency detected: $depName');
        continue;
      }
      visited.add(depName);
      final dep = getByName(depName);
      if (dep == null) continue;
      result.add(dep);
      for (final subDep in dep.dependencies) {
        if (!visited.contains(subDep)) {
          queue.add(subDep);
        }
      }
    }
    return result;
  }

  /// 查找反向依赖
  List<Skill> findDependents(String skillName) {
    return _skills.where((s) => s.dependencies.contains(skillName)).toList();
  }

  // ======================== 加载与持久化 ========================

  Future<void> initialize() async {
    if (_initialized) return;
    await _resolveSkillsBasePath(); // 先确定技能根目录路径
    await _loadUsage();              // 加载使用统计
    await _load();                  // 文件系统 → 缓存
    await _importBuiltIns();        // 内置技能写入文件系统
    _initialized = true;
    notifyListeners();
  }

  Future<void> _load() async {
    _skills = [];

    // 1. 扫描 ~/skills/*/SKILL.md
    final dir = Directory(_skillsDirPath());
    if (await dir.exists()) {
      try {
        await for (final entry in dir.list()) {
          if (entry is Directory) {
            final skillMd = File('${entry.path}/SKILL.md');
            if (await skillMd.exists()) {
              final result = SkillParser.parseFile(skillMd.path);
              if (result.isSuccess && result.meta.name.isNotEmpty) {
                // 收集子文件
                final files = <SkillFile>[];
                try {
                  await for (final sub in entry.list(recursive: true, followLinks: false)) {
                    if (sub is File && sub.path != skillMd.path) {
                      final relPath = sub.path.replaceFirst('${entry.path}/', '');
                      final subContent = await sub.readAsString();
                      files.add(SkillFile(
                        relativePath: relPath,
                        content: subContent,
                        sizeBytes: subContent.length,
                      ));
                    }
                  }
                } catch (_) {}

                _skills.add(Skill.fromMeta(
                  meta: result.meta,
                  content: result.content,
                  files: files,
                  filePath: skillMd.path,
                ));
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[SkillProvider] file system scan error: $e');
      }
    }

    // 2. 从缓存加载缺失技能
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List;
        final cachedNames = _skills.map((s) => s.name).toSet();
        for (final e in list) {
          try {
            final skill = Skill.fromJson(e as Map<String, dynamic>);
            if (!cachedNames.contains(skill.name)) {
              _skills.add(skill);
              // 同时回写到文件系统，保证一致性
              await _writeToFileSystem(skill);
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[SkillProvider] load from prefs error: $e');
    }

    await _persist();
  }

  /// 首次启动时导入内置技能
  Future<void> _importBuiltIns() async {
    final builtInSkillDirs = [
      'obsidian-knowledge-worker',
      'tech-homelab-ops',
      'ai-api-manager',
      'obsidian-plugin-dev',
      'firefox-addon-dev',
    ];

    int imported = 0;
    for (final dirName in builtInSkillDirs) {
      // 如果文件系统已有同名技能，跳过
      final fsPath = '${_skillsDirPath()}/$dirName/SKILL.md';
      if (File(fsPath).existsSync()) continue;

      try {
        final raw = await rootBundle.loadString('assets/skills/$dirName/SKILL.md');
        final result = SkillParser.parseString(raw, sourcePath: 'assets/skills/$dirName/SKILL.md');
        if (!result.isSuccess || result.meta.name.isEmpty) continue;

        final skill = Skill.fromMeta(
          meta: result.meta,
          content: result.content,
          filePath: fsPath,
        );

        // 写入文件系统
        await _writeToFileSystem(skill);

        // 检查是否已在缓存中
        final exists = _skills.any((s) => s.name == result.meta.name);
        if (!exists) {
          _skills.add(skill);
        }
        imported++;
      } catch (_) {
        // 忽略加载失败的内置技能
      }
    }

    if (imported > 0) {
      await _persist();
      notifyListeners();
    }
  }

  /// 持久化缓存到 SharedPreferences
  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(_skills.map((s) => s.toJson()).toList());
      await prefs.setString(_prefsKey, json);
    } catch (e) {
      debugPrint('[SkillProvider] persist error: $e');
    }
  }

  /// 🔐 原子写入：tmp → rename → 回退直接覆盖
  Future<void> _atomicWriteToFileSystem(Skill skill) async {
    final targetDir = Directory('${_skillsDirPath()}/${skill.name}');
    final tmpName = '.tmp_${skill.name}_${DateTime.now().millisecondsSinceEpoch}';
    final tmpDir = Directory('${_skillsDirPath()}/$tmpName');

    try {
      // 1. 临时目录
      if (!await tmpDir.exists()) {
        await tmpDir.create(recursive: true);
      }

      // 2. 写入 SKILL.md
      final tmpSkillMd = File('${tmpDir.path}/SKILL.md');
      await tmpSkillMd.writeAsString(skill.toMarkdown());

      // 3. 写入所有子文件
      await _writeSubFiles(skill.files, tmpDir.path);

      // 4. fsync 目录（确保数据落盘）
      tmpSkillMd.parent.resolveSymbolicLinksSync();

      // 5. 原子 rename：tmp → target
      if (await targetDir.exists()) {
        // 目标已存在，先移到回收站做备份
        final backupName = '.bak_${skill.name}_${DateTime.now().millisecondsSinceEpoch}';
        final backupDir = Directory('${_skillsDirPath()}/$backupName');
        await targetDir.rename(backupDir.path);
        await tmpDir.rename(targetDir.path);
        // 删除备份
        await backupDir.delete(recursive: true);
      } else {
        await tmpDir.rename(targetDir.path);
      }
    } catch (e) {
      debugPrint('[SkillProvider] atomic write failed, fallback to direct write: $e');
      // 回退：直接写入 SKILL.md
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }
      final file = File('${targetDir.path}/SKILL.md');
      await file.writeAsString(skill.toMarkdown());
      await _writeSubFiles(skill.files, targetDir.path);
    } finally {
      // 清理残留的临时目录
      if (await tmpDir.exists()) {
        try {
          await tmpDir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// 写入子文件到指定目录
  Future<void> _writeSubFiles(List<SkillFile> files, String dirPath) async {
    for (final sf in files) {
      if (sf.relativePath.isEmpty || sf.relativePath == 'SKILL.md') continue;
      final target = File('$dirPath/${sf.relativePath}');
      if (!await target.parent.exists()) {
        await target.parent.create(recursive: true);
      }
      await target.writeAsString(sf.content);
    }
  }

  Future<void> _writeToFileSystem(Skill skill) async {
    await _atomicWriteToFileSystem(skill);
  }

  /// 从文件系统重读并更新缓存
  Future<void> _reloadFromFileSystem(String name) async {
    _invalidateCache(name);
    final skillDir = Directory('${_skillsDirPath()}/$name');
    final skillMd = File('${skillDir.path}/SKILL.md');
    if (!await skillMd.exists()) return;

    try {
      final result = SkillParser.parseFile(skillMd.path);
      if (!result.isSuccess || result.meta.name != name) return;

      final files = <SkillFile>[];
      try {
        await for (final sub in skillDir.list(recursive: true, followLinks: false)) {
          if (sub is File && sub.path != skillMd.path) {
            final relPath = sub.path.replaceFirst('${skillDir.path}/', '');
            final subContent = await sub.readAsString();
            files.add(SkillFile(
              relativePath: relPath,
              content: subContent,
              sizeBytes: subContent.length,
            ));
          }
        }
      } catch (_) {}

      final skill = Skill.fromMeta(
        meta: result.meta,
        content: result.content,
        files: files,
        filePath: skillMd.path,
      );

      final idx = _skills.indexWhere((s) => s.name == name);
      if (idx >= 0) {
        _skills[idx] = skill.copyWith(createdAt: _skills[idx].createdAt);
      } else {
        _skills.add(skill);
      }
    } catch (e) {
      debugPrint('[SkillProvider] _reloadFromFileSystem error: $e');
    }
  }

  // ========================== 手动刷新 ==========================

  /// 手动重扫 ~/skills/，重建缓存
  Future<void> refreshFromFileSystem() async {
    _bodyCache.clear();
    _fileCache.clear();

    // 保存已有技能的 created_at 信息
    final creationDates = <String, DateTime>{
      for (final s in _skills) s.name: s.createdAt,
    };

    _skills = [];

    final dir = Directory(_skillsDirPath());
    if (!await dir.exists()) {
      await _persist();
      notifyListeners();
      return;
    }

    try {
      await for (final entry in dir.list()) {
        if (entry is Directory) {
          final skillMd = File('${entry.path}/SKILL.md');
          if (await skillMd.exists()) {
            final result = SkillParser.parseFile(skillMd.path);
            if (result.isSuccess && result.meta.name.isNotEmpty) {
              final files = <SkillFile>[];
              try {
                await for (final sub in entry.list(recursive: true, followLinks: false)) {
                  if (sub is File && sub.path != skillMd.path) {
                    final relPath = sub.path.replaceFirst('${entry.path}/', '');
                    final subContent = await sub.readAsString();
                    files.add(SkillFile(
                      relativePath: relPath,
                      content: subContent,
                      sizeBytes: subContent.length,
                    ));
                  }
                }
              } catch (_) {}

              _skills.add(Skill.fromMeta(
                meta: result.meta,
                content: result.content,
                files: files,
                filePath: skillMd.path,
                createdAt: creationDates[result.meta.name],
              ));
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[SkillProvider] refreshFromFileSystem error: $e');
    }

    await _persist();
    notifyListeners();
  }

  // ============================== 导入 ==============================

  /// 从文件导入单个技能
  Future<Skill?> importFromFile(String filePath) async {
    try {
      final result = SkillParser.parseFile(filePath);
      if (!result.isSuccess) {
        debugPrint('[SkillProvider] import failed: ${result.error}');
        return null;
      }
      return _upsertSkill(result);
    } catch (e) {
      debugPrint('[SkillProvider] importFromFile error: $e');
      return null;
    }
  }

  /// 从字符串导入
  Future<Skill?> importFromString(String raw, {String? filePath}) async {
    try {
      final result = SkillParser.parseString(raw, sourcePath: filePath);
      if (!result.isSuccess) return null;
      return _upsertSkill(result);
    } catch (e) {
      debugPrint('[SkillProvider] importFromString error: $e');
      return null;
    }
  }

  // ===================== GitHub + 目录导入 =====================

  /// 支持的 GitHub URL 格式：/user/repo  /user/repo/tree/branch  /user/repo/blob/branch/path/to/SKILL.md
  static final RegExp _gitHubRe = RegExp(
    r'^https?://github\.com/([^/]+)/([^/]+?)(?:/tree/([^/]+))?(?:/blob/([^/]+)/(.+))?$',
  );

  /// 从 GitHub 仓库导入（含子文件）
  Future<Skill?> importFromGitHub(String url) async {
    final match = _gitHubRe.firstMatch(url.trim());
    if (match == null) return null;

    final owner = match.group(1)!;
    final repo = match.group(2)!.replaceAll('.git', '');
    final branch = match.group(3) ?? match.group(4) ?? 'main';
    final path = match.group(5) ?? '';

    try {
      if (path.isNotEmpty && path.endsWith('.md')) {
        // 指定了具体文件路径 → 获取单个 SKILL.md
        final rawUrl =
            'https://raw.githubusercontent.com/$owner/$repo/$branch/$path';
        final response = await http.get(Uri.parse(rawUrl));
        if (response.statusCode != 200) return null;
        return importFromString(
          response.body,
          filePath: rawUrl,
        );
      }

      // 未指定路径 → 尝试 SKILL.md（根目录）
      final rawUrl =
          'https://raw.githubusercontent.com/$owner/$repo/$branch/SKILL.md';
      final response = await http.get(Uri.parse(rawUrl));

      if (response.statusCode != 200) return null;

      // 导入主文件
      final skill = await importFromString(response.body, filePath: rawUrl);
      if (skill == null) return null;

      // 发现子文件：如果能获取 GitHub API tree，就扫描目录
      // 用 API 获取文件树：https://api.github.com/repos/{owner}/{repo}/git/trees/{branch}?recursive=1
      try {
        final apiUrl =
            'https://api.github.com/repos/$owner/$repo/git/trees/$branch?recursive=1';
        final apiResp = await http.get(
          Uri.parse(apiUrl),
          headers: {'Accept': 'application/vnd.github+json'},
        );
        if (apiResp.statusCode == 200) {
          final tree = jsonDecode(apiResp.body) as Map;
          final items = tree['tree'] as List?;
          if (items != null) {
            final subFiles = <SkillFile>[];
            for (final item in items) {
              final itemPath = item['path'] as String?;
              final itemType = item['type'] as String?;
              if (itemPath == null || itemType == 'tree') continue;
              if (itemPath == 'SKILL.md') continue;
              if (!itemPath.startsWith(path.isEmpty ? '' : '$path/'.replaceFirst('/SKILL.md', ''))) continue;
              if (!itemPath.endsWith('.md')) continue;

              // 获取 raw 内容
              final fileRawUrl =
                  'https://raw.githubusercontent.com/$owner/$repo/$branch/$itemPath';
              try {
                final fileResp = await http.get(Uri.parse(fileRawUrl));
                if (fileResp.statusCode == 200) {
                  subFiles.add(SkillFile(
                    relativePath: itemPath,
                    content: fileResp.body,
                    sizeBytes: fileResp.body.length,
                  ));
                }
              } catch (_) {}
            }

            if (subFiles.isNotEmpty) {
              // 更新技能，追加子文件
              final updated = skill.copyWith(
                files: subFiles,
                updatedAt: DateTime.now(),
              );
              await update(updated);
              return getByName(skill.name);
            }
          }
        }
      } catch (_) {
        // API 调用失败不影响主技能导入
      }

      return getByName(skill.name);
    } catch (e) {
      debugPrint('[SkillProvider] importFromGitHub error: $e');
      return null;
    }
  }

  /// 从目录导入为单个技能（含子文件）
  Future<Skill?> importFromDirectoryAsSkill(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return null;

    final skillMd = File('$dirPath/SKILL.md');
    if (!await skillMd.exists()) {
      debugPrint('[SkillProvider] importFromDirectoryAsSkill: SKILL.md not found in $dirPath');
      return null;
    }

    try {
      // 1. 解析 SKILL.md
      final result = SkillParser.parseFile(skillMd.path);
      if (!result.isSuccess) return null;

      // 2. 收集子文件（排除 SKILL.md 本身）
      final files = <SkillFile>[];
      await for (final entry in dir.list(recursive: true, followLinks: false)) {
        if (entry is File && entry.path != skillMd.path) {
          final relPath = entry.path.replaceFirst('${dir.path}/', '');
          try {
            final content = await entry.readAsString();
            files.add(SkillFile(
              relativePath: relPath,
              content: content,
              sizeBytes: content.length,
            ));
          } catch (_) {}
        }
      }

      // 3. 构建完整技能对象
      final skill = Skill.fromMeta(
        meta: result.meta,
        content: result.content,
        files: files,
        filePath: skillMd.path,
      );

      // 4. 写入文件系统（原子写入，含子文件）
      await _atomicWriteToFileSystem(skill);

      // 5. 重读文件系统并更新缓存
      await _reloadFromFileSystem(result.meta.name);

      await _persist();
      notifyListeners();

      return getByName(result.meta.name);
    } catch (e) {
      debugPrint('[SkillProvider] importFromDirectoryAsSkill error: $e');
      return null;
    }
  }

  /// 从文件夹批量导入所有 SKILL.md
  Future<int> importFromDirectory(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return 0;
    int count = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File && (entity.path.endsWith('.md') || entity.path.endsWith('.skill.md'))) {
          final skill = await importFromFile(entity.path);
          if (skill != null) count++;
        }
      }
    } catch (e) {
      debugPrint('[SkillProvider] importFromDirectory error: $e');
    }
    return count;
  }

  /// 内部：创建或更新技能（写入文件系统 + 缓存）
  Future<Skill?> _upsertSkill(SkillParseResult result) async {
    final existing = _skills.where((s) => s.name == result.meta.name).toList();

    Skill skill;
    if (existing.isNotEmpty) {
      final latest = existing.reduce((a, b) => a.updatedAt.isAfter(b.updatedAt) ? a : b);
      skill = latest.copyWith(
        version: result.meta.version,
        description: result.meta.description,
        author: result.meta.author,
        compatibility: result.meta.compatibility,
        triggers: result.meta.triggers,
        content: result.content,
        updatedAt: DateTime.now(),
      );
      // 更新文件系统
      await _writeToFileSystem(skill);
      // 重读文件系统（获取子文件信息）
      await _reloadFromFileSystem(skill.name);
    } else {
      skill = Skill.fromMeta(
        meta: result.meta,
        content: result.content,
        filePath: '${_skillsDirPath()}/${result.meta.name}/SKILL.md',
      );
      // 写入文件系统
      await _writeToFileSystem(skill);
      // 重读文件系统
      await _reloadFromFileSystem(skill.name);
    }

    await _persist();
    notifyListeners();
    return getByName(result.meta.name);
  }

  // =============================== CRUD ===============================

  Skill? getByName(String name) {
    try {
      return _skills.firstWhere((s) => s.name == name);
    } catch (_) {
      return null;
    }
  }

  Future<void> update(Skill updated) async {
    final idx = _skills.indexWhere((s) => s.name == updated.name);
    if (idx == -1) return;

    _skills[idx] = updated.copyWith(updatedAt: DateTime.now());

    // 写入文件系统
    _invalidateCache(updated.name);
    await _writeToFileSystem(_skills[idx]);

    // 重读文件系统（获取子文件）
    await _reloadFromFileSystem(updated.name);

    await _persist();
    notifyListeners();
  }

  /// 删除技能
  Future<void> delete(String name) async {
    _skills.removeWhere((s) => s.name == name);
    _invalidateCache(name);

    // 删除文件系统目录
    final skillDir = Directory('${_skillsDirPath()}/$name');
    if (await skillDir.exists()) {
      try {
        await skillDir.delete(recursive: true);
      } catch (e) {
        debugPrint('[SkillProvider] delete dir error: $e');
      }
    }

    await _persist();
    notifyListeners();
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _skills.length) return;
    if (newIndex < 0 || newIndex >= _skills.length) return;
    if (oldIndex == newIndex) return;
    final item = _skills.removeAt(oldIndex);
    _skills.insert(newIndex, item);
    await _persist();
    notifyListeners();
  }

  // ============================== 导出 ==============================

  /// 导出为 Markdown 字符串
  String exportToMarkdown(String name) {
    final skill = getByName(name);
    if (skill == null) return '';
    return skill.toMarkdown();
  }

  Future<bool> exportToFile(String name, String outputPath) async {
    final md = exportToMarkdown(name);
    if (md.isEmpty) return false;
    try {
      await File(outputPath).writeAsString(md);
      return true;
    } catch (_) {
      return false;
    }
  }
}