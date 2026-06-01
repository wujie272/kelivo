import 'dart:async';
import 'package:flutter/foundation.dart';

/// Possible outcomes of a tool approval request.
enum ToolApprovalAction { approved, denied, answered }

/// Result of a tool approval request.
class ToolApprovalResult {
  final ToolApprovalAction action;
  final String? message; // denyReason for denied, answer text for answered

  bool get approved => action == ToolApprovalAction.approved;
  bool get denied => action == ToolApprovalAction.denied;
  bool get answered => action == ToolApprovalAction.answered;
  String? get denyReason => denied ? message : null;
  String? get answerText => answered ? message : null;

  const ToolApprovalResult._({
    required this.action,
    this.message,
  });

  factory ToolApprovalResult.approved() =>
      const ToolApprovalResult._(action: ToolApprovalAction.approved);
  factory ToolApprovalResult.denied([String? reason]) =>
      ToolApprovalResult._(action: ToolApprovalAction.denied, message: reason);
  factory ToolApprovalResult.answered(String answer) =>
      ToolApprovalResult._(action: ToolApprovalAction.answered, message: answer);
}

/// A pending approval request for an MCP tool call.
class ToolApprovalRequest {
  final String toolCallId;
  final String toolName;
  final Map<String, dynamic> arguments;
  final Completer<ToolApprovalResult> _completer;

  ToolApprovalRequest({
    required this.toolCallId,
    required this.toolName,
    required this.arguments,
    required this._completer,
  });
}

/// Manages approval state for MCP tool calls that require user confirmation.
///
/// Flow:
/// 1. [requestApproval] is called from the tool handler when a tool needs approval.
///    It creates a [Completer], stores the request in [pendingRequests], and returns
///    the completer's future. The tool handler `await`s this future, blocking execution.
/// 2. The UI watches this service and shows approve/deny buttons.
/// 3. When the user taps approve/deny, [approve] or [deny] completes the completer,
///    unblocking the tool handler.
class ToolApprovalService extends ChangeNotifier {
  final Map<String, ToolApprovalRequest> _pending = {};

  /// Unmodifiable view of pending approval requests.
  Map<String, ToolApprovalRequest> get pendingRequests =>
      Map.unmodifiable(_pending);

  /// Whether there are any pending approval requests.
  bool get hasPending => _pending.isNotEmpty;

  /// Check if a specific tool call is pending approval.
  bool isPending(String toolCallId) => _pending.containsKey(toolCallId);

  /// Request approval for a tool call.
  /// Returns a [Future] that completes when the user approves or denies.
  Future<ToolApprovalResult> requestApproval({
    required String toolCallId,
    required String toolName,
    required Map<String, dynamic> arguments,
  }) {
    final completer = Completer<ToolApprovalResult>();
    _pending[toolCallId] = ToolApprovalRequest(
      toolCallId: toolCallId,
      toolName: toolName,
      arguments: arguments,
      completer: completer,
    );
    notifyListeners();
    return completer.future;
  }

  /// Approve a pending tool call.
  void approve(String toolCallId) {
    final req = _pending.remove(toolCallId);
    if (req != null && !req._completer.isCompleted) {
      req._completer.complete(ToolApprovalResult.approved());
    }
    notifyListeners();
  }

  /// Deny a pending tool call with an optional reason.
  void deny(String toolCallId, [String? reason]) {
    final req = _pending.remove(toolCallId);
    if (req != null && !req._completer.isCompleted) {
      req._completer.complete(ToolApprovalResult.denied(reason));
    }
    notifyListeners();
  }

  /// Cancel all pending approvals (e.g., when streaming is cancelled).
  void cancelAll() {
    for (final req in _pending.values) {
      if (!req._completer.isCompleted) {
        req._completer.complete(ToolApprovalResult.denied('cancelled'));
      }
    }
    _pending.clear();
    notifyListeners();
  }
}
