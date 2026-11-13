part of '../settings.dart';

const _randomFrom = {'planning': 'Planning list', 'everything': 'Anything'};

const _holdGestures = {
  'speed': 'Play at 2×',
  'pause': 'Pause until released',
  'off': 'Do nothing',
};

const _qualities = {0: 'Best', 1080: '1080p', 720: '720p', 480: '480p'};

const subtitleLanguages = [
  'Off',
  'English',
  'Spanish',
  'Portuguese',
  'French',
  'German',
  'Italian',
  'Arabic',
  'Russian',
];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    Analytics.screen('/settings', title: 'Settings');
  }

  Future<void> _choose<T>(
    String title,
    Map<T, String> options,
    T current,
    void Function(T) apply,
  ) async {
    final picked = await pickOne(context, title, options, current);
    if (picked != null) setState(() => apply(picked));
  }

  Future<void> _pickTheme() async {
    // Your colors only where Android has a wallpaper palette to give.
    // Following the system, only the twins for its current mode are offered; picking one still covers both.
    final mode = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final themes = [
      for (final choice in ThemeSelection.values)
        if ((!choice.dynamic || systemAccent != null) &&
            (!Settings.followSystemTheme ||
                choice == ThemeSelection.custom ||
                choice.brightness == mode))
          choice,
    ];
    final picked = await showSheet<ThemeSelection>(
      context,
      height: .72,
      (sheet) => SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            sheetTitle(sheet, 'Choose a theme'),
            Expanded(
              child: ListView.builder(
                itemCount: themes.length,
                itemBuilder: (context, index) {
                  final choice = themes[index];
                  final colors = themeScheme(choice);
                  final selected = choice == Settings.activeTheme;
                  return ScrollIntoViewOnFocus(
                    child: ListTile(
                      autofocus: selected,
                      selected: selected,
                      leading: SizedBox(
                        width: 48,
                        height: 48,
                        child: Stack(
                          children: [
                            Positioned(
                              left: 1,
                              top: 1,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: colors.surface,
                                  border: Border.all(color: colors.outline),
                                ),
                                child: const SizedBox.square(dimension: 34),
                              ),
                            ),
                            Positioned(
                              right: 1,
                              bottom: 1,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: colors.primary,
                                ),
                                child: const SizedBox.square(dimension: 26),
                              ),
                            ),
                          ],
                        ),
                      ),
                      title: Text(choice.label),
                      subtitle: Text(choice.description),
                      trailing: selected
                          ? const Icon(Icons.check_circle_rounded)
                          : null,
                      onTap: () => Navigator.pop(sheet, choice),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (!mounted || picked == null || picked == Settings.themeSelection) return;
    setState(() => Settings.themeSelection = picked);
    themeGeneration.value++;
  }

  /// Desktop: keep the downloads in [folder] (the app's own when null), and say why when that can't be done.
  Future<void> _moveDownloads(String? folder) async {
    try {
      if (Downloads.instance.storageError != null) {
        await Downloads.instance.recoverTo(folder);
      } else {
        await Downloads.instance.moveTo(folder);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() {});
  }

  Future<bool> _confirm(String title, String message, String action) =>
      confirmDestructive(
        context,
        title: title,
        message: message,
        action: action,
      );

  Future<void> _signIn(ListProvider provider) async {
    try {
      final name = await Tracker.signIn(context, provider);
      if (mounted && name != null) showSuccess(context, 'Signed in as $name');
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() {});
  }

  Future<void> _jellyfinSignIn() async {
    final server = TextEditingController(text: Settings.jellyfinServer);
    final name = TextEditingController(text: Settings.jellyfinUserName);
    final password = TextEditingController();
    final how = await showDialog<String>(
      context: context,
      builder: (context) => PanelDialog(
        title: const Text('Connect to Jellyfin'),
        content: AutofillGroup(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: server,
                autofocus: true,
                keyboardType: TextInputType.url,
                autofillHints: const [AutofillHints.url],
                decoration: const InputDecoration(
                  labelText: 'Server address',
                  hintText: 'http://192.168.1.10:8096',
                ),
              ),
              TextField(
                controller: name,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(labelText: 'Username'),
              ),
              TextField(
                controller: password,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                decoration: const InputDecoration(labelText: 'Password'),
                onSubmitted: (_) => Navigator.pop(context, 'password'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          // No typing a password with a remote: approve this device from a Jellyfin app already signed in.
          TextButton(
            onPressed: () => Navigator.pop(context, 'quick'),
            child: const Text('Quick Connect'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'password'),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    if (how == null) return;
    try {
      if (how == 'quick') {
        if (!await _quickConnect(server.text)) return;
      } else {
        await Jellyfin.signIn(server.text, name.text, password.text);
      }
      Sites.reload();
      if (mounted) {
        showSuccess(context, 'Connected as ${Settings.jellyfinUserName}');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() {});
  }

  Future<void> _jellyseerrSignIn() async {
    final server = TextEditingController(text: Settings.jellyseerrServer);
    final name = TextEditingController(text: Settings.jellyfinUserName);
    final password = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => PanelDialog(
        title: const Text('Connect to Jellyseerr'),
        content: AutofillGroup(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: server,
                autofocus: true,
                keyboardType: TextInputType.url,
                autofillHints: const [AutofillHints.url],
                decoration: const InputDecoration(
                  labelText: 'Jellyseerr address',
                  hintText: 'http://192.168.1.10:5055',
                ),
              ),
              TextField(
                controller: name,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(
                  labelText: 'Jellyfin username',
                ),
              ),
              TextField(
                controller: password,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                decoration: const InputDecoration(
                  labelText: 'Jellyfin password',
                ),
                onSubmitted: (_) => Navigator.pop(context, true),
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
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    if (go != true) return;
    try {
      await Jellyseerr.signIn(server.text, name.text, password.text);
      if (mounted) showSuccess(context, 'Connected to Jellyseerr');
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() {});
  }

  /// Shows Quick Connect's code until it's approved (true) or the dialog is closed (false).
  Future<bool> _quickConnect(String server) async {
    final code = ValueNotifier<String?>(null);
    var open = true;
    final dialog = showDialog<void>(
      context: context,
      builder: (context) => PanelDialog(
        title: const Text('Quick Connect'),
        content: ValueListenableBuilder(
          valueListenable: code,
          builder: (context, value, _) => value == null
              ? const LinearProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'In a Jellyfin app you\'re signed in to, open Quick Connect and enter this code',
                    ),
                    const SizedBox(height: 16),
                    Text(
                      value,
                      style: Theme.of(context).textTheme.displaySmall
                          ?.copyWith(letterSpacing: 8),
                    ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    ).whenComplete(() => open = false);
    try {
      return await Jellyfin.quickConnect(
        server,
        showCode: (value) => code.value = value,
        cancelled: () => !open,
      );
    } finally {
      if (open && mounted) Navigator.pop(context);
      await dialog;
      code.dispose();
    }
  }

  Future<void> _signOut(ListProvider provider) async {
    await Tracker.signOut(provider);
    if (!mounted) return;
    setState(() {});
    showSuccess(context, 'Signed out of ${provider.name}');
  }

  int _page = 0;

  /// Desktop: the groups down the left, the one you picked filling the right, so no scrolling past the rest.
  Widget _desktop(List<Widget> sections) {
    final text = Theme.of(context).textTheme;
    final groups = [
      for (final w in sections)
        if (w is _Group) w,
    ];
    // The account, then each group; a page is picked by its place.
    final titles = ['Account', for (final g in groups) g.title];
    final page = _page.clamp(0, titles.length - 1);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 240,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 28, 12, 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                child: Text('Settings', style: text.headlineMedium),
              ),
              for (final (i, title) in titles.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: ListTile(
                    dense: true,
                    selected: i == page,
                    selectedTileColor: scheme.primary.withValues(alpha: .16),
                    selectedColor: scheme.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    title: Text(title),
                    onTap: () => setState(() => _page = i),
                  ),
                ),
            ],
          ),
        ),
        VerticalDivider(width: 1, color: hairline),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(32, 8, 32, 48),
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: page == 0 ? sections.first : groups[page - 1],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final sections = <Widget>[
      Column(
        children: [
          for (final p in [Tracker.anilist, Tracker.mal])
            if (p.usable)
              _Account(
                provider: p,
                other: Tracker.account == p ? null : Tracker.account,
                onSignIn: () => _signIn(p),
                onSignOut: () => _signOut(p),
              ),
        ],
      ),
      _Group('Appearance', [
        ListTile(
          title: const Text('Theme'),
          subtitle: Text(Settings.activeTheme.label),
          onTap: _pickTheme,
        ),
        _Choice(
          title: 'Show titles in',
          value: Settings.titleLanguage.label,
          onTap: () => _choose(
            'Show titles in',
            {for (final l in TitleLanguage.values) l: l.label},
            Settings.titleLanguage,
            (v) {
              Settings.titleLanguage = v;
              // Every screen, the ones under this one too, names its shows again; nothing else is reset.
              void rebuild(Element e) => e
                ..markNeedsBuild()
                ..visitChildren(rebuild);
              WidgetsBinding.instance.rootElement?.visitChildren(rebuild);
            },
          ),
        ),
        SwitchListTile(
          title: const Text('Welcome screen'),
          subtitle: const Text('Greets you by name when AniView opens'),
          value: Settings.welcome,
          onChanged: (v) => setState(() => Settings.welcome = v),
        ),
        SwitchListTile(
          title: const Text('Follow system light and dark'),
          subtitle: Text(
            'Uses the light or dark version of this theme to match your ${isDesktop ? 'computer' : 'phone'}',
          ),
          value: Settings.followSystemTheme,
          onChanged: (v) {
            setState(() => Settings.followSystemTheme = v);
            themeGeneration.value++;
          },
        ),
        if (isBetaBuild)
          SwitchListTile(
            title: const Text('Performance overlay'),
            subtitle: const Text(
              'Frame graph: top is the UI thread, bottom the raster thread. Red bars are slow frames',
            ),
            value: Settings.perfOverlay,
            onChanged: (v) {
              setState(() => Settings.perfOverlay = v);
              themeGeneration.value++; // the app rebuilds to show or hide it
            },
          ),
      ]),
      _Group('Tracking', [
        SwitchListTile(
          title: const Text('Update progress automatically'),
          subtitle: const Text('Marks the episode watched on your tracker'),
          value: Settings.syncAniList,
          onChanged: (v) => setState(() => Settings.syncAniList = v),
        ),
        _Choice(
          title: 'Count as watched at',
          value: '${Settings.watchedPercent}%',
          onTap: () => _choose(
            'Count as watched at',
            {
              for (final p in const [50, 60, 70, 75, 80, 85, 90, 95]) p: '$p%',
            },
            Settings.watchedPercent,
            (v) => Settings.watchedPercent = v,
          ),
        ),
      ]),
      _Group('Jellyfin', [
        if (Settings.jellyfinToken.isEmpty)
          ListTile(
            leading: const Icon(Icons.dns_rounded),
            title: const Text('Connect to Jellyfin'),
            subtitle: const Text(
              'Play shows from your own server, listed first among the sites',
            ),
            onTap: _jellyfinSignIn,
          )
        else
          ListTile(
            leading: const Icon(Icons.dns_rounded),
            title: Text('Connected as ${Settings.jellyfinUserName}'),
            subtitle: Text(Settings.jellyfinServer),
            trailing: TextButton(
              onPressed: () {
                Jellyfin.signOut();
                Sites.reload();
                setState(() {});
              },
              child: const Text('Disconnect'),
            ),
          ),
        if (Settings.jellyseerrCookie.isEmpty)
          ListTile(
            leading: const Icon(Icons.playlist_add_rounded),
            title: const Text('Connect to Jellyseerr'),
            subtitle: const Text(
              'Request shows that aren\'t on your server yet. Works with Seerr too',
            ),
            onTap: _jellyseerrSignIn,
          )
        else
          ListTile(
            leading: const Icon(Icons.playlist_add_check_rounded),
            title: const Text('Jellyseerr connected'),
            subtitle: Text(Settings.jellyseerrServer),
            trailing: TextButton(
              onPressed: () => setState(Jellyseerr.signOut),
              child: const Text('Disconnect'),
            ),
          ),
      ]),
      if (isDesktop)
        _Group('Keyboard', [
          ListTile(
            leading: const Icon(Icons.keyboard_rounded),
            title: const Text('Search shortcut'),
            subtitle: Text(keysLabel(searchShortcut.value)),
            trailing: Settings.searchShortcut == null
                ? null
                : IconButton(
                    tooltip: 'Back to $shortcutKey+F',
                    icon: const Icon(Icons.restore_rounded),
                    onPressed: () => setState(() => rebindSearch(null)),
                  ),
            onTap: () async {
              final keys = await recordShortcut(context);
              if (keys != null) setState(() => rebindSearch(keys));
            },
          ),
        ]),
      _Group('Home screen', [
        _Choice(
          title: 'Watch random picks from',
          value: _randomFrom[Settings.randomFrom] ?? 'Planning list',
          onTap: () => _choose(
            'Watch random picks from',
            const {
              'planning': 'Planning list · anything when it’s empty',
              'everything': 'Anything popular you haven’t watched',
            },
            Settings.randomFrom,
            (v) => Settings.randomFrom = v,
          ),
        ),
        if (!isDesktop && !Platform.isIOS)
          ListTile(
            title: const Text('Layout'),
            subtitle: Text(
              const {
                'auto': 'Automatic · TV layout on TVs',
                'phone': 'Phone',
                'tv': 'TV · for a remote or keyboard, in landscape',
              }[Settings.layout]!,
            ),
            onTap: () async {
              final picked = await pickOne(context, 'Layout', const {
                'auto': 'Automatic',
                'phone': 'Phone',
                'tv': 'TV',
              }, Settings.layout);
              if (picked == null || picked == Settings.layout) return;
              Settings.layout = picked;
              applyLayout(picked);
              appGeneration.value++; // rebuilt in the new layout
            },
          ),
        ListTile(
          title: const Text('Sections'),
          subtitle: const Text('Choose and reorder the rows on home'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const _HomeSectionsScreen()),
          ),
        ),
        SwitchListTile(
          title: const Text('Hide NSFW shows'),
          subtitle: const Text('Keeps ecchi titles out of browse and search'),
          value: Settings.hideNsfw,
          onChanged: (v) => setState(() => Settings.hideNsfw = v),
        ),
      ]),
      _Group('Anime details', [
        SwitchListTile(
          title: const Text('Group related seasons'),
          subtitle: const Text(
            'Show the prequel and sequel chain together on anime details',
          ),
          value: Settings.groupSeasons,
          onChanged: (v) => setState(() => Settings.groupSeasons = v),
        ),
      ]),
      // A phone that has never paired a TV sets one up; "remote" only once there's a TV to control.
      if (!Platform.isIOS)
        _Group(isTv ? 'Remote' : 'TV', [
          ListTile(
            leading: Icon(
              isTv || Settings.tvRemotes.isNotEmpty
                  ? Icons.settings_remote_rounded
                  : Icons.connected_tv_rounded,
            ),
            title: Text(
              isTv
                  ? 'Phone remote'
                  : Settings.tvRemotes.isEmpty
                  ? 'Set up AniView on a TV'
                  : 'TV remote',
            ),
            subtitle: Text(
              isTv
                  ? 'Control AniView on this TV from your phone'
                  : Settings.tvRemotes.isEmpty
                  ? isDesktop
                        ? 'Pair a TV running AniView to sign it in from this computer and use it as the TV\'s remote'
                        : 'Pair a TV running AniView to sign it in from this phone and use the phone as its remote'
                  : 'Control AniView on ${Settings.tvRemotes.length == 1 ? Settings.tvRemotes.values.first['name'] : 'your TVs'}',
            ),
            onTap: () async {
              await pushSettled(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      isTv ? const TvPairScreen() : const PhoneRemoteScreen(),
                ),
              );
              // Pairing may have signed the TV in.
              if (mounted) setState(() {});
            },
          ),
        ]),
      if (Platform.isAndroid)
        _Group('Notifications', [
          SwitchListTile(
            title: const Text('New episodes'),
            subtitle: const Text(
              'When a show you\'re watching or recently watched airs',
            ),
            value: Settings.episodeNotifications,
            onChanged: (v) {
              setState(() => Settings.episodeNotifications = v);
              // The schedule itself is refreshed by home when Settings closes.
              if (v) EpisodeNotifications.requestPermission(again: true);
            },
          ),
        ]),
      _Group('Playback', [
        SwitchListTile(
          title: const Text('Skip filler episodes'),
          subtitle: const Text(
            'Up next and the next episode pass over filler (from Anime Filler List). Filler stays in the list, marked',
          ),
          value: Settings.skipFiller,
          onChanged: (v) => setState(() => Settings.skipFiller = v),
        ),
        _Choice(
          title: 'Preferred audio',
          value: Settings.preferDub ? 'Dub' : 'Sub',
          onTap: () => _choose(
            'Preferred audio',
            const {false: 'Sub (Japanese audio)', true: 'Dub (English audio)'},
            Settings.preferDub,
            (v) => Settings.preferDub = v,
          ),
        ),
        SwitchListTile(
          title: const Text('Use Sub when Dub is unavailable'),
          subtitle: const Text(
            'Try Japanese audio for that episode. Your preferred audio stays unchanged.',
          ),
          value: Settings.fallbackToSub,
          onChanged: (v) => setState(() => Settings.fallbackToSub = v),
        ),
        FutureBuilder(
          future: Sites.all(),
          builder: (context, snap) => _Choice(
            title: 'Preferred source',
            value: Settings.preferredSource.isEmpty
                ? 'Highest ranked'
                : Settings.preferredSource,
            onTap: () => _choose(
              'Preferred source',
              {
                '': 'Highest ranked',
                for (final s in snap.data ?? const <Source>[]) s.name: s.label,
              },
              Settings.preferredSource,
              (v) => Settings.preferredSource = v,
            ),
          ),
        ),
        if (Platform.isAndroid)
          ListTile(
            title: const Text('Extensions'),
            subtitle: const Text('More sites, from Aniyomi extension repos'),
            onTap: () async {
              await pushSettled(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const ExtensionsScreen(),
                ),
              );
              // Installed extensions join the sources above.
              if (mounted) setState(() {});
            },
          ),
        _Choice(
          title: 'Streaming quality',
          subtitle: 'Change it for one episode in the player',
          value: _qualities[Settings.streamQuality] ?? 'Best',
          onTap: () => _choose(
            'Streaming quality',
            _qualities,
            Settings.streamQuality,
            (v) => Settings.streamQuality = v,
          ),
        ),
        SwitchListTile(
          title: const Text('Resume where you left off'),
          value: Settings.resume,
          onChanged: (v) => setState(() => Settings.resume = v),
        ),
        SwitchListTile(
          title: const Text('Play next episode automatically'),
          value: Settings.autoNext,
          onChanged: (v) => setState(() => Settings.autoNext = v),
        ),
        _Choice(
          title: 'Skip intro & outro',
          subtitle: 'Timestamps from AniSkip',
          value: const {
            SkipMode.button: 'Show button',
            SkipMode.auto: 'Automatically',
            SkipMode.off: 'Off',
          }[Settings.skipMode]!,
          onTap: () => _choose(
            'Skip intro & outro',
            const {
              SkipMode.button: 'Show a skip button',
              SkipMode.auto: 'Skip automatically',
              SkipMode.off: 'Off',
            },
            Settings.skipMode,
            (v) => Settings.skipMode = v,
          ),
        ),
        if (Platform.isAndroid)
          SwitchListTile(
            title: const Text('Use an external player'),
            subtitle: const Text(
              'Play episodes in MX Player, VLC or another installed app',
            ),
            value: Settings.externalPlayer,
            onChanged: (v) => setState(() => Settings.externalPlayer = v),
          ),
        if (!isTv && !isDesktop)
          SwitchListTile(
            title: const Text('Swipe gestures'),
            subtitle: const Text(
              'Swipe to seek, brightness on the left, volume on the right',
            ),
            value: Settings.swipeGestures,
            onChanged: (v) => setState(() => Settings.swipeGestures = v),
          ),
        if (!isTv && !isDesktop)
          _Choice(
            title: 'Hold the video to',
            value: _holdGestures[Settings.holdGesture] ?? 'Play at 2×',
            onTap: () => _choose(
              'Hold the video to',
              _holdGestures,
              Settings.holdGesture,
              (v) => Settings.holdGesture = v,
            ),
          ),
        _Choice(
          title: isTv || isDesktop
              ? 'Left / right seeks'
              : 'Double-tap to seek',
          value: '${Settings.seekSeconds}s',
          onTap: () => _choose(
            isTv || isDesktop ? 'Left / right seeks' : 'Double-tap to seek',
            {
              for (final s in const [5, 10, 15, 30]) s: '$s seconds',
            },
            Settings.seekSeconds,
            (v) => Settings.seekSeconds = v,
          ),
        ),
        _Choice(
          title: 'Skip button length',
          value: '${Settings.skipSeconds}s',
          onTap: () => _choose(
            'Skip button length',
            {
              for (final s in const [30, 60, 75, 85, 90, 120]) s: '$s seconds',
            },
            Settings.skipSeconds,
            (v) => Settings.skipSeconds = v,
          ),
        ),
        _Choice(
          title: 'Default speed',
          value: '${Settings.speed}×',
          onTap: () => _choose(
            'Default speed',
            {
              for (final s in const [.75, 1.0, 1.25, 1.5, 2.0]) s: '$s×',
            },
            Settings.speed,
            (v) => Settings.speed = v,
          ),
        ),
        _Choice(
          title: 'Default picture',
          value: pictureFits[Settings.videoFit]!,
          onTap: () => _choose(
            'Default picture',
            pictureFits,
            Settings.videoFit,
            (v) => Settings.videoFit = v,
          ),
        ),
      ]),
      _Group('Subtitles', [
        Padding(
          padding: const EdgeInsets.all(16),
          child: ColoredBox(
            color: const Color(0xff263238),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'This is your subtitle preview',
                textAlign: TextAlign.center,
                style: Settings.subtitleAppearance.style(),
              ),
            ),
          ),
        ),
        _Choice(
          title: 'Language',
          value: Settings.subtitleLanguage,
          onTap: () => _choose(
            'Subtitle language',
            {for (final l in subtitleLanguages) l: l},
            Settings.subtitleLanguage,
            (v) => Settings.subtitleLanguage = v,
          ),
        ),
        _Choice(
          title: 'Subtitles on dub',
          value: Settings.dubSubtitles == 'off' ? 'Off' : 'Dubtitles',
          onTap: () => _choose(
            'Subtitles on dub',
            {'dubtitles': 'Dubtitles', 'off': 'Off'},
            Settings.dubSubtitles,
            (v) => Settings.dubSubtitles = v,
          ),
        ),
        _Choice(
          title: 'Size',
          value:
              {
                18.0: 'Small',
                22.0: 'Medium',
                28.0: 'Large',
              }[Settings.subtitleSize] ??
              'Medium',
          onTap: () => _choose(
            'Subtitle size',
            {18.0: 'Small', 22.0: 'Medium', 28.0: 'Large'},
            Settings.subtitleSize,
            (v) => Settings.subtitleSize = v,
          ),
        ),
        _Choice(
          title: 'Text color',
          value: SubtitleAppearance.colors[Settings.subtitleAppearance.color]!,
          onTap: () => _choose(
            'Subtitle color',
            SubtitleAppearance.colors,
            Settings.subtitleAppearance.color,
            (v) => Settings.subtitleAppearance = Settings.subtitleAppearance
                .copyWith(color: v),
          ),
        ),
        _Choice(
          title: 'Background',
          value: SubtitleAppearance
              .backgrounds[Settings.subtitleAppearance.background]!,
          onTap: () => _choose(
            'Subtitle background',
            SubtitleAppearance.backgrounds,
            Settings.subtitleAppearance.background,
            (v) => Settings.subtitleAppearance = Settings.subtitleAppearance
                .copyWith(background: v),
          ),
        ),
        _Choice(
          title: 'Text edge',
          value: SubtitleAppearance.edges[Settings.subtitleAppearance.edge]!,
          onTap: () => _choose(
            'Subtitle edge',
            SubtitleAppearance.edges,
            Settings.subtitleAppearance.edge,
            (v) => Settings.subtitleAppearance = Settings.subtitleAppearance
                .copyWith(edge: v),
          ),
        ),
        _Choice(
          title: 'Font',
          value: SubtitleAppearance.fonts[Settings.subtitleAppearance.font]!,
          onTap: () => _choose(
            'Subtitle font',
            SubtitleAppearance.fonts,
            Settings.subtitleAppearance.font,
            (v) => Settings.subtitleAppearance = Settings.subtitleAppearance
                .copyWith(font: v),
          ),
        ),
        SwitchListTile(
          title: const Text('Bold subtitles'),
          value: Settings.subtitleAppearance.bold,
          onChanged: (v) => setState(
            () => Settings.subtitleAppearance = Settings.subtitleAppearance
                .copyWith(bold: v),
          ),
        ),
        _Choice(
          title: 'Vertical position',
          value:
              SubtitleAppearance.positions[Settings.subtitleAppearance.bottom]!,
          onTap: () => _choose(
            'Subtitle position',
            SubtitleAppearance.positions,
            Settings.subtitleAppearance.bottom,
            (v) => Settings.subtitleAppearance = Settings.subtitleAppearance
                .copyWith(bottom: v),
          ),
        ),
        ListTile(
          title: const Text('Reset subtitle appearance'),
          onTap: () => setState(
            () => Settings.subtitleAppearance = const SubtitleAppearance(),
          ),
        ),
      ]),
      _Group('Storage', [
        if (Platform.isIOS)
          const ListTile(
            leading: Icon(Icons.folder_outlined),
            title: Text('Downloads stay in AniView'),
            subtitle: Text(
              'Keep the app open while downloading. Saved episodes are available offline.',
            ),
          ),
        _Choice(
          title: 'Download quality',
          subtitle: 'Lower quality takes less space',
          value: _qualities[Settings.downloadQuality] ?? 'Best',
          onTap: () => _choose(
            'Download quality',
            _qualities,
            Settings.downloadQuality,
            (v) => Settings.downloadQuality = v,
          ),
        ),
        if (isDesktop)
          ListenableBuilder(
            listenable: Downloads.instance,
            builder: (context, _) => ListTile(
              leading: const Icon(Icons.folder_open_rounded),
              title: const Text('Download folder'),
              subtitle: Text(
                Downloads.instance.storageError == null
                    ? Downloads.instance.folder
                    : 'Storage unavailable · reconnect the folder and tap Retry',
              ),
              trailing: Settings.desktopDownloadFolder.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Back to the app’s own folder',
                      icon: const Icon(Icons.restore_rounded),
                      onPressed: () => _moveDownloads(null),
                    ),
              onTap: Platform.isMacOS
                  ? null
                  : () async {
                      final folder = await getDirectoryPath(
                        confirmButtonText: 'Keep downloads here',
                      );
                      if (folder != null) await _moveDownloads(folder);
                    },
            ),
          ),
        if (isDesktop)
          ListenableBuilder(
            listenable: Downloads.instance,
            builder: (context, _) => Downloads.instance.storageError == null
                ? const SizedBox.shrink()
                : ListTile(
                    title: const Text('Download storage unavailable'),
                    subtitle: Text('${Downloads.instance.storageError}'),
                    trailing: TextButton(
                      onPressed: Downloads.instance.reconnect,
                      child: const Text('Retry'),
                    ),
                  ),
          ),
        if (Platform.isMacOS)
          const ListTile(
            title: Text('Downloads stay in AniView'),
            subtitle: Text(
              'Custom folders are unavailable until persistent sandbox access is supported.',
            ),
          ),
        if (Platform.isAndroid)
          SwitchListTile(
            title: const Text('Save downloads to gallery'),
            subtitle: const Text(
              'Also copies each finished episode to the selected folder',
            ),
            value: Settings.saveToGallery,
            onChanged: (v) => setState(() => Settings.saveToGallery = v),
          ),
        if (Platform.isAndroid && Settings.saveToGallery)
          ListTile(
            leading: const Icon(Icons.folder_open_rounded),
            title: const Text('Download folder'),
            subtitle: Text(Settings.downloadFolderLabel),
            trailing: Settings.downloadFolder.isEmpty
                ? const Icon(Icons.chevron_right_rounded)
                : IconButton(
                    tooltip: 'Use app storage for new downloads',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () =>
                        setState(() => Settings.downloadFolder = ''),
                  ),
            onTap: () async {
              try {
                final folder = await AndroidApp.pickDownloadFolder();
                if (folder != null && mounted) {
                  setState(() => Settings.downloadFolder = folder);
                }
              } catch (e) {
                if (mounted) showError(this.context, e);
              }
            },
          ),
        ListenableBuilder(
          listenable: Downloads.instance,
          builder: (context, _) => DestructiveTile(
            icon: Icons.download_for_offline_outlined,
            title: 'Delete all downloads',
            subtitle: Text(
              '${formatBytes(Downloads.instance.totalBytes)} used on this device',
            ),
            onTap: Downloads.instance.items.isEmpty
                ? null
                : () async {
                    if (!await _confirm(
                      'Delete all downloads?',
                      'Every downloaded episode will be removed from this device.',
                      'Delete',
                    )) {
                      return;
                    }
                    await Downloads.instance.removeAll();
                    if (context.mounted) {
                      showSuccess(context, 'All downloads deleted');
                    }
                  },
          ),
        ),
        DestructiveTile(
          icon: Icons.history_rounded,
          title: 'Clear watch history',
          subtitle: const Text(
            'Removes continue-watching positions on this device',
          ),
          onTap: () async {
            if (!await _confirm(
              'Clear watch history?',
              'Saved positions will be removed.',
              'Clear',
            )) {
              return;
            }
            await WatchHistory.clear();
            if (context.mounted) {
              showSuccess(context, 'Watch history cleared');
            }
          },
        ),
        DestructiveTile(
          icon: Icons.link_off_rounded,
          title: 'Reset show matches',
          subtitle: const Text('Forget shows you picked manually on each site'),
          onTap: () async {
            await clearMatches();
            if (context.mounted) {
              showSuccess(context, 'Show matches reset');
            }
          },
        ),
        DestructiveTile(
          icon: Icons.verified_user_outlined,
          title: 'Clear site verifications',
          subtitle: const Text(
            'Use this if a site keeps failing after verifying',
          ),
          onTap: () async {
            await CookieManager.instance().deleteAllCookies();
            if (context.mounted) {
              showSuccess(context, 'Site verifications cleared');
            }
          },
        ),
      ]),
      _Group('About', [
        FutureBuilder(
          future: AndroidApp.version(),
          builder: (context, snap) => ListTile(
            leading: const Icon(Icons.info_outline_rounded),
            title: const Text(appName),
            subtitle: Text(
              snap.hasData
                  ? 'Version ${snap.data}${Platform.isIOS ? ' · Update through your sideloading app' : ' · ${isDesktop ? 'Click' : 'Tap'} to check for updates'}'
                  : 'Version',
            ),
            trailing: Platform.isIOS
                ? null
                : Icon(
                    isDesktop
                        ? Icons.refresh_rounded
                        : Icons.system_update_rounded,
                    size: 18,
                  ),
            onTap: Platform.isIOS ? null : () => checkForUpdate(context),
          ),
        ),
        if (Platform.isLinux)
          FutureBuilder(
            future: launcherInstalled(),
            builder: (_, snap) => ListTile(
              leading: const Icon(Icons.apps_rounded),
              title: Text(
                snap.data == true
                    ? 'Update the app menu entry'
                    : 'Add AniView to the app menu',
              ),
              subtitle: const Text(
                'A launcher with its icon, which also lets the browser return you here after signing in',
              ),
              onTap: () async {
                await installLauncher();
                if (!mounted) return;
                showSuccess(this.context, 'AniView is in your app menu');
                setState(() {});
              },
            ),
          ),
        ListTile(
          leading: const Icon(Icons.new_releases_outlined),
          title: const Text('What’s new'),
          subtitle: const Text('Version $changelogVersion'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => showChangelog(context),
        ),
        if (Analytics.available && Settings.analytics)
          ListTile(
            leading: const Icon(Icons.poll_outlined),
            title: const Text('AniView’s future'),
            subtitle: Text(
              Settings.subscriptionSurveyState == 'answered'
                  ? 'Thanks for sharing your thoughts'
                  : 'Share your thoughts on a US\$1 monthly subscription',
            ),
            onTap: Settings.subscriptionSurveyState == 'answered'
                ? null
                : () async {
                    await showSubscriptionSurvey(context);
                    if (mounted) setState(() {});
                  },
          ),
        if (Analytics.available)
          SwitchListTile(
            title: const Text('Share anonymous usage stats'),
            subtitle: const Text(
              'Which screens and features get used. No account, search text or personal data',
            ),
            value: Settings.analytics,
            // Sent while analytics is on: before switching it off, after switching it on.
            onChanged: (v) {
              if (!v) Analytics.event('usage_stats', {'enabled': false});
              setState(() => Settings.analytics = v);
              if (v) Analytics.event('usage_stats', {'enabled': true});
            },
          ),
        for (final (icon, title, url) in const [
          (
            Icons.coffee_rounded,
            'Buy me a coffee',
            'https://www.buymeacoffee.com/kidfury',
          ),
          (Icons.discord, 'Join the Discord', 'https://discord.gg/TXkEgGK9cp'),
          (
            Icons.code_rounded,
            'GitHub',
            'https://github.com/ebrahimHakimuddin',
          ),
          (
            Icons.description_outlined,
            'Resume',
            'https://resume.ebrahim.co.tz',
          ),
        ])
          ListTile(
            leading: Icon(icon),
            title: Text(title),
            subtitle: Text(url.replaceFirst('https://', '')),
            trailing: const Icon(Icons.open_in_new_rounded, size: 18),
            onTap: () => AndroidApp.open(url).ignore(),
          ),
      ]),
    ];
    if (isDesktop) return _desktop(sections);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        toolbarHeight: isTv ? 72 : 64,
        titleSpacing: side,
        titleTextStyle: Theme.of(context).textTheme.headlineMedium,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          0,
          0,
          // TV: a readable column rather than lines across the whole screen.
          isTv ? MediaQuery.sizeOf(context).width * .3 : 0,
          32 + MediaQuery.paddingOf(context).bottom,
        ),
        children: sections,
      ),
    );
  }
}

/// A titled group of settings, Android Settings style: the title in the accent colour, rows under it.
class _Group extends StatelessWidget {
  const _Group(this.title, this.children);

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: EdgeInsets.fromLTRB(side, 24, side, 4),
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleSmall
              ?.copyWith(color: scheme.primary),
        ),
      ),
      ...children,
    ],
  );
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.title,
    required this.value,
    required this.onTap,
    this.subtitle,
  });

  final String title, value;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(title),
    subtitle: Text(subtitle == null ? value : '$value · $subtitle'),
    onTap: onTap,
  );
}

/// An account at the top of Settings: AniList or MyAnimeList, one signed in at a time.
class _Account extends StatelessWidget {
  const _Account({
    required this.provider,
    required this.other,
    required this.onSignIn,
    required this.onSignOut,
  });

  final ListProvider provider;

  /// The other account, when it's the one signed in: signing in here switches from it.
  final ListProvider? other;
  final VoidCallback onSignIn, onSignOut;

  bool get signedIn => provider.signedIn;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(side, 8, side, 0),
    child: Card.filled(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHigh,
      child: FutureBuilder(
        future: provider.viewer().catchError((Object _) => null),
        builder: (context, snap) {
          final avatar = snap.data?['avatar']?['large'] as String?;
          return ListTile(
            contentPadding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
            leading: CircleAvatar(
              radius: 24,
              backgroundColor: scheme.secondaryContainer,
              backgroundImage: avatar == null ? null : NetworkImage(avatar),
              child: avatar == null
                  ? Icon(
                      Icons.person_rounded,
                      color: scheme.onSecondaryContainer,
                    )
                  : null,
            ),
            title: Text(
              signedIn ? (snap.data?['name'] ?? provider.name) : provider.name,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            subtitle: Text(
              signedIn
                  ? 'Your list and progress are kept here'
                  : other != null
                  ? 'Switching signs you out of ${other!.name}'
                  : 'Sign in to track what you watch',
            ),
            trailing: signedIn
                ? OutlinedButton(
                    style: destructiveButton,
                    onPressed: onSignOut,
                    child: const Text('Sign out'),
                  )
                : other != null
                ? OutlinedButton(
                    onPressed: onSignIn,
                    child: const Text('Switch'),
                  )
                : FilledButton(
                    onPressed: onSignIn,
                    child: const Text('Sign in'),
                  ),
          );
        },
      ),
    ),
  );
}
