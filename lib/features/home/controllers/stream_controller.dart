import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'dart:convert';
import '../../../core/models/chat_message.dart';
import '../../../core/models/token_usage.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../chat/widgets/chat_message_widget.dart';
import '../../../utils/markdown_media_sanitizer.dart';
import 'streaming_content_notifier.dart';

export 'streaming_content_notifier.dart';

/// Controller for managing streaming message generation.
///
/// This controller handles:
/// - Stream chunk processing (content, reasoning, tool calls, tool results)
/// - Stream throttling to reduce UI rebuild frequency
/// - Reasoning state management (including segments)
/// - Tool UI state management
/// - Inline image sanitization during streaming
///
/// The controller is designed to work alongside ChatController and be used
/// by the home page to handle streaming generation without cluttering the UI code.
class StreamController {
  StreamController({
    required this._chatService,
    required this.onStateChanged,
    required this.getSettingsProvider,
    required this.getCurrentConversationId,
    this.onStreamTick,
  });

  final ChatService _chatService;

  /// Callback when state changes (trigger setState in the widget).
  /// NOTE: This should only be used for non-streaming state changes.
  /// For streaming content updates, use streamingContentNotifier instead.
  final VoidCallback onStateChanged;

  /// Optional callback fired during streaming updates (e.g., auto-scroll).
  final VoidCallback? onStreamTick;

  /// Lightweight notifier for streaming content updates.
  /// This avoids triggering full page rebuilds during streaming.
  final StreamingContentNotifier streamingContentNotifier =
      StreamingContentNotifier();

  /// Set of message IDs currently being streamed.
  /// Used to suppress onStateChanged calls during streaming.
  final Set<String> _activeStreamingIds = <String>{};

  /// Check if any message is currently streaming.
  bool get isAnyMessageStreaming => _activeStreamingIds.isNotEmpty;

  /// Mark a message as actively streaming.
  /// Also creates the StreamingContentNotifier for this message so that
  /// MessageListView can detect it and use ValueListenableBuilder.
  void markStreamingStarted(String messageId) {
    _activeStreamingIds.add(messageId);
    // Pre-create notifier so MessageListView can detect streaming state
    streamingContentNotifier.getNotifier(messageId);
  }

  /// Mark a message as no longer streaming.
  void markStreamingEnded(String messageId) {
    _activeStreamingIds.remove(messageId);
  }

  /// Call onStateChanged only if no messages are actively streaming.
  /// During streaming, UI updates are handled by ValueListenableBuilder.
  void _safeNotifyStateChanged() {
    if (_activeStreamingIds.isEmpty) {
      onStateChanged();
    }
  }

  /// Get current settings provider (for auto-collapse setting, etc.).
  final SettingsProvider Function() getSettingsProvider;

  /// Get current conversation ID (for checking if we should update UI).
  final String? Function() getCurrentConversationId;

  // ============================================================================
  // State Maps
  // ============================================================================

  /// Reasoning data per assistant message.
  final Map<String, ReasoningData> _reasoning = <String, ReasoningData>{};
  Map<String, ReasoningData> get reasoning => _reasoning;

  /// Reasoning segments per assistant message (for interleaved tool/thinking).
  final Map<String, List<ReasoningSegmentData>> _reasoningSegments =
      <String, List<ReasoningSegmentData>>{};
  Map<String, List<ReasoningSegmentData>> get reasoningSegments =>
      _reasoningSegments;

  /// Content/text split metadata per assistant message.
  final Map<String, ContentSplitData> _contentSplits =
      <String, ContentSplitData>{};
  Map<String, ContentSplitData> get contentSplits => _contentSplits;

  /// Tool UI parts per assistant message.
  final Map<String, List<ToolUIPart>> _toolParts = <String, List<ToolUIPart>>{};
  Map<String, List<ToolUIPart>> get toolParts => _toolParts;

  /// Gemini thought signatures per assistant message.
  final Map<String, String> _geminiThoughtSigs = <String, String>{};
  Map<String, String> get geminiThoughtSigs => _geminiThoughtSigs;

  // ============================================================================
  // Throttle State
  // ============================================================================

  /// UI output interval for streaming content.
  static const Duration _streamThrottleInterval = Duration(milliseconds: 50);
  static const int _streamSmoothMinCount = 2;
  static const int _streamSmoothBaseCount = 40;
  static const int _streamSmoothMaxCount = 240;
  static const double _streamSmoothPickRate = 0.1;
  static const int _streamSmoothMoveAverageLength = 10;

  /// Throttle timers per message ID.
  final Map<String, Timer?> _streamThrottleTimers = <String, Timer?>{};

  /// Per-message smooth output state.
  final Map<String, _StreamSmoothState> _streamSmoothStates =
      <String, _StreamSmoothState>{};

  /// Delay before sanitizing inline base64 images.
  static const Duration _inlineImageSanitizeDelay = Duration(milliseconds: 120);
  /// Tool call coalescing buffer and timer per message.
  /// When handleToolCallsChunk arrives, buffer the calls instead of immediately
  /// showing loading state. If handleToolResultsChunk arrives within the coalesce
  /// window, merge them together and skip the loading flash entirely.
  static const Duration _toolCoalesceDelay = Duration(milliseconds: 400);

  /// Per-message pending tool calls (buffered, not yet shown to UI).
  final Map<String, _PendingToolCoalesce> _pendingToolCoalesce =
      <String, _PendingToolCoalesce>{};

  /// Per-message coalesce fallback timer.
  /// Fires after _toolCoalesceDelay if results haven't arrived yet,
  /// flushing the buffered calls as loading state.
  final Map<String, Timer?> _toolCoalesceTimers = <String, Timer?>{};


  /// Timers for inline image sanitization per message.
  final Map<String, Timer?> _inlineImageSanitizeTimers = <String, Timer?>{};

  /// Set of message IDs currently being sanitized.
  final Set<String> _inlineImageSanitizing = <String>{};

  /// Regex to capture Gemini thought signature comments.
  static final RegExp _geminiThoughtSigRe = RegExp(
    r'<!--\s*gemini_thought_signatures:.*?-->',
    dotAll: true,
  );

  // ============================================================================
  // Public Methods - State Access
  // ============================================================================

  /// Get reasoning data for a message.
  ReasoningData? getReasoningData(String messageId) => _reasoning[messageId];

  /// Set reasoning data for a message.
  void setReasoningData(String messageId, ReasoningData data) {
    _reasoning[messageId] = data;
  }

  /// Remove reasoning data for a message.
  void removeReasoningData(String messageId) {
    _reasoning.remove(messageId);
  }

  /// Get reasoning segments for a message.
  List<ReasoningSegmentData>? getReasoningSegments(String messageId) =>
      _reasoningSegments[messageId];

  /// Set reasoning segments for a message.
  void setReasoningSegments(
    String messageId,
    List<ReasoningSegmentData> segments,
  ) {
    _reasoningSegments[messageId] = segments;
  }

  /// Remove reasoning segments for a message.
  void removeReasoningSegments(String messageId) {
    _reasoningSegments.remove(messageId);
  }

  /// Get content split metadata for a message.
  ContentSplitData? getContentSplitData(String messageId) =>
      _contentSplits[messageId];

  /// Set content split metadata for a message.
  void setContentSplitData(String messageId, ContentSplitData data) {
    _contentSplits[messageId] = data;
  }

  /// Remove content split metadata for a message.
  void removeContentSplitData(String messageId) {
    _contentSplits.remove(messageId);
  }

  int getReasoningSegmentCount(String messageId) =>
      _reasoningSegments[messageId]?.length ?? 0;

  int getToolPartsCount(String messageId) => _toolParts[messageId]?.length ?? 0;

  /// Get tool parts for a message.
  List<ToolUIPart>? getToolParts(String messageId) => _toolParts[messageId];

  /// Set tool parts for a message.
  void setToolParts(String messageId, List<ToolUIPart> parts) {
    _toolParts[messageId] = parts;
  }

  /// Remove tool parts for a message.
  void removeToolParts(String messageId) {
    _toolParts.remove(messageId);
  }

  /// Clear all state for a message (reasoning, segments, tools).
  void clearMessageState(String messageId) {
    _reasoning.remove(messageId);
    _reasoningSegments.remove(messageId);
    _contentSplits.remove(messageId);
    _toolParts.remove(messageId);
    _geminiThoughtSigs.remove(messageId);
    _pendingToolCoalesce.remove(messageId);
    _toolCoalesceTimers[messageId]?.cancel();
    _toolCoalesceTimers.remove(messageId);
    _cleanupStreamTimers(messageId);
  }

  /// Clear all state maps (for new conversation).
  void clearAllState() {
    _reasoning.clear();
    _reasoningSegments.clear();
    _contentSplits.clear();
    _toolParts.clear();
    _geminiThoughtSigs.clear();
    _pendingToolCoalesce.clear();
    for (final t in _toolCoalesceTimers.values) { t?.cancel(); }
    _toolCoalesceTimers.clear();
    _cancelAllTimers();
    streamingContentNotifier.clear();
  }

  // ============================================================================
  // Gemini Thought Signature Handling
  // ============================================================================

  /// Capture and strip Gemini thought signature from content.
  String captureGeminiThoughtSignature(String content, String messageId) {
    if (content.isEmpty) return content;
    final m = _geminiThoughtSigRe.firstMatch(content);
    if (m != null) {
      final sig = m.group(0) ?? '';
      if (sig.isNotEmpty) {
        if (_geminiThoughtSigs[messageId] != sig) {
          _geminiThoughtSigs[messageId] = sig;
          unawaited(_chatService.setGeminiThoughtSignature(messageId, sig));
        }
      }
      content = content.replaceAll(_geminiThoughtSigRe, '').trimRight();
    }
    return content;
  }

  /// Append Gemini thought signature for API calls (when sending history).
  String appendGeminiThoughtSignatureForApi(
    ChatMessage message,
    String content,
  ) {
    String? sig = _geminiThoughtSigs[message.id];
    sig ??= _chatService.getGeminiThoughtSignature(message.id);
    if (sig != null &&
        sig.isNotEmpty &&
        !content.contains('gemini_thought_signatures:')) {
      if (content.isEmpty) return sig;
      return '$content\n$sig';
    }
    return content;
  }

  /// Clear Gemini thought signatures map.
  void clearGeminiThoughtSigs() {
    _geminiThoughtSigs.clear();
  }

  // ============================================================================
  // Reasoning Serialization
  // ============================================================================

  /// Serialize reasoning segments to JSON string.
  String serializeReasoningSegments(List<ReasoningSegmentData> segments) {
    final list = segments
        .map(
          (s) => {
            'text': s.text,
            'startAt': s.startAt?.toIso8601String(),
            'finishedAt': s.finishedAt?.toIso8601String(),
            'expanded': s.expanded,
            'toolStartIndex': s.toolStartIndex,
          },
        )
        .toList();
    return _encodeJson(list);
  }

  String serializeReasoningSegmentsWithSplits(
    List<ReasoningSegmentData> segments, {
    List<int>? contentSplitOffsets,
    List<int>? reasoningCountAtSplit,
    List<int>? toolCountAtSplit,
  }) {
    final list = segments
        .map(
          (s) => {
            'text': s.text,
            'startAt': s.startAt?.toIso8601String(),
            'finishedAt': s.finishedAt?.toIso8601String(),
            'expanded': s.expanded,
            'toolStartIndex': s.toolStartIndex,
          },
        )
        .toList();

    if (contentSplitOffsets == null &&
        reasoningCountAtSplit == null &&
        toolCountAtSplit == null) {
      return _encodeJson(list);
    }

    final normalized = _normalizeContentSplitData(
      ContentSplitData(
        offsets: List<int>.of(contentSplitOffsets ?? const <int>[]),
        reasoningCounts: List<int>.of(reasoningCountAtSplit ?? const <int>[]),
        toolCounts: List<int>.of(toolCountAtSplit ?? const <int>[]),
      ),
    );

    return _encodeJson({
      'v': 2,
      'segments': list,
      'contentSplits': {
        'offsets': normalized.offsets,
        'reasoningCounts': normalized.reasoningCounts,
        'toolCounts': normalized.toolCounts,
      },
    });
  }

  /// Deserialize reasoning segments from JSON string.
  List<ReasoningSegmentData> deserializeReasoningSegments(String? json) {
    if (json == null || json.isEmpty) return [];
    try {
      final decoded = _decodeJson(json);
      final list = decoded is Map<String, dynamic>
          ? (decoded['segments'] as List? ?? const [])
          : decoded as List;
      return list.map((item) {
        final s = ReasoningSegmentData();
        s.text = item['text'] ?? '';
        s.startAt = item['startAt'] != null
            ? DateTime.parse(item['startAt'])
            : null;
        final parsedFinished = item['finishedAt'] != null
            ? DateTime.parse(item['finishedAt'])
            : null;
        // If finishedAt is null but startAt exists, the stream was interrupted;
        // treat segment as finished to avoid an infinite timer on restore.
        s.finishedAt = parsedFinished ?? s.startAt;
        s.expanded = item['expanded'] ?? false;
        s.toolStartIndex = (item['toolStartIndex'] as int?) ?? 0;
        return s;
      }).toList();
    } catch (_) {
      return [];
    }
  }

  ContentSplitData? deserializeContentSplits(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      final decoded = _decodeJson(json);
      if (decoded is! Map<String, dynamic>) return null;
      final contentSplits = (decoded['contentSplits'] as Map?)
          ?.cast<String, dynamic>();
      if (contentSplits == null) return null;
      return _normalizeContentSplitData(
        ContentSplitData(
          offsets: (contentSplits['offsets'] as List? ?? const [])
              .map((item) => item as int)
              .toList(),
          reasoningCounts:
              (contentSplits['reasoningCounts'] as List? ?? const [])
                  .map((item) => item as int)
                  .toList(),
          toolCounts: (contentSplits['toolCounts'] as List? ?? const [])
              .map((item) => item as int)
              .toList(),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  ContentSplitData _normalizeContentSplitData(ContentSplitData data) {
    final length = math.min(
      data.offsets.length,
      math.min(data.reasoningCounts.length, data.toolCounts.length),
    );
    return ContentSplitData(
      offsets: List<int>.of(data.offsets.take(length)),
      reasoningCounts: List<int>.of(data.reasoningCounts.take(length)),
      toolCounts: List<int>.of(data.toolCounts.take(length)),
    );
  }
// JSON helpers using dart:convert
String _encodeJson(dynamic obj) => jsonEncode(obj);
dynamic _decodeJson(String json) => jsonDecode(json);

  // ============================================================================
  // Tool Parts Deduplication
  // ============================================================================

  /// Deduplicate tool UI parts by id or by name+args when id is empty.
  List<ToolUIPart> dedupeToolPartsList(List<ToolUIPart> parts) {
    final completedIds = <String>{
      for (final p in parts)
        if (p.id.trim().isNotEmpty && _hasToolContent(p.content)) p.id.trim(),
    };
    final completedNoIdBases = <String>{
      for (final p in parts)
        if (p.id.trim().isEmpty && _hasToolContent(p.content))
          _toolDedupeBase(p.toolName, p.arguments),
    };
    final indexByKey = <String, int>{};
    final out = <ToolUIPart>[];
    for (final p in parts) {
      final id = p.id.trim();
      if (!_hasToolContent(p.content) &&
          ((id.isNotEmpty && completedIds.contains(id)) ||
              (id.isEmpty &&
                  completedNoIdBases.contains(
                    _toolDedupeBase(p.toolName, p.arguments),
                  )))) {
        continue;
      }
      final key = _toolDedupeKey(
        id: p.id,
        name: p.toolName,
        arguments: p.arguments,
        content: p.content,
      );
      final existingIndex = indexByKey[key];
      if (existingIndex != null) {
        if (id.isNotEmpty) out[existingIndex] = p;
        continue;
      }
      indexByKey[key] = out.length;
      out.add(p);
    }
    return out;
  }

  /// Deduplicate raw persisted tool events.
  List<Map<String, dynamic>> dedupeToolEvents(
    List<Map<String, dynamic>> events,
  ) {
    final completedIds = <String>{
      for (final e in events)
        if ((e['id']?.toString() ?? '').trim().isNotEmpty &&
            _hasToolContent(e['content']?.toString()))
          (e['id']?.toString() ?? '').trim(),
    };
    final completedNoIdBases = <String>{
      for (final e in events)
        if ((e['id']?.toString() ?? '').trim().isEmpty &&
            _hasToolContent(e['content']?.toString()))
          _toolDedupeBase(
            e['name']?.toString() ?? '',
            (e['arguments'] as Map?)?.cast<String, dynamic>() ??
                const <String, dynamic>{},
          ),
    };
    final indexByKey = <String, int>{};
    final out = <Map<String, dynamic>>[];
    for (final e in events) {
      final id = (e['id']?.toString() ?? '').trim();
      final name = (e['name']?.toString() ?? '');
      final args =
          ((e['arguments'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{});
      if (!_hasToolContent(e['content']?.toString()) &&
          ((id.isNotEmpty && completedIds.contains(id)) ||
              (id.isEmpty &&
                  completedNoIdBases.contains(_toolDedupeBase(name, args))))) {
        continue;
      }
      final key = _toolDedupeKey(
        id: id,
        name: name,
        arguments: args,
        content: e['content']?.toString(),
      );
      final normalizedEvent = e.map((k, v) => MapEntry(k.toString(), v));
      final existingIndex = indexByKey[key];
      if (existingIndex != null) {
        if (id.isNotEmpty) out[existingIndex] = normalizedEvent;
        continue;
      }
      indexByKey[key] = out.length;
      out.add(normalizedEvent);
    }
    return out;
  }

  String _toolDedupeBase(String name, Map<String, dynamic> arguments) {
    return 'name:$name|args:${_encodeJson(arguments)}';
  }

  bool _hasToolContent(String? content) => content?.trim().isNotEmpty == true;

  String _toolDedupeKey({
    required String id,
    required String name,
    required Map<String, dynamic> arguments,
    String? content,
  }) {
    final trimmedId = id.trim();
    if (trimmedId.isNotEmpty) return 'id:$trimmedId';

    final base = _toolDedupeBase(name, arguments);
    final trimmedContent = content?.trim();
    if (trimmedContent == null || trimmedContent.isEmpty) return base;
    return '$base|content:$trimmedContent';
  }

  // ============================================================================
  // Stream Throttling
  // ============================================================================

  /// Schedule a throttled UI update for streaming content.
  ///
  /// This method uses StreamingContentNotifier to update only the streaming
  /// message widget, avoiding full page rebuilds that cause lag.
  void scheduleThrottledUpdate(
    String messageId,
    String conversationId,
    String content, {
    required void Function(String messageId, String content, int totalTokens)
    updateMessageInList,
    required int totalTokens,
    List<int>? contentSplitOffsets,
    List<int>? reasoningCountAtSplit,
    List<int>? toolCountAtSplit,
    int? promptTokens,
    int? completionTokens,
    int? cachedTokens,
    int? durationMs,
  }) {
    final state = _streamSmoothStates.putIfAbsent(
      messageId,
      _StreamSmoothState.new,
    );
    state
      ..conversationId = conversationId
      ..targetContent = content
      ..totalTokens = totalTokens
      ..contentSplitOffsets = contentSplitOffsets
      ..reasoningCountAtSplit = reasoningCountAtSplit
      ..toolCountAtSplit = toolCountAtSplit
      ..promptTokens = promptTokens
      ..completionTokens = completionTokens
      ..cachedTokens = cachedTokens
      ..durationMs = durationMs
      ..updateMessageInList = updateMessageInList;

    // Ensure notifier exists for this message
    streamingContentNotifier.getNotifier(messageId);

    _streamThrottleTimers[messageId] ??= Timer.periodic(
      _streamThrottleInterval,
      (_) => _flushSmoothStreamTick(messageId),
    );
  }

  void _flushSmoothStreamTick(String messageId) {
    final state = _streamSmoothStates[messageId];
    if (state == null) return;
    if (getCurrentConversationId() != state.conversationId) return;

    final nextContent = state.takeNextContentSlice(
      minCount: _streamSmoothMinCount,
      baseCount: _streamSmoothBaseCount,
      maxCount: _streamSmoothMaxCount,
      pickRate: _streamSmoothPickRate,
      moveAverageLength: _streamSmoothMoveAverageLength,
    );
    if (nextContent == null) return;

    _publishSmoothStreamContent(messageId, state, nextContent);
  }

  void _publishSmoothStreamContent(
    String messageId,
    _StreamSmoothState state,
    String content,
  ) {
    streamingContentNotifier.updateContent(
      messageId,
      content,
      state.totalTokens,
      contentSplitOffsets: state.contentSplitOffsets,
      reasoningCountAtSplit: state.reasoningCountAtSplit,
      toolCountAtSplit: state.toolCountAtSplit,
      promptTokens: state.promptTokens,
      completionTokens: state.completionTokens,
      cachedTokens: state.cachedTokens,
      durationMs: state.durationMs,
    );
    state.updateMessageInList?.call(messageId, content, state.totalTokens);
    onStreamTick?.call();
  }

  String? _flushPendingStreamUpdate(String messageId) {
    final state = _streamSmoothStates[messageId];
    if (state == null) return null;
    final content = state.flushTargetContent();
    if (content == null) return state.visibleContent;
    if (getCurrentConversationId() == state.conversationId) {
      _publishSmoothStreamContent(messageId, state, content);
    } else {
      state.updateMessageInList?.call(messageId, content, state.totalTokens);
    }
    return content;
  }

  /// Get pending stream content for a message.
  String? getPendingStreamContent(String messageId) =>
      _streamSmoothStates[messageId]?.targetContent;

  /// Set pending stream content (used by inline image sanitizer).
  void setPendingStreamContent(String messageId, String content) {
    final state = _streamSmoothStates.putIfAbsent(
      messageId,
      _StreamSmoothState.new,
    );
    state.targetContent = content;
  }

  /// Clean up stream throttle timers for a message.
  void _cleanupStreamTimers(String messageId) {
    _flushPendingStreamUpdate(messageId);
    _streamThrottleTimers[messageId]?.cancel();
    _streamThrottleTimers.remove(messageId);
    _streamSmoothStates.remove(messageId);
    _inlineImageSanitizeTimers[messageId]?.cancel();
    _inlineImageSanitizeTimers.remove(messageId);
    _inlineImageSanitizing.remove(messageId);
    _pendingToolCoalesce.remove(messageId);
    _toolCoalesceTimers[messageId]?.cancel();
    _toolCoalesceTimers.remove(messageId);
  }

  /// Clean up timers for a message (public API).
  void cleanupTimers(String messageId) {
    _cleanupStreamTimers(messageId);
  }

  /// Remove the streaming content notifier for a message.
  ///
  /// This must be called AFTER onMessagesChanged to avoid a race where
  /// the UI rebuilds without the notifier and falls back to stale
  /// message.content (which may still be empty).
  /// Idempotent: safe to call multiple times.
  void removeStreamingNotifier(String messageId) {
    streamingContentNotifier.removeNotifier(messageId);
  }

  /// Cancel all throttle timers.
  void _cancelAllTimers() {
    for (final timer in _streamThrottleTimers.values) {
      timer?.cancel();
    }
    _streamThrottleTimers.clear();
    _streamSmoothStates.clear();
    for (final timer in _inlineImageSanitizeTimers.values) {
      timer?.cancel();
    }
    _inlineImageSanitizeTimers.clear();
    _inlineImageSanitizing.clear();
    _pendingToolCoalesce.clear();
    for (final timer in _toolCoalesceTimers.values) {
      timer?.cancel();
    }
    _toolCoalesceTimers.clear();
  }

  // ============================================================================
  // Inline Image Sanitization
  // ============================================================================

  /// Schedule inline base64 image sanitization.
  void scheduleInlineImageSanitize(
    String messageId, {
    String? latestContent,
    bool immediate = false,
    required Future<void> Function(String messageId, String sanitizedContent)
    onSanitized,
  }) {
    // Quick pre-check to avoid needless timers
    final snapshot = latestContent ?? '';
    if (snapshot.isEmpty ||
        !snapshot.contains('data:image') ||
        !snapshot.contains('base64,')) {
      return;
    }

    // Debounce per message
    _inlineImageSanitizeTimers[messageId]?.cancel();
    _inlineImageSanitizeTimers[messageId] = Timer(
      immediate ? Duration.zero : _inlineImageSanitizeDelay,
      () async {
        if (_inlineImageSanitizing.contains(messageId)) return;
        _inlineImageSanitizing.add(messageId);
        try {
          String current = latestContent ?? '';
          if (current.isEmpty ||
              !current.contains('data:image') ||
              !current.contains('base64,')) {
            return;
          }

          final sanitized =
              await MarkdownMediaSanitizer.replaceInlineBase64Images(current);
          if (sanitized == current) return;

          // Keep throttled UI updates in sync.
          setPendingStreamContent(messageId, sanitized);
          await onSanitized(messageId, sanitized);
        } catch (_) {
          // Swallow errors to avoid crashing streaming UI
        } finally {
          _inlineImageSanitizing.remove(messageId);
          _inlineImageSanitizeTimers.remove(messageId);
        }
      },
    );
  }

  // ============================================================================
  // Stream Chunk Processing
  // ============================================================================

  /// Process a reasoning chunk from stream.
  Future<void> handleReasoningChunk(
    ChatStreamChunk chunk,
    StreamingState state, {
    required Future<void> Function(
      String messageId, {
      String? reasoningText,
      DateTime? reasoningStartAt,
      String? reasoningSegmentsJson,
    })
    updateReasoningInDb,
  }) async {
    if ((chunk.reasoning ?? '').isEmpty || !state.ctx.supportsReasoning) return;

    final messageId = state.messageId;
    final conversationId = state.conversationId;
    state.hadThinkingBlock = true;
    _contentSplits[messageId] = _normalizeContentSplitData(
      ContentSplitData(
        offsets: List<int>.of(state.contentSplitOffsets),
        reasoningCounts: List<int>.of(state.reasoningCountAtSplit),
        toolCounts: List<int>.of(state.toolCountAtSplit),
      ),
    );

    if (state.ctx.streamOutput) {
      final initialExpanded = !getSettingsProvider().autoCollapseThinking;
      final isNewReasoning = !_reasoning.containsKey(messageId);
      final r = _reasoning[messageId] ?? ReasoningData();
      r.text += chunk.reasoning!;
      r.startAt ??= DateTime.now();
      // NOTE: Do not reset r.expanded here - preserve user's toggle state during streaming
      if (isNewReasoning) {
        r.expanded = initialExpanded;
      }
      _reasoning[messageId] = r;

      // Add to reasoning segments for mixed display
      final segments =
          _reasoningSegments[messageId] ?? <ReasoningSegmentData>[];
      if (segments.isEmpty) {
        final newSegment = ReasoningSegmentData();
        newSegment.text = chunk.reasoning!;
        newSegment.startAt = DateTime.now();
        newSegment.expanded = initialExpanded;
        newSegment.toolStartIndex = (_toolParts[messageId]?.length ?? 0);
        segments.add(newSegment);
      } else {
        final hasToolsAfterLastSegment =
            (_toolParts[messageId]?.isNotEmpty ?? false);
        final lastSegment = segments.last;
        if (hasToolsAfterLastSegment && lastSegment.finishedAt != null) {
          final newSegment = ReasoningSegmentData();
          newSegment.text = chunk.reasoning!;
          newSegment.startAt = DateTime.now();
          newSegment.expanded = initialExpanded;
          newSegment.toolStartIndex = (_toolParts[messageId]?.length ?? 0);
          segments.add(newSegment);
        } else {
          lastSegment.text += chunk.reasoning!;
          lastSegment.startAt ??= DateTime.now();
        }
      }
      _reasoningSegments[messageId] = segments;

      await updateReasoningInDb(
        messageId,
        reasoningSegmentsJson: serializeReasoningSegmentsWithSplits(
          segments,
          contentSplitOffsets: state.contentSplitOffsets,
          reasoningCountAtSplit: state.reasoningCountAtSplit,
          toolCountAtSplit: state.toolCountAtSplit,
        ),
      );

      // Update reasoning via StreamingContentNotifier for real-time UI updates
      // without triggering full page rebuild (only when viewing this conversation)
      if (getCurrentConversationId() == conversationId) {
        streamingContentNotifier.updateReasoning(
          messageId,
          reasoningText: r.text,
          reasoningStartAt: r.startAt,
          contentSplitOffsets: state.contentSplitOffsets,
          reasoningCountAtSplit: state.reasoningCountAtSplit,
          toolCountAtSplit: state.toolCountAtSplit,
        );
        onStreamTick?.call();
      }

      await updateReasoningInDb(
        messageId,
        reasoningText: r.text,
        reasoningStartAt: r.startAt,
      );
    } else {
      state.reasoningStartAt ??= DateTime.now();
      state.bufferedReasoning += chunk.reasoning!;
      await updateReasoningInDb(
        messageId,
        reasoningText: state.bufferedReasoning,
        reasoningStartAt: state.reasoningStartAt,
      );
    }
  }

  /// Process tool calls chunk from stream.
  ///
  /// Buffers tool calls with a short coalesce delay before updating the UI.
  /// If handleToolResultsChunk arrives within the window, they are merged
  /// and shown together, skipping the loading flash entirely.
  Future<void> handleToolCallsChunk(
    ChatStreamChunk chunk,
    StreamingState state, {
    required Future<void> Function(String messageId, String json)
    updateReasoningSegmentsInDb,
    required Future<void> Function(
      String messageId,
      List<Map<String, dynamic>> events,
    )
    setToolEventsInDb,
    required List<Map<String, dynamic>> Function(String messageId)
    getToolEventsFromDb,
  }) async {
    if ((chunk.toolCalls ?? const []).isEmpty) return;

    final messageId = state.messageId;
    state.hadThinkingBlock = true;
    _contentSplits[messageId] = _normalizeContentSplitData(
      ContentSplitData(
        offsets: List<int>.of(state.contentSplitOffsets),
        reasoningCounts: List<int>.of(state.reasoningCountAtSplit),
        toolCounts: List<int>.of(state.toolCountAtSplit),
      ),
    );

    // Finish any unfinished reasoning segment when tools start
    final segments = _reasoningSegments[messageId] ?? <ReasoningSegmentData>[];
    if (segments.isNotEmpty && segments.last.finishedAt == null) {
      segments.last.finishedAt = DateTime.now();
      final autoCollapse = getSettingsProvider().autoCollapseThinking;
      if (autoCollapse) {
        segments.last.expanded = false;
        final rd = _reasoning[messageId];
        if (rd != null) rd.expanded = false;
      }
      _reasoningSegments[messageId] = segments;
      await updateReasoningSegmentsInDb(
        messageId,
        serializeReasoningSegmentsWithSplits(
          segments,
          contentSplitOffsets: state.contentSplitOffsets,
          reasoningCountAtSplit: state.reasoningCountAtSplit,
          toolCountAtSplit: state.toolCountAtSplit,
        ),
      );
    }

    // Buffer tool calls instead of immediately showing loading state.
    // Start a coalesce timer; if results arrive before it fires, they'll
    // merge and skip the loading flash entirely.
    _pendingToolCoalesce[messageId] = _PendingToolCoalesce(
      calls: chunk.toolCalls!,
      chunk: chunk,
      state: state,
    );

    // Cancel any existing timer and set a new one
    _toolCoalesceTimers[messageId]?.cancel();
    _toolCoalesceTimers[messageId] = Timer(
      _toolCoalesceDelay,
      () => _flushToolCoalesce(messageId, state, chunk, 
        updateReasoningSegmentsInDb: updateReasoningSegmentsInDb,
        setToolEventsInDb: setToolEventsInDb,
        getToolEventsFromDb: getToolEventsFromDb,
      ),
    );

    // Persist tool events immediately (needed for DB, loading state can wait)
    try {
      final prev = getToolEventsFromDb(messageId);
      final newEvents = <Map<String, dynamic>>[
        ...prev,
        for (final c in chunk.toolCalls!)
          {
            'id': c.id,
            'name': c.name,
            'arguments': c.arguments,
            'content': null,
            if (c.metadata != null && c.metadata!.isNotEmpty)
              'metadata': c.metadata,
          },
      ];
      await setToolEventsInDb(messageId, dedupeToolEvents(newEvents));
    } catch (_) {}
  }

  /// Flush buffered tool calls to the UI as loading state.
  /// Called when the coalesce timer fires (tool results didn't arrive in time).
  void _flushToolCoalesce(
    String messageId,
    StreamingState state,
    ChatStreamChunk chunk, {
    required Future<void> Function(String messageId, String json)
    updateReasoningSegmentsInDb,
    required Future<void> Function(
      String messageId,
      List<Map<String, dynamic>> events,
    )
    setToolEventsInDb,
    required List<Map<String, dynamic>> Function(String messageId)
    getToolEventsFromDb,
  }) {
    // Only flush if still pending (not already merged by handleToolResultsChunk)
    if (!_pendingToolCoalesce.containsKey(messageId)) return;
    _pendingToolCoalesce.remove(messageId);
    _toolCoalesceTimers.remove(messageId);

    final conversationId = state.conversationId;
    final existing = List<ToolUIPart>.of(_toolParts[messageId] ?? const []);
    
    // Check if these calls already have results (edge case where results arrived
    // after timer was scheduled but before it fired)
    bool allResolved = true;
    for (final c in chunk.toolCalls!) {
      final hasResult = existing.any((p) =>
        !p.loading &&
        (p.id == c.id || (p.id.isEmpty && p.toolName == c.name)));
      if (!hasResult) {
        allResolved = false;
        existing.add(
          ToolUIPart(
            id: c.id,
            toolName: c.name,
            arguments: c.arguments,
            loading: true,
          ),
        );
      }
    }
    if (allResolved) return; // All already have results, nothing to show

    if (getCurrentConversationId() == conversationId) {
      _toolParts[messageId] = dedupeToolPartsList(existing);
      streamingContentNotifier.notifyToolPartsUpdated(
        messageId,
        contentSplitOffsets: state.contentSplitOffsets,
        reasoningCountAtSplit: state.reasoningCountAtSplit,
        toolCountAtSplit: state.toolCountAtSplit,
      );
    }
  }

  /// Process tool results chunk from stream.
  ///
  /// If there are buffered (coalesced) tool calls, this merges results with them
  /// immediately, skipping the loading flash entirely. If no buffer exists,
  /// falls through to the normal update-by-id path.
  Future<void> handleToolResultsChunk(
    ChatStreamChunk chunk,
    StreamingState state, {
    required Future<void> Function(
      String messageId, {
      required String id,
      required String name,
      required Map<String, dynamic> arguments,
      String? content,
      Map<String, dynamic>? metadata,
    })
    upsertToolEventInDb,
  }) async {
    if ((chunk.toolResults ?? const []).isEmpty) return;

    final messageId = state.messageId;
    final conversationId = state.conversationId;

    // If we have buffered tool calls, merge results directly (skip loading).
    // The buffer is populated by handleToolCallsChunk when using coalesce delay.
    // Cancel the fallback timer first.
    final buffered = _pendingToolCoalesce.remove(messageId);
    _toolCoalesceTimers[messageId]?.cancel();
    _toolCoalesceTimers.remove(messageId);

    if (buffered != null) {
      // Buffered coalesce path: create parts with results directly.
      final parts = List<ToolUIPart>.of(_toolParts[messageId] ?? const []);
      for (final r in chunk.toolResults!) {
        // Check if we already have this result (shouldn't happen, but be safe)
        final existing = parts.any((p) =>
          !p.loading && (p.id == r.id || (p.id.isEmpty && p.toolName == r.name)));
        if (existing) continue;

        parts.add(
          ToolUIPart(
            id: r.id,
            toolName: r.name,
            arguments: r.arguments.isNotEmpty
                ? Map<String, dynamic>.from(r.arguments)
                : r.arguments,
            content: r.content,
            loading: false,
          ),
        );
      }

      try {
        for (final r in chunk.toolResults!) {
          final args = Map<String, dynamic>.from(r.arguments);
          await upsertToolEventInDb(
            messageId,
            id: r.id,
            name: r.name,
            arguments: args,
            content: r.content,
            metadata: r.metadata,
          );
        }
      } catch (_) {}

      if (getCurrentConversationId() == conversationId) {
        _toolParts[messageId] = dedupeToolPartsList(parts);
        final splits = _contentSplits[messageId];
        streamingContentNotifier.notifyToolPartsUpdated(
          messageId,
          contentSplitOffsets: splits?.offsets,
          reasoningCountAtSplit: splits?.reasoningCounts,
          toolCountAtSplit: splits?.toolCounts,
        );
      }
      return;
    }

    // Normal path (no buffered calls): update loading parts by id
    final parts = List<ToolUIPart>.of(_toolParts[messageId] ?? const []);
    for (final r in chunk.toolResults!) {
      int idx = -1;
      for (int i = 0; i < parts.length; i++) {
        if (parts[i].loading &&
            (parts[i].id == r.id ||
                (parts[i].id.isEmpty && parts[i].toolName == r.name))) {
          idx = i;
          break;
        }
      }
      if (idx >= 0) {
        parts[idx] = ToolUIPart(
          id: parts[idx].id,
          toolName: parts[idx].toolName,
          arguments: r.arguments.isNotEmpty
              ? Map<String, dynamic>.from(r.arguments)
              : parts[idx].arguments,
          content: r.content,
          loading: false,
        );
      } else {
        parts.add(
          ToolUIPart(
            id: r.id,
            toolName: r.name,
            arguments: r.arguments,
            content: r.content,
            loading: false,
          ),
        );
      }
      try {
        final args = Map<String, dynamic>.from(r.arguments);
        await upsertToolEventInDb(
          messageId,
          id: r.id,
          name: r.name,
          arguments: args,
          content: r.content,
          metadata: r.metadata,
        );
      } catch (_) {}
    }
    if (getCurrentConversationId() == conversationId) {
      _toolParts[messageId] = dedupeToolPartsList(parts);
      // Notify via StreamingContentNotifier for real-time UI updates
      final splits = _contentSplits[messageId];
      streamingContentNotifier.notifyToolPartsUpdated(
        messageId,
        contentSplitOffsets: splits?.offsets,
        reasoningCountAtSplit: splits?.reasoningCounts,
        toolCountAtSplit: splits?.toolCounts,
      );
    }
  }

  /// Finish reasoning segment when content starts arriving.
  Future<void> finishReasoningOnContent(
    StreamingState state, {
    required Future<void> Function(
      String messageId, {
      String? reasoningText,
      DateTime? reasoningFinishedAt,
      String? reasoningSegmentsJson,
    })
    updateReasoningInDb,
  }) async {
    final messageId = state.messageId;

    final r = _reasoning[messageId];
    if (r != null && r.startAt != null && r.finishedAt == null) {
      r.finishedAt = DateTime.now();
      final autoCollapse = getSettingsProvider().autoCollapseThinking;
      if (autoCollapse) {
        r.expanded = false;
      }
      _reasoning[messageId] = r;
      await updateReasoningInDb(
        messageId,
        reasoningText: r.text,
        reasoningFinishedAt: r.finishedAt,
      );
      _safeNotifyStateChanged();
    }

    final segments = _reasoningSegments[messageId];
    if (segments != null &&
        segments.isNotEmpty &&
        segments.last.finishedAt == null) {
      segments.last.finishedAt = DateTime.now();
      final autoCollapse = getSettingsProvider().autoCollapseThinking;
      if (autoCollapse) {
        segments.last.expanded = false;
      }
      _reasoningSegments[messageId] = segments;
      _safeNotifyStateChanged();
      await updateReasoningInDb(
        messageId,
        reasoningSegmentsJson: serializeReasoningSegmentsWithSplits(
          segments,
          contentSplitOffsets: _contentSplits[messageId]?.offsets,
          reasoningCountAtSplit: _contentSplits[messageId]?.reasoningCounts,
          toolCountAtSplit: _contentSplits[messageId]?.toolCounts,
        ),
      );
    }
  }

  // NOTE: transformAssistantContent is kept in home_page.dart because it uses AssistantRegexScope

  /// Finalize streaming and finish reasoning state.
  Future<void> finalizeReasoningState(
    String messageId, {
    required Future<void> Function(
      String messageId, {
      String? reasoningText,
      DateTime? reasoningFinishedAt,
      String? reasoningSegmentsJson,
    })
    updateReasoningInDb,
  }) async {
    // Finish reasoning data
    final r = _reasoning[messageId];
    if (r != null) {
      r.finishedAt ??= DateTime.now();
      final autoCollapse = getSettingsProvider().autoCollapseThinking;
      if (autoCollapse) {
        r.expanded = false;
      }
      _reasoning[messageId] = r;
      _safeNotifyStateChanged();
    }

    // Also finish any unfinished reasoning segments
    final segments = _reasoningSegments[messageId];
    if (segments != null &&
        segments.isNotEmpty &&
        segments.last.finishedAt == null) {
      segments.last.finishedAt = DateTime.now();
      final autoCollapse = getSettingsProvider().autoCollapseThinking;
      if (autoCollapse) {
        segments.last.expanded = false;
      }
      _reasoningSegments[messageId] = segments;
      _safeNotifyStateChanged();
    }

    // Save reasoning segments to database
    if (segments != null && segments.isNotEmpty) {
      await updateReasoningInDb(
        messageId,
        reasoningSegmentsJson: serializeReasoningSegmentsWithSplits(
          segments,
          contentSplitOffsets: _contentSplits[messageId]?.offsets,
          reasoningCountAtSplit: _contentSplits[messageId]?.reasoningCounts,
          toolCountAtSplit: _contentSplits[messageId]?.toolCounts,
        ),
      );
    }
  }

  /// Check if there are any loading tool parts for a message.
  bool hasLoadingTools(String messageId) {
    return _toolParts[messageId]?.any((p) => p.loading) ?? false;
  }

  // ============================================================================
  // Unified Reasoning Completion
  // ============================================================================

  /// Finishes reasoning for a message if not already finished.
  ///
  /// This is the unified method to handle reasoning completion logic that was
  /// previously duplicated across multiple places in home_page.dart:
  /// - _cancelStreaming (line 597-617)
  /// - _finishReasoningOnContent (line 3738-3770)
  /// - _finishStreaming (line 3886-3917)
  /// - _handleStreamError (line 3954-3970)
  ///
  /// Returns true if any state was actually changed.
  bool finishReasoningIfNeeded(String messageId, {bool forceCollapse = false}) {
    bool changed = false;
    final autoCollapse =
        forceCollapse || getSettingsProvider().autoCollapseThinking;

    // Finish main reasoning data (only when it first finishes, not on subsequent calls)
    final r = _reasoning[messageId];
    if (r != null && r.finishedAt == null) {
      r.finishedAt = DateTime.now();
      if (autoCollapse) {
        r.expanded = false;
      }
      _reasoning[messageId] = r;
      changed = true;
    }
    // NOTE: Removed the "else if" branch that would force collapse on every call.
    // This allows users to expand reasoning during content streaming without it
    // being immediately collapsed again.

    // Finish last reasoning segment (only when it first finishes)
    final segments = _reasoningSegments[messageId];
    if (segments != null && segments.isNotEmpty) {
      final lastSegment = segments.last;
      if (lastSegment.finishedAt == null) {
        lastSegment.finishedAt = DateTime.now();
        if (autoCollapse) {
          lastSegment.expanded = false;
        }
        _reasoningSegments[messageId] = segments;
        changed = true;
      }
      // NOTE: Removed the "else if" branch that would force collapse on every call.
    }

    if (changed) {
      _safeNotifyStateChanged();
    }
    return changed;
  }

  /// Finishes reasoning and persists to database.
  ///
  /// This is a convenience method that combines finishing reasoning state
  /// and persisting it to the database in one call.
  Future<void> finishReasoningAndPersist(
    String messageId, {
    bool forceCollapse = false,
    required Future<void> Function(
      String messageId, {
      String? reasoningText,
      DateTime? reasoningFinishedAt,
      String? reasoningSegmentsJson,
    })
    updateReasoningInDb,
  }) async {
    final changed = finishReasoningIfNeeded(
      messageId,
      forceCollapse: forceCollapse,
    );
    final splits = _contentSplits[messageId];
    final segments =
        _reasoningSegments[messageId] ?? const <ReasoningSegmentData>[];
    if (!changed && splits == null) return;

    // Persist reasoning data
    final r = _reasoning[messageId];
    if (r != null) {
      await updateReasoningInDb(
        messageId,
        reasoningText: r.text,
        reasoningFinishedAt: r.finishedAt,
      );
    }

    // Persist reasoning segments
    if (segments.isNotEmpty || splits != null) {
      await updateReasoningInDb(
        messageId,
        reasoningSegmentsJson: serializeReasoningSegmentsWithSplits(
          segments,
          contentSplitOffsets: splits?.offsets,
          reasoningCountAtSplit: splits?.reasoningCounts,
          toolCountAtSplit: splits?.toolCounts,
        ),
      );
    }
  }

  // ============================================================================
  // Restoration from Database
  // ============================================================================

  /// Restore UI state for a message from its persisted data.
  void restoreMessageUiState(
    ChatMessage message, {
    required List<Map<String, dynamic>> Function(String messageId)
    getToolEventsFromDb,
    required String? Function(String messageId) getGeminiThoughtSigFromDb,
  }) {
    if (message.role != 'assistant') return;

    final messageId = message.id;

    // Restore Gemini thought signature
    final storedSig = getGeminiThoughtSigFromDb(messageId);
    if (storedSig != null && storedSig.isNotEmpty) {
      _geminiThoughtSigs[messageId] = storedSig;
    }

    // Restore reasoning state
    final txt = message.reasoningText ?? '';
    if (txt.isNotEmpty ||
        message.reasoningStartAt != null ||
        message.reasoningFinishedAt != null) {
      final rd = ReasoningData();
      rd.text = txt;
      rd.startAt = message.reasoningStartAt;
      // If finishedAt is null but startAt exists, the stream was interrupted
      // (e.g. app force-quit mid-reasoning); treat reasoning as finished to
      // avoid an infinite timer.
      rd.finishedAt = message.reasoningFinishedAt ?? message.reasoningStartAt;
      rd.expanded = false;
      _reasoning[messageId] = rd;
    }

    // Restore tool events
    try {
      final events = dedupeToolEvents(getToolEventsFromDb(messageId));
      if (events.isNotEmpty) {
        _toolParts[messageId] = events
            .map(
              (e) => ToolUIPart(
                id: (e['id'] ?? '').toString(),
                toolName: (e['name'] ?? '').toString(),
                arguments:
                    (e['arguments'] as Map?)?.cast<String, dynamic>() ??
                    const <String, dynamic>{},
                content: (e['content']?.toString().isNotEmpty == true)
                    ? e['content'].toString()
                    : null,
                loading: !(e['content']?.toString().isNotEmpty == true),
              ),
            )
            .toList();
      }
    } catch (_) {}

    // Restore reasoning segments
    final segments = deserializeReasoningSegments(
      message.reasoningSegmentsJson,
    );
    if (segments.isNotEmpty) {
      _reasoningSegments[messageId] = segments;
    }
    final contentSplits = deserializeContentSplits(
      message.reasoningSegmentsJson,
    );
    if (contentSplits != null) {
      _contentSplits[messageId] = contentSplits;
    }
  }

  // ============================================================================
  // Disposal
  // ============================================================================

  /// Dispose of all resources.
  void dispose() {
    _cancelAllTimers();
    streamingContentNotifier.dispose();
  }
}

// ============================================================================
// Data Classes
// ============================================================================

/// Context object for message generation.
class GenerationContext {
  GenerationContext({
    required this.assistantMessage,
    required this.apiMessages,
    required this.userImagePaths,
    required this.allowImagesApiRouting,
    required this.providerKey,
    required this.modelId,
    required this.assistant,
    required this.settings,
    required this.config,
    required this.toolDefs,
    this.onToolCall,
    this.extraHeaders,
    this.extraBody,
    required this.supportsReasoning,
    required this.enableReasoning,
    required this.streamOutput,
    this.ocrActive = false,
    this.generateTitleOnFinish = true,
  });

  final ChatMessage assistantMessage;
  final List<Map<String, dynamic>> apiMessages;
  final List<String> userImagePaths;
  final bool allowImagesApiRouting;
  final String providerKey;
  final String modelId;
  final dynamic assistant;
  final SettingsProvider settings;
  final ProviderConfig config;
  final List<Map<String, dynamic>> toolDefs;
  final ToolCallHandler? onToolCall;
  final Map<String, String>? extraHeaders;
  final Map<String, dynamic>? extraBody;
  final bool supportsReasoning;
  final bool enableReasoning;
  final bool streamOutput;
  final bool ocrActive;
  final bool generateTitleOnFinish;
}

/// State object for streaming message generation.
class StreamingState {
  StreamingState(this.ctx) : fullContentRaw = ctx.assistantMessage.content;

  final GenerationContext ctx;
  String fullContentRaw;
  int totalTokens = 0;
  TokenUsage? usage;
  String bufferedReasoning = '';
  DateTime? reasoningStartAt;
  bool finishHandled = false;
  bool titleQueued = false;
  DateTime? streamStartedAt;
  bool hadThinkingBlock = false;
  List<int> contentSplitOffsets = <int>[];
  List<int> reasoningCountAtSplit = <int>[];
  List<int> toolCountAtSplit = <int>[];

  String get messageId => ctx.assistantMessage.id;
  String get conversationId => ctx.assistantMessage.conversationId;
}

/// Reasoning data for an assistant message.
class ReasoningData {
  String text = '';
  DateTime? startAt;
  DateTime? finishedAt;
  bool expanded = false;
}

/// Reasoning segment data (for interleaved thinking/tool display).
class ReasoningSegmentData {
  String text = '';
  DateTime? startAt;
  DateTime? finishedAt;
  bool expanded = true;
  int toolStartIndex = 0;
}

class ContentSplitData {
  const ContentSplitData({
    required this.offsets,
    required this.reasoningCounts,
    required this.toolCounts,
  });

  final List<int> offsets;
  final List<int> reasoningCounts;
  final List<int> toolCounts;
}


/// Pending tool call coalesce buffer entry.
/// Holds buffered tool calls that have not yet been shown to the UI.
class _PendingToolCoalesce {
  final List<ToolCallInfo> calls;

  /// The ChatStreamChunk data that arrived via handleToolCallsChunk.
  /// We need the state fields (contentSplitOffsets etc.) when we flush.
  ChatStreamChunk? chunk;

  StreamingState? state;

  _PendingToolCoalesce({required this.calls, this.chunk, this.state});
}

class _StreamSmoothState {
  String conversationId = '';
  String targetContent = '';
  String visibleContent = '';
  int totalTokens = 0;
  List<int>? contentSplitOffsets;
  List<int>? reasoningCountAtSplit;
  List<int>? toolCountAtSplit;
  int? promptTokens;
  int? completionTokens;
  int? cachedTokens;
  int? durationMs;
  void Function(String messageId, String content, int totalTokens)?
  updateMessageInList;
  final List<int> _recentPickCounts = <int>[];

  String? takeNextContentSlice({
    required int minCount,
    required int baseCount,
    required int maxCount,
    required double pickRate,
    required int moveAverageLength,
  }) {
    if (targetContent == visibleContent) return null;
    if (!targetContent.startsWith(visibleContent)) {
      visibleContent = targetContent;
      _recentPickCounts.clear();
      return visibleContent;
    }

    final backlog = targetContent.length - visibleContent.length;
    if (backlog <= 0) return null;
    final pickCount = _nextPickCount(
      backlog: backlog,
      minCount: minCount,
      baseCount: baseCount,
      maxCount: maxCount,
      pickRate: pickRate,
      moveAverageLength: moveAverageLength,
    );
    final nextLength = math.min(
      targetContent.length,
      visibleContent.length + pickCount,
    );
    visibleContent = targetContent.substring(0, nextLength);
    return visibleContent;
  }

  String? flushTargetContent() {
    if (targetContent == visibleContent) return null;
    visibleContent = targetContent;
    _recentPickCounts.clear();
    return visibleContent;
  }

  int _nextPickCount({
    required int backlog,
    required int minCount,
    required int baseCount,
    required int maxCount,
    required double pickRate,
    required int moveAverageLength,
  }) {
    if (backlog <= minCount) return backlog;

    final rawPick = _rawPickCount(
      backlog: backlog,
      minCount: minCount,
      baseCount: baseCount,
      maxCount: maxCount,
      pickRate: pickRate,
    );
    _recentPickCounts.add(rawPick);
    if (_recentPickCounts.length > moveAverageLength) {
      _recentPickCounts.removeAt(0);
    }

    final average =
        _recentPickCounts.reduce((a, b) => a + b) / _recentPickCounts.length;
    return average.round().clamp(minCount, backlog).toInt();
  }

  int _rawPickCount({
    required int backlog,
    required int minCount,
    required int baseCount,
    required int maxCount,
    required double pickRate,
  }) {
    if (backlog <= minCount) return backlog;

    double effectivePickRate;
    if (backlog < baseCount) {
      effectivePickRate = pickRate * backlog / baseCount;
    } else if (backlog >= maxCount) {
      effectivePickRate = math.max((backlog - baseCount) / backlog, pickRate);
    } else {
      final t = (backlog - baseCount) / (maxCount - baseCount);
      effectivePickRate = pickRate + (0.5 - pickRate) * t;
    }

    return math.max(minCount, (backlog * effectivePickRate).round());
  }
}
