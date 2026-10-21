// Feedback for a parse that was started while the Parse tab is not visible
// (e.g. from the clipboard dialog shown over the History or Mine tab). The
// Parse tab has its own inline progress and error card; these snackbars cover
// the other tabs.

import 'package:flutter/material.dart';

import '../core/error_copy.dart';

/// Persistent "解析中…" snackbar with a cancel action. Close it through the
/// returned controller once the parse finished.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showParsingSnackBar(
  BuildContext context, {
  required VoidCallback onCancel,
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  return messenger.showSnackBar(
    SnackBar(
      duration: const Duration(minutes: 5),
      content: const Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          ),
          SizedBox(width: 12),
          Expanded(child: Text('解析中…')),
        ],
      ),
      action: SnackBarAction(label: '取消', onPressed: onCancel),
    ),
  );
}

/// Error snackbar for a failed parse; [onView] opens the Parse tab, where the
/// full error card (login / retry actions) is shown.
void showParseErrorSnackBar(
  BuildContext context, {
  required String code,
  String? message,
  required VoidCallback onView,
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 8),
      content: Text(displayErrorMessage(code, message)),
      action: SnackBarAction(label: '查看', onPressed: onView),
    ),
  );
}
