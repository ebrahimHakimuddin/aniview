part of '../player.dart';

/// The desktop player's controls: a title bar along the top and, along the bottom, the seek bar over one row of
/// controls (play, volume, skip, and each choice a drop-down: subtitles, server, quality, speed). They come up when
/// the pointer moves and stay while it's over them; the keyboard and wheel (see [_onDesktopKey], [_pointer]) work
/// without them.
extension _DeskPlayer on _PlayerScreenState {
  Widget _deskOverlay(Duration position, bool loading) => Column(
    children: [
      _overBar(
        DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xCC000000), Color(0x00000000)],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back  (Esc)',
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: () => Navigator.pop(context),
                ),
                const SizedBox(width: 8),
                Expanded(child: _titles(tv: false)),
                if (_episodes.length > 1)
                  IconButton(
                    tooltip: 'Episodes',
                    icon: const Icon(Icons.video_library_outlined),
                    onPressed: _openEpisodes,
                  ),
              ],
            ),
          ),
        ),
      ),
      const Spacer(),
      _overBar(
        DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x00000000), Color(0xE6000000)],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _timeline(position),
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Previous episode',
                      onPressed: index > 0 ? () => _load(index - 1) : null,
                      icon: const Icon(Icons.skip_previous_rounded),
                    ),
                    IconButton(
                      tooltip: player.state.playing
                          ? 'Pause  (Space)'
                          : 'Play  (Space)',
                      iconSize: 36,
                      onPressed: loading ? null : _click,
                      icon: Icon(
                        player.state.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Next episode  (N)',
                      onPressed: hasNext ? () => _load(index + 1) : null,
                      icon: const Icon(Icons.skip_next_rounded),
                    ),
                    const SizedBox(width: 8),
                    _volumeControl(),
                    const SizedBox(width: 12),
                    _skipButton(position),
                    const Spacer(),
                    if (_hasSubtitles) _subtitleMenu(),
                    if (streams.length > 1 && streams.contains(current))
                      _serverMenu(),
                    if (_qualities.length > 1) _qualityMenu(),
                    _speedMenu(),
                    _fitButton(),
                    IconButton(
                      tooltip: 'Open in another app',
                      icon: const Icon(Icons.open_in_new_rounded),
                      onPressed: current == null ? null : _openExternal,
                    ),
                    IconButton(
                      tooltip: 'Fullscreen  (F)',
                      icon: const Icon(Icons.fullscreen_rounded),
                      onPressed: _toggleFullscreen,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );

  /// [bar] keeps the controls up while the pointer rests on it.
  Widget _overBar(Widget bar) => MouseRegion(
    onEnter: (_) => _overControls = true,
    onExit: (_) {
      _overControls = false;
      _scheduleHide();
    },
    child: bar,
  );

  Widget _volumeControl() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: volume == 0 ? 'Unmute  (M)' : 'Mute  (M)',
        icon: Icon(
          volume == 0
              ? Icons.volume_off_rounded
              : volume < .5
              ? Icons.volume_down_rounded
              : Icons.volume_up_rounded,
        ),
        onPressed: () {
          if (volume > 0) _beforeMute = volume;
          _setVolume(volume > 0 ? 0 : _beforeMute);
        },
      ),
      SizedBox(
        width: 96,
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbColor: Colors.white,
            activeTrackColor: Colors.white,
            inactiveTrackColor: Colors.white24,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
          ),
          child: Slider(
            value: volume,
            onChanged: (v) {
              _set(() => volume = v);
              player.setVolume(v).ignore();
            },
          ),
        ),
      ),
    ],
  );

  /// A drop-down of [options] over an [icon], [selected] ticked.
  Widget _choiceMenu<T>({
    required String tooltip,
    required IconData icon,
    required Map<T, String> options,
    required T selected,
    required ValueChanged<T> onSelected,
  }) => PopupMenuButton<T>(
    tooltip: tooltip,
    icon: Icon(icon),
    onSelected: onSelected,
    itemBuilder: (_) => [
      for (final MapEntry(:key, :value) in options.entries)
        CheckedPopupMenuItem<T>(
          value: key,
          checked: key == selected,
          child: Text(value),
        ),
    ],
  );

  Widget _subtitleMenu() {
    final external = current?.subtitles ?? const <Subtitle>[];
    final embedded = player.state.subtitles
        .where(
          (t) =>
              t.id != 'auto' &&
              t.id != 'no' &&
              !external.any((s) => s.label == t.title),
        )
        .toList();
    String name(SubtitleTrack t) => t.title ?? t.language ?? 'Track ${t.id}';
    final options = <Object, String>{
      'off': 'Off',
      for (final s in external) s: s.label,
      for (final t in embedded) t: name(t),
    };
    final selected =
        options.entries.where((e) => e.value == subtitle).firstOrNull?.key ??
        'off';
    return _choiceMenu<Object>(
      tooltip: 'Subtitles · $subtitle',
      icon: subtitle == 'Off'
          ? Icons.subtitles_off_outlined
          : Icons.subtitles_outlined,
      options: options,
      selected: selected,
      onSelected: (picked) async {
        switch (picked) {
          case Subtitle s:
            await _setExternal(current!, s);
          case SubtitleTrack t:
            await _setSubtitle(t, name(t));
          case 'off':
            await _setSubtitle(SubtitleTrack.off, 'Off');
        }
      },
    );
  }

  Widget _serverMenu() => _choiceMenu<VideoStream>(
    tooltip: 'Server · ${current!.label}',
    icon: Icons.dns_outlined,
    options: {for (final s in streams) s: s.label},
    selected: current!,
    onSelected: (s) {
      if (s != current) _play(s, at: player.state.position);
    },
  );

  Widget _qualityMenu() => _choiceMenu<int>(
    tooltip: 'Quality · $_qualityLabel',
    icon: Icons.high_quality_rounded,
    options: {0: 'Auto', for (final h in _qualities) h: '${h}p'},
    selected: quality,
    onSelected: (q) {
      _set(() => quality = q);
      player.setQuality(q == 0 ? Settings.streamQuality : q, exact: q != 0);
    },
  );

  Widget _speedMenu() => _choiceMenu<double>(
    tooltip: 'Speed · $rate×  ( [ and ] )',
    icon: Icons.speed_rounded,
    options: {for (final r in _PlayerScreenState._speeds) r: '$r×'},
    selected: rate,
    onSelected: (r) {
      _set(() => rate = r);
      player.setRate(r);
    },
  );
}
