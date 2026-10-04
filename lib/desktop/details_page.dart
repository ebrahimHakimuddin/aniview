part of '../details.dart';

/// The desktop's page for a show: a banner across the top with the poster over it and what you do with the show
/// beside that (play, your list, more), then the show's own details down the left and its episodes filling the rest.
/// Episodes are wide rows with their still, play on hover, and a right click for the rest; Ctrl+click picks several.
/// An episode row's height, 4 apart: fixed, so a jump can scroll to any of them without building those between.
const _deskRowExtent = 137.0;

extension _DeskDetails on _DetailsScreenState {
  Widget _deskBuild() {
    final text = Theme.of(context).textTheme;
    return PopScope(
      canPop: !picked.active,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) picked.clear();
      },
      child: Scaffold(
        bottomNavigationBar: picked.active
            ? Padding(
                padding: const EdgeInsets.fromLTRB(
                  deskMargin,
                  8,
                  deskMargin,
                  12,
                ),
                child: _pickedActions(),
              )
            : null,
        body: LayoutBuilder(
          builder: (context, box) {
            // The page keeps to a readable width and centres in a very wide window; in a narrow one the show's
            // details sit above the episodes instead of beside them.
            final inset = ((box.maxWidth - 1400) / 2).clamp(
              deskMargin,
              double.infinity,
            );
            final narrow = box.maxWidth < 880;
            return CustomScrollView(
              controller: scroll,
              slivers: [
                SliverToBoxAdapter(child: _deskHero(text, inset)),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 24, inset, 48),
                  sliver: narrow
                      ? SliverMainAxisGroup(
                          slivers: [
                            SliverToBoxAdapter(child: _deskSide(text)),
                            const SliverToBoxAdapter(
                              child: SizedBox(height: 24),
                            ),
                            _tabBar(text),
                            _tabContent(),
                          ],
                        )
                      : SliverCrossAxisGroup(
                          slivers: [
                            SliverConstrainedCrossAxis(
                              maxExtent: 320,
                              sliver: SliverToBoxAdapter(
                                child: _deskSide(text),
                              ),
                            ),
                            const SliverConstrainedCrossAxis(
                              maxExtent: 32,
                              sliver: SliverToBoxAdapter(
                                child: SizedBox(width: 32),
                              ),
                            ),
                            SliverCrossAxisExpanded(
                              flex: 1,
                              sliver: SliverMainAxisGroup(
                                slivers: [_tabBar(text), _tabContent()],
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ───────────────────────────── The banner ─────────────────────────────

  Widget _deskHero(TextTheme text, double inset) {
    final airing = airingLabel(media);
    final score = show.score;
    // The banner follows the window, so a short one still has room for episodes under it.
    final hero = (MediaQuery.sizeOf(context).height * .44).clamp(310.0, 420.0);
    final posterHeight = hero - 100;
    return SizedBox(
      height: hero,
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: hero - 80,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Artwork(
                  show.backdrop,
                  color: show.color,
                  alignment: Alignment.topCenter,
                  full: true,
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        scheme.surface.withValues(alpha: .25),
                        scheme.surface.withValues(alpha: .55),
                        scheme.surface,
                      ],
                      stops: const [0, .55, 1],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: inset,
            right: inset,
            bottom: 0,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 24,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: SizedBox(
                      width: posterHeight * 2 / 3,
                      height: posterHeight,
                      child: Artwork(show.cover, color: show.color),
                    ),
                  ),
                ),
                const SizedBox(width: 28),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_eyebrow case final eyebrow?) Eyebrow(eyebrow),
                        const SizedBox(height: 8),
                        Text(
                          titleOf(media),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: text.headlineMedium?.copyWith(
                            fontSize: 36,
                            height: 1.05,
                            letterSpacing: -.8,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (score != null) Pill.score(score),
                            if (airing != null)
                              Pill(
                                'Next $airing',
                                icon: Icons.schedule_rounded,
                              ),
                            Text(
                              [
                                mediaMeta(media, genres: 0),
                                (media['status'] as String?)
                                    ?.replaceAll('_', ' ')
                                    .toLowerCase(),
                              ].whereType<String>().join(' · '),
                              style: text.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        if (show.genres.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final genre in show.genres.take(6))
                                _genre('$genre'),
                            ],
                          ),
                        ],
                        const SizedBox(height: 18),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            SizedBox(width: 300, child: _playAction()),
                            _deskListButton(),
                            _deskMore(),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Your list: its status as a button that opens the choices, and the entry's progress to edit.
  Widget _deskListButton() {
    if (!Tracker.signedIn) return const SizedBox.shrink();
    return PopupMenuButton<String>(
      tooltip: 'Your list',
      onSelected: (v) async {
        switch (v) {
          case '_edit':
            await _editEntry();
          case '_remove':
            try {
              await Tracker.removeFromList(media);
              _set(() {});
            } catch (e) {
              if (mounted) showError(context, e);
            }
          default:
            await setListStatus(
              context,
              media,
              v,
              onChanged: () => _set(() {}),
            );
        }
      },
      itemBuilder: (_) => [
        ...statusItems(media),
        const PopupMenuDivider(),
        const PopupMenuItem(value: '_edit', child: Text('Edit progress…')),
        if (show.inList)
          const PopupMenuItem(
            value: '_remove',
            child: Text('Remove from list'),
          ),
      ],
      child: Container(
        height: buttonHeight,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outline),
          borderRadius: BorderRadius.circular(buttonRadius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              show.inList
                  ? Icons.bookmark_added_rounded
                  : Icons.bookmark_add_outlined,
              size: 20,
              color: scheme.primary,
            ),
            const SizedBox(width: 8),
            Text(
              show.inList
                  ? ListStatus.labels[show.listStatus] ?? 'On your list'
                  : 'Add to list',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const Icon(Icons.arrow_drop_down_rounded),
          ],
        ),
      ),
    );
  }

  /// More: play on the TV, download episodes, mark the season watched, fix the site's match.
  Widget _deskMore() => ValueListenableBuilder(
    valueListenable: TvRemote.connected,
    builder: (context, tvConnected, _) => FutureBuilder(
      future: episodes,
      builder: (context, snap) {
        final list = snap.data, site = source;
        final has = list != null && list.isNotEmpty;
        final items = <(String, IconData, VoidCallback)>[
          if (tvConnected && show.onAniList)
            ('Play on ${TvRemote.name ?? 'TV'}', Icons.cast_rounded, _playOnTv),
          if (has && site != null)
            (
              'Download episodes…',
              Icons.download_rounded,
              () => _downloadSeason(site, list, _progress),
            ),
          if (has && Tracker.signedIn)
            (
              'Mark season watched',
              Icons.done_all_rounded,
              () => _markWatched(EpisodePlan.progressAfter(list)),
            ),
          if (site != null)
            ('Wrong show? Pick it', Icons.swap_horiz_rounded, _fixMatch),
        ];
        if (items.isEmpty) return const SizedBox.shrink();
        return PopupMenuButton<int>(
          tooltip: 'More',
          icon: const Icon(Icons.more_vert_rounded),
          onSelected: (i) => items[i].$3(),
          itemBuilder: (_) => [
            for (final (i, (label, icon, _)) in items.indexed)
              PopupMenuItem(
                value: i,
                child: Row(
                  children: [
                    Icon(icon, size: 20, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 12),
                    Text(label),
                  ],
                ),
              ),
          ],
        );
      },
    ),
  );

  // ───────────────────────────── The side ─────────────────────────────

  Widget _deskSide(TextTheme text) {
    final description = plainText(show.description);
    final season = media['season'] as String?;
    final facts = <(String, String)>[
      if (media['format'] case final String f)
        ('Format', f.replaceAll('_', ' ')),
      if (show.episodes ?? show.aired case final n?) ('Episodes', '$n'),
      if (media['status'] case final String s)
        ('Status', s.replaceAll('_', ' ').toLowerCase()),
      if (season != null)
        (
          'Season',
          '${season[0]}${season.substring(1).toLowerCase()} ${media['seasonYear'] ?? ''}'
              .trim(),
        ),
      if (show.score != null) ('Score', '${show.score}%'),
    ];
    Widget heading(String title) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(title, style: text.titleMedium),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (Tracker.signedIn) ...[
          _ListEntry(
            progress: _progress,
            total: show.episodes,
            status: show.listStatus,
            onTap: _editEntry,
          ),
          const SizedBox(height: 24),
        ],
        if (description.isNotEmpty) ...[
          heading('About'),
          _about(description),
          const SizedBox(height: 24),
        ],
        if (facts.isNotEmpty) ...[
          heading('Details'),
          for (final (label, value) in facts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: text.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(value, style: text.bodyMedium),
                ],
              ),
            ),
          const SizedBox(height: 24),
        ],
        FutureBuilder(
          future: relations,
          builder: (context, snap) {
            final found = snap.data ?? const <(String, Map)>[];
            if (found.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                heading('Related'),
                for (final (type, related) in found)
                  Hover(
                    pressScale: .98,
                    onTap: () => openDetails(context, related),
                    builder: (context, hovered) => Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: hovered
                            ? scheme.onSurface.withValues(alpha: .06)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: SizedBox(
                              width: 40,
                              height: 60,
                              child: Artwork(
                                Show(related).cover,
                                color: Show(related).color,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  titleOf(related),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  type == 'PREQUEL' ? 'Prequel' : 'Sequel',
                                  style: text.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  // ───────────────────────────── Episodes ─────────────────────────────

  /// [site] is null offline, when only downloaded episodes play.
  Widget _deskEpisodeSliver(List<Episode> list, Source? site) {
    final playable = EpisodePlan.playable(
      list,
      online: site != null,
      downloaded: (e) =>
          Downloads.instance.toPlay(media, e.number, dub: dub, online: false) !=
          null,
    );
    return FutureBuilder(
      future: record,
      builder: (context, saved) {
        final plan = EpisodePlan(
          list,
          progress: _progress,
          record: saved.data,
          newestFirst: _newestFirst(saved.data),
          page: page,
          pageSize: _DetailsScreenState._pageSize,
        );
        return SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: _episodeControls(
                list,
                plan,
                // Long shows get a box to go straight to an episode.
                extra: list.length > 12 ? _jumpBox(list, plan) : null,
              ),
            ),
            SliverToBoxAdapter(child: SizedBox(key: listAnchor)),
            SliverFixedExtentList.builder(
              itemExtent: _deskRowExtent,
              itemCount: plan.shown.length,
              itemBuilder: (context, i) =>
                  _deskEpisode(plan.shown[i], plan, list, playable, site),
            ),
          ],
        );
      },
    );
  }

  Widget _deskEpisode(
    Episode episode,
    EpisodePlan plan,
    List<Episode> list,
    List<Episode> playable,
    Source? site,
  ) {
    final text = Theme.of(context).textTheme;
    final watched = plan.watched(episode);
    final saved = site != null || playable.contains(episode);
    final upNext = episode == plan.upNext;
    final part = plan.resumedPart(episode);
    final picking = picked.active;
    final isPicked = picking && picked.has(episode);
    final download = Downloads.instance.entry(media, episode.number, dub);

    Future<void> play() async {
      if (!saved) {
        showError(
          context,
          "Episode ${epNumber(episode.number)} isn't downloaded",
        );
        return;
      }
      final start = EpisodePlan.startAt(
        episode,
        playable,
        site: site?.name,
        downloadedFrom: Downloads.instance.forMedia(media).firstOrNull?.source,
      );
      await _openPlayer(
        context,
        media: media,
        source: site,
        sourceName: start.sourceName,
        episodes: playable,
        index: start.index,
        dub: dub,
      );
      _reloadRecord(); // progress and resume point changed
    }

    Future<void> menu(Offset at) async {
      final choice = await showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
        items: [
          const PopupMenuItem(value: 'play', child: Text('Play')),
          if (Tracker.signedIn)
            PopupMenuItem(
              value: 'watched',
              child: Text(
                watched ? 'Mark as unwatched' : 'Mark watched up to here',
              ),
            ),
          if (site != null && download == null)
            PopupMenuItem(
              value: 'download',
              child: Text('Download ${dub ? 'dub' : 'sub'}'),
            ),
          if (download?.status == DownloadStatus.done)
            const PopupMenuItem(
              value: 'delete',
              child: Text('Delete download'),
            ),
          if (show.onAniList)
            const PopupMenuItem(value: 'discuss', child: Text('Discussion')),
          const PopupMenuItem(value: 'select', child: Text('Select')),
        ],
      );
      if (!mounted) return;
      switch (choice) {
        case 'play':
          await play();
        case 'watched':
          await _markWatched(
            watched
                ? EpisodePlan.progressUnwatching(episode)
                : EpisodePlan.progressWatching(episode),
          );
        case 'download':
          Downloads.instance.enqueue(
            media,
            site!.name,
            [episode],
            dub: dub,
            season: list,
          );
        case 'delete':
          await confirmDeleteDownload(context, download!);
        case 'discuss':
          await openEpisodeDiscussion(
            context,
            media,
            episode.number,
            progress: _progress,
          );
        case 'select':
          _togglePick(episode);
      }
    }

    final tile = _EpisodeTile(
      episode,
      watched: watched,
      upNext: upNext,
      resumedPart: part,
      onTap: () {},
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Hover(
        pressScale: .99,
        onTap: () {
          if (picking || HardwareKeyboard.instance.isControlPressed) {
            _togglePick(episode);
          } else {
            play();
          }
        },
        onSecondary: menu,
        builder: (context, hovered) => AnimatedContainer(
          duration: motionMs(context, 120),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isPicked || episode.number == highlight
                ? scheme.primary.withValues(alpha: .14)
                : hovered
                ? scheme.onSurface.withValues(alpha: .06)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 208,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        tile._still(context),
                        AnimatedOpacity(
                          opacity: hovered && !picking ? 1 : 0,
                          duration: motionMs(context, 120),
                          child: const ColoredBox(
                            color: Color(0x66000000),
                            child: Center(
                              child: CircleAvatar(
                                radius: 22,
                                backgroundColor: Colors.white,
                                child: Icon(
                                  Icons.play_arrow_rounded,
                                  color: Colors.black,
                                  size: 30,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (picking)
                          Positioned(
                            top: 8,
                            left: 8,
                            child: Icon(
                              isPicked
                                  ? Icons.check_circle_rounded
                                  : Icons.radio_button_unchecked_rounded,
                              color: isPicked ? scheme.primary : Colors.white,
                              shadows: const [Shadow(blurRadius: 6)],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              'Episode ${epNumber(episode.number)}',
                              style: text.titleSmall?.copyWith(
                                color: watched
                                    ? scheme.onSurfaceVariant
                                    : scheme.onSurface,
                              ),
                            ),
                          ),
                          if (tile._badge case final badge?) ...[
                            const SizedBox(width: 8),
                            Text(
                              badge.toUpperCase(),
                              style: text.labelSmall?.copyWith(
                                color: scheme.primary,
                                letterSpacing: .8,
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (episode.title != null)
                        Text(
                          episode.title!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      if (episode.overview != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            episode.overview!,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant.withValues(
                                alpha: .8,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // Always there, so the row doesn't shift as the pointer moves across it.
              if (!picking)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (Tracker.signedIn)
                      IconButton(
                        tooltip: watched
                            ? 'Mark as unwatched'
                            : 'Mark watched up to here',
                        color: watched
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                        onPressed: () => _markWatched(
                          watched
                              ? EpisodePlan.progressUnwatching(episode)
                              : EpisodePlan.progressWatching(episode),
                        ),
                        icon: Icon(
                          watched
                              ? Icons.check_circle_rounded
                              : Icons.check_circle_outline_rounded,
                        ),
                      ),
                    if (show.onAniList)
                      IconButton(
                        tooltip: 'Episode discussion',
                        color: scheme.onSurfaceVariant,
                        onPressed: () => openEpisodeDiscussion(
                          context,
                          media,
                          episode.number,
                          progress: _progress,
                        ),
                        icon: const Icon(Icons.forum_outlined),
                      ),
                    if (site != null)
                      _DownloadButton(
                        media: media,
                        source: site,
                        episode: episode,
                        season: list,
                        dub: dub,
                      )
                    else if (saved)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Icon(
                          Icons.download_done_rounded,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// A box for an episode number: shows the page that holds it and scrolls to it, lit for a moment.
  Widget _jumpBox(List<Episode> list, EpisodePlan plan) => SizedBox(
    width: 168,
    height: 40,
    child: TextField(
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
      textInputAction: TextInputAction.go,
      onSubmitted: (text) => _jumpTo(text, list, plan),
      style: Theme.of(context).textTheme.bodyMedium,
      decoration: InputDecoration(
        hintText: 'Go to episode',
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 0),
        prefixIcon: const Icon(Icons.tag_rounded, size: 18),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide.none,
        ),
      ),
    ),
  );

  void _jumpTo(String text, List<Episode> list, EpisodePlan plan) {
    final ascending = [...list]..sort((a, b) => a.number.compareTo(b.number));
    final at = EpisodePlan.indexOfNumber(ascending, text);
    if (at == null) return;
    final target = ascending[at];
    final pageOf = plan.pages.indexWhere((p) => p.contains(target));
    if (pageOf == -1) return;
    final row = plan.pages[pageOf].indexOf(target);
    _highlightTimer?.cancel();
    _set(() {
      page = pageOf;
      highlight = target.number;
    });
    _highlightTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) _set(() => highlight = null);
    });
    // Once the page is showing: the rows start at the marker, each a fixed height.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final anchor = listAnchor.currentContext?.findRenderObject();
      if (anchor == null || !scroll.hasClients) return;
      final start = RenderAbstractViewport.of(anchor)
          .getOffsetToReveal(anchor, 0)
          .offset;
      scroll.animateTo(
        (start + row * _deskRowExtent - 80).clamp(
          0.0,
          scroll.position.maxScrollExtent,
        ),
        duration: const Duration(milliseconds: 300),
        curve: deskEaseInOut,
      );
    });
  }
}
