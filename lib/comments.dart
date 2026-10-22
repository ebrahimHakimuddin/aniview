import 'package:flutter/material.dart';

import 'analytics.dart';
import 'anilist.dart';
import 'dantotsu.dart';
import 'settings.dart';
import 'social.dart';
import 'sources.dart';
import 'states.dart';
import 'tracker.dart';
import 'ui.dart';

/// Opens [media]'s Dantotsu comments, on [episode] alone when given; one past [progress] warns of spoilers first.
Future<void> openComments(
  BuildContext context,
  Map media, {
  num? episode,
  required int progress,
}) async {
  if (!Show(media).onAniList) {
    return showError(context, "AniList doesn't have this show");
  }
  if (episode != null &&
      episode > progress &&
      !await confirmDestructive(
        context,
        title: 'Spoilers ahead',
        message:
            "You haven't watched Episode ${epNumber(episode)} yet, and its comments talk about what happens.",
        action: 'Open anyway',
      )) {
    return;
  }
  if (!context.mounted) return;
  await pushSettled(
    context,
    MaterialPageRoute<void>(
      builder: (_) =>
          CommentsScreen(media, episode: episode, progress: progress),
    ),
  );
}

/// A show's comments on Dantotsu, shared with the other apps that use it: an episode's, or all of them. Read,
/// vote, reply, post (after agreeing to its rules), delete your own and report the rest. The episode's AniList
/// discussion is a button away.
class CommentsScreen extends StatefulWidget {
  const CommentsScreen(
    this.media, {
    super.key,
    this.episode,
    required this.progress,
  });

  final Map media;
  final num? episode;
  final int progress;

  @override
  State<CommentsScreen> createState() => _CommentsScreenState();
}

class _CommentsScreenState extends State<CommentsScreen> {
  final comments = <Map>[];
  final input = TextEditingController();
  int page = 0, pages = 1;
  bool loading = false, sending = false, newest = false;
  Object? error;
  String? postError;

  /// The comment being replied to; null posts on the show (or episode).
  Map? replyTo;

  /// Replies shown under their comment, by its id.
  final replies = <int, List<Map>>{};

  int get id => widget.media['id'];
  num? get episode => widget.episode;

  @override
  void initState() {
    super.initState();
    Analytics.screen('/comments', title: 'Comments');
    if (Tracker.anilistSignedIn) _load();
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  bool get more => page < pages;

  Future<void> _load() async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final (list, total) = await Dantotsu.comments(
        id,
        page + 1,
        episode: episode,
        newest: newest,
      );
      if (!mounted) return;
      setState(() {
        comments.addAll(list);
        page++;
        // An empty page is the end, whatever the count said.
        pages = list.isEmpty ? page : total;
      });
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _reload() {
    setState(() {
      comments.clear();
      replies.clear();
      page = 0;
      pages = 1;
    });
    _load();
  }

  Future<void> _showReplies(Map c) async {
    final cid = c['comment_id'] as int;
    if (replies.containsKey(cid)) return setState(() => replies.remove(cid));
    try {
      final all = <Map>[];
      // ponytail: the first 5 pages of replies; a longer thread wants its own paging
      for (var p = 1; p <= 5; p++) {
        final (list, total) = await Dantotsu.replies(cid, p);
        all.addAll(list);
        if (list.isEmpty || p >= total) break;
      }
      if (mounted) setState(() => replies[cid] = all);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Agreeing to Dantotsu's rules, once, before the first post.
  Future<bool> _agreeToRules() async {
    if (Settings.dantotsuRulesAccepted) return true;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => PanelDialog(
        title: const Text('Comment rules'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Dantotsu comments are shared with other apps and moderated. Breaking a rule removes the comment; '
                'serious or repeated breaks ban the account.',
              ),
              const SizedBox(height: 12),
              for (final (i, rule) in Dantotsu.rules.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('${i + 1}. $rule'),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('I agree'),
          ),
        ],
      ),
    );
    if (agreed == true) Settings.dantotsuRulesAccepted = true;
    return agreed == true;
  }

  Future<void> _send() async {
    final text = input.text.trim();
    if (text.isEmpty || sending || !await _agreeToRules() || !mounted) return;
    setState(() {
      sending = true;
      postError = null;
    });
    try {
      final parent = replyTo;
      await Dantotsu.post(
        id,
        text,
        episode: episode,
        parent: parent?['comment_id'] as int?,
      );
      if (!mounted) return;
      setState(() {
        replyTo = null;
        input.clear();
      });
      FocusScope.of(context).unfocus();
      showSuccess(context, 'Comment posted');
      // Shown where you'll see it: under its comment, or the list again from the top.
      if (parent != null) {
        parent['reply_count'] = (parent['reply_count'] as int? ?? 0) + 1;
        replies.remove(parent['comment_id']);
        await _showReplies(parent);
      } else {
        if (!newest) setState(() => newest = true);
        _reload();
      }
    } catch (e) {
      if (mounted) setState(() => postError = friendlyError(e));
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  /// Up (1) or down (-1); the same again takes the vote back.
  Future<void> _vote(Map c, int type) async {
    final before = c['user_vote_type'] as int? ?? 0;
    final after = before == type ? 0 : type;
    try {
      await Dantotsu.vote(c['comment_id'], after);
      if (!mounted) return;
      setState(() {
        if (before == 1) c['upvotes'] = (c['upvotes'] as int? ?? 1) - 1;
        if (before == -1) c['downvotes'] = (c['downvotes'] as int? ?? 1) - 1;
        if (after == 1) c['upvotes'] = (c['upvotes'] as int? ?? 0) + 1;
        if (after == -1) c['downvotes'] = (c['downvotes'] as int? ?? 0) + 1;
        c['user_vote_type'] = after;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _delete(Map c) async {
    if (!await confirmDestructive(
      context,
      title: 'Delete this comment?',
      message: 'It shows as [deleted] for everyone.',
      action: 'Delete',
    )) {
      return;
    }
    try {
      await Dantotsu.delete(c['comment_id']);
      if (mounted) {
        setState(() {
          c['deleted'] = 1;
          c['content'] = '[deleted]';
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _report(Map c) async {
    if (!await confirmDestructive(
      context,
      title: 'Report this comment?',
      message: "Dantotsu's moderators check it against the comment rules.",
      action: 'Report',
    )) {
      return;
    }
    try {
      await Dantotsu.report(c, titleOf(widget.media));
      if (mounted) showSuccess(context, 'Reported');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = Tracker.anilistSignedIn;
    final ep = episode;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          ep == null ? 'Comments' : 'Episode ${epNumber(ep)} comments',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        titleSpacing: side,
        actions: [
          if (signedIn)
            TextButton.icon(
              onPressed: () {
                setState(() => newest = !newest);
                _reload();
              },
              icon: const Icon(Icons.sort_rounded, size: 18),
              label: Text(newest ? 'Newest' : 'Top'),
            ),
          if (ep != null)
            IconButton(
              tooltip: 'AniList discussion',
              icon: const Icon(Icons.forum_outlined),
              onPressed: () => openEpisodeDiscussion(
                context,
                widget.media,
                ep,
                progress: widget.progress,
              ),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: !signedIn
          ? const EmptyState(
              icon: Icons.forum_outlined,
              title: 'Sign in with AniList to see comments',
              message: 'Comments come from Dantotsu, shared with other anime apps, and use your AniList account.',
            )
          : Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    padding: EdgeInsets.fromLTRB(side, 0, side, 24),
                    itemCount: comments.length + 1,
                    itemBuilder: (context, i) => i < comments.length
                        ? _comment(comments[i], reply: false)
                        : _footer(),
                  ),
                ),
                _composer(),
              ],
            ),
    );
  }

  Widget _footer() {
    if (error != null) {
      return ErrorState(error!, compact: true, onRetry: _load);
    }
    if (more) {
      // Reaching the end loads the next page.
      if (!loading) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _load());
      }
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (comments.isEmpty) {
      return EmptyState(
        icon: Icons.forum_outlined,
        title: 'No comments yet',
        message: episode == null
            ? 'Be the first to say something about it.'
            : 'Be the first to say something about this episode.',
        compact: true,
      );
    }
    return const SizedBox.shrink();
  }

  Widget _comment(Map c, {required bool reply}) {
    final text = Theme.of(context).textTheme;
    final avatar = c['profile_picture_url'] as String?;
    final deleted = c['deleted'] == 1;
    final vote = c['user_vote_type'] as int? ?? 0;
    final cid = c['comment_id'] as int;
    final shown = replies[cid];
    final count = c['reply_count'] as int? ?? 0;
    final at = DateTime.tryParse('${c['timestamp']}');
    final staff = c['is_admin'] == 1
        ? 'Admin'
        : c['is_mod'] == 1
        ? 'Mod'
        : null;
    Widget voteButton(int type, IconData icon, IconData picked, int votes) =>
        TextButton.icon(
          onPressed: deleted ? null : () => _vote(c, type),
          style: TextButton.styleFrom(
            foregroundColor: vote == type
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
          icon: Icon(vote == type ? picked : icon, size: 18),
          label: Text('$votes'),
        );
    return Container(
      margin: EdgeInsets.only(left: reply ? 8 : 0),
      padding: EdgeInsets.only(left: reply ? 12 : 0, top: 12),
      decoration: reply
          ? BoxDecoration(
              border: Border(
                left: BorderSide(color: scheme.outlineVariant, width: 2),
              ),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: scheme.surfaceContainerHighest,
                backgroundImage: avatar == null ? null : NetworkImage(avatar),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '${c['username'] ?? c['user']?['username'] ?? 'Someone'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall,
                ),
              ),
              if (staff != null)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(
                    staff,
                    style: text.labelSmall?.copyWith(color: scheme.primary),
                  ),
                ),
              Text(
                [
                  if (at != null)
                    ' · ${since(at.millisecondsSinceEpoch ~/ 1000)}',
                  if (episode == null && c['tag'] != null) ' · EP ${c['tag']}',
                ].join(),
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const Spacer(),
              if (!deleted)
                PopupMenuButton<VoidCallback>(
                  tooltip: 'More',
                  iconSize: 18,
                  iconColor: scheme.onSurfaceVariant,
                  onSelected: (run) => run(),
                  itemBuilder: (_) => [
                    if (Dantotsu.isMine(c))
                      PopupMenuItem(
                        value: () => _delete(c),
                        child: const Text('Delete'),
                      )
                    else
                      PopupMenuItem(
                        value: () => _report(c),
                        child: const Text('Report'),
                      ),
                  ],
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: deleted
                ? Text(
                    '[deleted]',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  )
                : CommentText(c['content'] as String? ?? ''),
          ),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              voteButton(
                1,
                Icons.thumb_up_outlined,
                Icons.thumb_up_rounded,
                c['upvotes'] as int? ?? 0,
              ),
              voteButton(
                -1,
                Icons.thumb_down_outlined,
                Icons.thumb_down_rounded,
                c['downvotes'] as int? ?? 0,
              ),
              if (!reply && !deleted)
                TextButton(
                  onPressed: () => setState(() => replyTo = c),
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.onSurfaceVariant,
                  ),
                  child: const Text('Reply'),
                ),
              if (!reply && count > 0)
                TextButton(
                  onPressed: () => _showReplies(c),
                  child: Text(
                    shown != null
                        ? 'Hide replies'
                        : '$count ${count == 1 ? 'reply' : 'replies'}',
                  ),
                ),
            ],
          ),
          for (final r in shown ?? const <Map>[]) _comment(r, reply: true),
        ],
      ),
    );
  }

  Widget _composer() => Material(
    color: scheme.surfaceContainer,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(side, 8, side - 4, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (replyTo case final parent?)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Replying to ${parent['username'] ?? 'comment'}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Cancel reply',
                    onPressed: () => setState(() => replyTo = null),
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                ],
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: input,
                    minLines: 1,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) => setState(() => postError = null),
                    decoration: InputDecoration(
                      hintText: replyTo != null
                          ? 'Write a reply'
                          : episode == null
                          ? 'Add a comment'
                          : 'Comment on Episode ${epNumber(episode!)}',
                      helperText: 'Spoilers go in ||spoiler tags||',
                      errorText: postError,
                      errorMaxLines: 3,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Post',
                  onPressed: sending || input.text.trim().isEmpty
                      ? null
                      : _send,
                  icon: sending
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
