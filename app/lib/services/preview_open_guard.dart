// One place that answers "what should happen when the app is asked to open
// this link?" — shared by every entry that can end up pushing a preview page.
//
// The decision used to live inside ParsePage._resolve, so any entry that
// reached the preview page another way (batch list, and earlier the floating
// bubble's "打开 EasySave") skipped the rule entirely and pushed a second
// preview. Keeping it here means the rule and its DevLog line exist exactly
// once, and every caller passes the entry name it came from.

import 'dart:async';

import '../core/dev_log.dart';
import 'clipboard_guard.dart';
import 'history_db.dart';
import 'links.dart';
import 'preview_route_observer.dart';

/// What an "open this link" request should do.
enum PreviewOpenAction {
  /// The top page already is this post's preview page: do nothing.
  skipAlreadyOnPreview,

  /// The post is in history: open the cached preview without a network call.
  openCached,

  /// Not on screen and not in history: run a fresh parse.
  parseFresh,
}

/// Result of [PreviewOpenGuard.decide], including everything the DevLog line
/// and the caller need.
class PreviewOpenDecision {
  const PreviewOpenDecision({
    required this.entry,
    required this.normalizedLink,
    required this.action,
    this.postId,
    this.currentPreviewPostId,
    this.resolvedUrl,
    this.cachedRecord,
  });

  /// Entry point name (bubble / share / clipboard / input / paste / batch ...).
  final String entry;

  /// Link as handed in, trimmed.
  final String normalizedLink;

  /// Post identity derived from the link (or its short-link target).
  final String? postId;

  /// Post id of the page currently on top, when it is a preview page.
  final String? currentPreviewPostId;

  /// Target of a resolved short link, when one was needed.
  final String? resolvedUrl;

  final PreviewOpenAction action;

  /// History record to show for [PreviewOpenAction.openCached].
  final HistoryRecord? cachedRecord;

  @override
  String toString() =>
      'PreviewOpenDecision(entry=$entry, action=${action.name}, postId=$postId, '
      'topPreview=$currentPreviewPostId, historyId=${cachedRecord?.id})';
}

abstract final class PreviewOpenGuard {
  /// DevLog tag: `adb logcat | findstr PREVIEW` shows the whole decision path.
  static const String logTag = 'PREVIEW';

  /// True when the top page is the preview page of [postId].
  static bool isTopPreview(String? postId) {
    if (postId == null || postId.isEmpty) return false;
    final top = PreviewRouteObserver.instance.topPreviewPostId;
    return top != null && top.toLowerCase() == postId.toLowerCase();
  }

  /// Decide what to do for [link], and log entry + link + result.
  ///
  /// [entry] is the human-readable entry point name; [resolvedUrl] can be
  /// supplied by callers that already resolved a short link. When the link has
  /// no post id of its own (xhslink.com/...), one resolving request is made so
  /// the "already on this preview" rule also works for shared short links.
  static Future<PreviewOpenDecision> decide({
    required String entry,
    required String link,
    String? resolvedUrl,
    HistoryDb? db,
    bool resolveShortLinks = true,
  }) async {
    final normalized = link.trim();
    var postId = postIdOfUrl(normalized);
    var resolved = resolvedUrl;
    if (postId == null && resolveShortLinks && normalized.isNotEmpty) {
      try {
        resolved ??= await resolveShortLink(normalized);
        postId = postIdOfUrl(resolved);
      } catch (_) {
        // Offline or not a short link: fall through to link matching.
      }
    }

    final top = PreviewRouteObserver.instance.topPreviewPostId;

    PreviewOpenDecision finish(
      PreviewOpenAction action, {
      HistoryRecord? cached,
    }) {
      final decision = PreviewOpenDecision(
        entry: entry,
        normalizedLink: normalized,
        action: action,
        postId: postId,
        currentPreviewPostId: top,
        resolvedUrl: resolved,
        cachedRecord: cached,
      );
      // Info level: release builds keep it (debug lines are dropped).
      unawaited(DevLog.write(logTag, '$decision'));
      return decision;
    }

    if (postId != null && top != null && postId.toLowerCase() == top.toLowerCase()) {
      return finish(PreviewOpenAction.skipAlreadyOnPreview);
    }

    final store = db ?? await HistoryDb.instance();
    final cached = await store.findRecordByLink(normalized, resolvedUrl: resolved);

    return finish(
      cached == null ? PreviewOpenAction.parseFresh : PreviewOpenAction.openCached,
      cached: cached,
    );
  }
}
