import 'package:flutter/material.dart';

import 'analytics.dart';
import 'anilist.dart';
import 'sources.dart';
import 'states.dart';
import 'tracker.dart';
import 'ui.dart';

/// AniList's social side on a show's page (phones): its forum threads, each episode's discussion, and where the
/// people you follow are with it.

/// The episodes a discussion thread's title covers: "Episode 5 Discussion" is (5, 5), "Premiere/Episodes 1-4"
/// is (1, 4); null when it names none.
(num, num)? episodesIn(String title) {
  final m = RegExp(
    r'episodes?\s*(\d+(?:\.\d+)?)(?:\s*[-–~]\s*(\d+(?:\.\d+)?))?',
    caseSensitive: false,
  ).firstMatch(title);
  if (m == null) return null;
  final from = num.parse(m[1]!);
  return (from, m[2] == null ? from : num.parse(m[2]!));
}

/// The thread among [threads] that discusses [episode], or null.
Map? threadForEpisode(List threads, num episode) =>
    threads.cast<Map>().where((t) {
      final range = episodesIn(t['title'] as String);
      return range != null && range.$1 <= episode && episode <= range.$2;
    }).firstOrNull;

/// Opens [episode]'s AniList discussion, after a spoiler warning when it's past [progress].
Future<void> openEpisodeDiscussion(
  BuildContext context,
  Map media,
  num episode, {
  required int progress,
}) async {
  final id = media['id'];
  if (id is! int) return showError(context, "AniList doesn't have this show");
  try {
    final thread = threadForEpisode(await AniList.releaseThreads(id), episode);
    if (!context.mounted) return;
    if (thread == null) {
      return showError(
        context,
        'No discussion for Episode ${epNumber(episode)} on AniList',
      );
    }
    await openThread(context, thread, spoilersPast: progress);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Opens [thread]; an episode discussion past [spoilersPast] episodes asks first.
Future<void> openThread(
  BuildContext context,
  Map thread, {
  int? spoilersPast,
}) async {
  final range = episodesIn(thread['title'] as String);
  if (spoilersPast != null &&
      range != null &&
      range.$2 > spoilersPast &&
      !await confirmDestructive(
        context,
        title: 'Spoilers ahead',
        message:
            "You haven't watched Episode ${epNumber(range.$2)} yet, and its discussion talks about what happens.",
        action: 'Open anyway',
      )) {
    return;
  }
  if (!context.mounted) return;
  await pushSettled(
    context,
    MaterialPageRoute<void>(builder: (_) => ThreadScreen(thread)),
  );
}

/// "5m", "3h", "2d", "4mo" or "1y" since a unix time.
String _since(int? at) {
  if (at == null) return '';
  final d = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch(at * 1000),
  );
  return d.inMinutes < 60
      ? '${d.inMinutes}m'
      : d.inHours < 24
      ? '${d.inHours}h'
      : d.inDays < 30
      ? '${d.inDays}d'
      : d.inDays < 365
      ? '${d.inDays ~/ 30}mo'
      : '${d.inDays ~/ 365}y';
}

/// A thread title without the "[Spoilers]" tag every episode discussion carries.
String threadTitle(Map thread) => (thread['title'] as String)
    .replaceFirst(RegExp(r'^\s*\[spoilers?\]\s*', caseSensitive: false), '')
    .trim();

/// A thread's comments, oldest first with replies nested, loading more as you scroll; signed in, you can like,
/// reply and post.
class ThreadScreen extends StatefulWidget {
  const ThreadScreen(this.thread, {super.key});

  final Map thread;

  @override
  State<ThreadScreen> createState() => _ThreadScreenState();
}

class _ThreadScreenState extends State<ThreadScreen> {
  final comments = <Map>[];
  final input = TextEditingController();
  int page = 0;
  bool more = true, loading = false, sending = false;
  Object? error;

  /// The comment being replied to; null posts to the thread.
  Map? replyTo;

  int get id => widget.thread['id'];

  @override
  void initState() {
    super.initState();
    Analytics.screen('/thread', title: 'Discussion');
    _load();
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final (list, next) = await AniList.threadComments(id, page + 1);
      if (!mounted) return;
      setState(() {
        comments.addAll(list.cast<Map>());
        page++;
        more = next;
      });
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _send() async {
    final text = input.text.trim();
    if (text.isEmpty || sending) return;
    setState(() => sending = true);
    try {
      final posted = await AniList.postComment(
        id,
        text,
        parent: replyTo?['id'] as int?,
      );
      if (!mounted) return;
      // Shown where you'll see it: under its comment, or at the top.
      setState(() {
        if (replyTo case final parent?) {
          (parent['childComments'] ??= []).add(posted);
        } else {
          comments.insert(0, posted);
        }
        replyTo = null;
        input.clear();
      });
      FocusScope.of(context).unfocus();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> _like(Map comment) async {
    try {
      final liked = await AniList.toggleCommentLike(comment['id']);
      if (mounted) setState(() => comment.addAll(liked));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = Tracker.signedIn;
    return Scaffold(
      appBar: AppBar(
        title: Text(threadTitle(widget.thread), maxLines: 2),
        titleTextStyle: Theme.of(context).textTheme.titleMedium,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.fromLTRB(
                side,
                0,
                side,
                24 + (signedIn ? 0 : MediaQuery.paddingOf(context).bottom),
              ),
              itemCount: comments.length + 1,
              itemBuilder: (context, i) =>
                  i < comments.length ? _comment(comments[i], 0) : _footer(),
            ),
          ),
          if (signedIn) _composer(),
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
      return const EmptyState(
        icon: Icons.forum_outlined,
        title: 'No comments yet',
        compact: true,
      );
    }
    return const SizedBox.shrink();
  }

  /// A comment, its like and reply buttons, and its replies indented under it (up to four deep).
  Widget _comment(Map c, int depth) {
    final text = Theme.of(context).textTheme;
    final user = c['user'] as Map?;
    final avatar = user?['avatar']?['medium'] as String?;
    final replies = (c['childComments'] as List?)?.cast<Map>() ?? const [];
    final indent = depth > 0 && depth <= 4;
    final liked = c['isLiked'] == true;
    final signedIn = Tracker.signedIn;
    return Container(
      margin: EdgeInsets.only(left: indent ? 8 : 0),
      padding: EdgeInsets.only(left: indent ? 12 : 0, top: 12),
      decoration: indent
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
                  user?['name'] as String? ?? 'Someone',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall,
                ),
              ),
              Text(
                ' · ${_since(c['createdAt'] as int?)}',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: CommentText(c['comment'] as String? ?? ''),
          ),
          Row(
            children: [
              TextButton.icon(
                onPressed: signedIn ? () => _like(c) : null,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: liked
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
                icon: Icon(
                  liked
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  size: 18,
                ),
                label: Text('${c['likeCount'] ?? 0}'),
              ),
              if (signedIn)
                TextButton(
                  onPressed: () => setState(() => replyTo = c),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: scheme.onSurfaceVariant,
                  ),
                  child: const Text('Reply'),
                ),
            ],
          ),
          for (final r in replies) _comment(r, depth + 1),
        ],
      ),
    );
  }

  Widget _composer() => Material(
    color: scheme.surfaceContainer,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (replyTo case final parent?)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Replying to ${parent['user']?['name'] ?? 'comment'}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Cancel reply',
                    visualDensity: VisualDensity.compact,
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
                    decoration: const InputDecoration(
                      hintText: 'Add a comment',
                      border: InputBorder.none,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Post',
                  onPressed: sending ? null : _send,
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

/// A comment's AniList markdown as readable text: spoilers hidden until the text is tapped, images and videos as
/// a placeholder, and formatting marks and HTML dropped.
// ponytail: plain text, so links and images aren't tappable; render AniList markdown properly if people miss them
class CommentText extends StatefulWidget {
  const CommentText(this.source, {super.key});

  final String source;

  @override
  State<CommentText> createState() => _CommentTextState();
}

class _CommentTextState extends State<CommentText> {
  bool revealed = false;

  static final _spoiler = RegExp(r'~!([\s\S]*?)!~');

  /// [source] with its markup reduced to plain text.
  static String clean(String source) => source
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll(
        RegExp(r'img\d*%?\s*\(([^)]*)\)', caseSensitive: false),
        '[image]',
      )
      .replaceAll(
        RegExp(r'(webm|youtube|video)\s*\(([^)]*)\)', caseSensitive: false),
        '[video]',
      )
      .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!)
      .replaceAll(RegExp(r'~~~|\*\*|__|~~'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    final source = widget.source;
    final spoilers = _spoiler.hasMatch(source);
    final spans = <InlineSpan>[];
    var at = 0;
    for (final m in _spoiler.allMatches(source)) {
      spans.add(TextSpan(text: clean(source.substring(at, m.start))));
      final hidden = clean(m[1]!);
      spans.add(
        TextSpan(
          text: revealed ? hidden : ' Spoiler · tap to show ',
          style: TextStyle(
            backgroundColor: scheme.surfaceContainerHighest,
            color: revealed ? null : scheme.onSurfaceVariant,
            fontStyle: revealed ? null : FontStyle.italic,
          ),
        ),
      );
      at = m.end;
    }
    spans.add(TextSpan(text: clean(source.substring(at))));
    final body = Text.rich(TextSpan(children: spans), style: style);
    return !spoilers || revealed
        ? body
        : GestureDetector(
            onTap: () => setState(() => revealed = true),
            child: body,
          );
  }
}

/// The Discussion tab: the show's AniList threads, most recently active first.
class DiscussionList extends StatefulWidget {
  const DiscussionList(this.media, {super.key, required this.progress});

  final Map media;

  /// Episodes watched, for the spoiler warning on later episode discussions.
  final int progress;

  @override
  State<DiscussionList> createState() => _DiscussionListState();
}

class _DiscussionListState extends State<DiscussionList> {
  late Future<List> threads = AniList.threads(widget.media['id']);

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: threads,
    builder: (context, snap) {
      if (snap.hasError) {
        return SliverToBoxAdapter(
          child: ErrorState(
            snap.error!,
            compact: true,
            onRetry: () =>
                setState(() => threads = AniList.threads(widget.media['id'])),
          ),
        );
      }
      if (!snap.hasData) {
        return const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          ),
        );
      }
      final list = snap.data!.cast<Map>();
      if (list.isEmpty) {
        return const SliverToBoxAdapter(
          child: EmptyState(
            icon: Icons.forum_outlined,
            title: 'No discussions on AniList yet',
            compact: true,
          ),
        );
      }
      final text = Theme.of(context).textTheme;
      return SliverList.builder(
        itemCount: list.length,
        itemBuilder: (context, i) {
          final t = list[i];
          final episode = episodesIn(t['title'] as String) != null;
          return ListTile(
            contentPadding: EdgeInsets.symmetric(horizontal: side),
            leading: Icon(
              episode ? Icons.live_tv_rounded : Icons.forum_outlined,
              color: scheme.onSurfaceVariant,
            ),
            title: Text(threadTitle(t), maxLines: 2),
            subtitle: Text(
              '${t['replyCount'] ?? 0} replies · active ${_since(t['repliedAt'] as int?)} ago',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            onTap: () => openThread(context, t, spoilersPast: widget.progress),
          );
        },
      );
    },
  );
}

/// The Friends tab: the people you follow who have this show on their list, with their status, progress and
/// score.
class FriendsList extends StatefulWidget {
  const FriendsList(this.media, {super.key});

  final Map media;

  @override
  State<FriendsList> createState() => _FriendsListState();
}

class _FriendsListState extends State<FriendsList> {
  late Future<List> entries = AniList.following(widget.media['id']);

  static const _statuses = {
    'CURRENT': 'Watching',
    'REPEATING': 'Rewatching',
    'PLANNING': 'Planning',
    'COMPLETED': 'Completed',
    'PAUSED': 'Paused',
    'DROPPED': 'Dropped',
  };

  @override
  Widget build(BuildContext context) {
    if (!Tracker.signedIn) {
      return const SliverToBoxAdapter(
        child: EmptyState(
          icon: Icons.people_outline_rounded,
          title: 'Sign in with AniList',
          message: 'See where the people you follow are with this show.',
          compact: true,
        ),
      );
    }
    return FutureBuilder(
      future: entries,
      builder: (context, snap) {
        if (snap.hasError) {
          return SliverToBoxAdapter(
            child: ErrorState(
              snap.error!,
              compact: true,
              onRetry: () => setState(
                () => entries = AniList.following(widget.media['id']),
              ),
            ),
          );
        }
        if (!snap.hasData) {
          return const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }
        final list = snap.data!.cast<Map>();
        if (list.isEmpty) {
          return const SliverToBoxAdapter(
            child: EmptyState(
              icon: Icons.people_outline_rounded,
              title: 'No one you follow has this on their list',
              compact: true,
            ),
          );
        }
        final text = Theme.of(context).textTheme;
        return SliverList.builder(
          itemCount: list.length,
          itemBuilder: (context, i) {
            final e = list[i];
            final user = e['user'] as Map;
            final avatar = user['avatar']?['medium'] as String?;
            final status = e['status'] as String?;
            final progress = e['progress'] as int? ?? 0;
            final score = (e['score'] as num?) ?? 0;
            return ListTile(
              contentPadding: EdgeInsets.symmetric(horizontal: side),
              leading: CircleAvatar(
                backgroundColor: scheme.surfaceContainerHighest,
                backgroundImage: avatar == null ? null : NetworkImage(avatar),
              ),
              title: Text(user['name'] as String? ?? 'Someone'),
              subtitle: Text(
                [
                  _statuses[status] ?? 'On their list',
                  if (progress > 0 && status != 'COMPLETED') 'EP $progress',
                  _since(e['updatedAt'] as int?),
                ].where((s) => s.isNotEmpty).join(' · '),
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              trailing: score > 0
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.star_rounded,
                          size: 18,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 4),
                        Text('$score', style: text.titleSmall),
                      ],
                    )
                  : null,
            );
          },
        );
      },
    );
  }
}
