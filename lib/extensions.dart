import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sources.dart';
import 'states.dart';
import 'tv.dart';
import 'ui.dart';

/// An Aniyomi extension repo the user added: its index.min.json, and the key its extensions are signed with.
class ExtensionRepo {
  const ExtensionRepo(this.index, this.name, this.fingerprint);

  final String index, name, fingerprint;

  /// The folder index.min.json, repo.json, apk/ and icon/ sit in.
  String get base => index.substring(0, index.lastIndexOf('/'));

  Map<String, String> toJson() => {
    'index': index,
    'name': name,
    'fingerprint': fingerprint,
  };

  factory ExtensionRepo.fromJson(Map json) =>
      ExtensionRepo(json['index'], json['name'], json['fingerprint']);
}

/// One extension listed by a repo.
class ExtensionInfo {
  ExtensionInfo(this.repo, Map json)
    : pkg = json['pkg'],
      apk = json['apk'],
      name = (json['name'] as String).replaceFirst('Aniyomi: ', ''),
      lang = json['lang'],
      version = json['version'],
      nsfw = json['nsfw'] == 1;

  final ExtensionRepo repo;
  final String pkg, apk, name, lang, version;
  final bool nsfw;

  String get icon => '${repo.base}/icon/$pkg.png';

  /// Extensions-lib 14 and 16 are what the app implements (the version name's major part).
  bool get supported =>
      switch (double.tryParse(version.substring(0, version.lastIndexOf('.')))) {
        final lib? => lib >= 14 && lib < 17,
        null => false,
      };
}

/// An installed extension: its package and the sources it adds.
typedef InstalledExtension = ({
  String pkg,
  String version,
  List<String> sources,
});

/// Left out: the sites AniView reaches itself (see [topSources]), which would only duplicate them, Re:Anime, which
/// AniView no longer offers, and torrent extensions, which need Aniyomi's torrent utilities.
// ponytail: matched by package name; read a manifest flag if more torrent extensions appear
const _hidden = {
  'anikoto',
  'animepahe',
  'reanime',
  'hentaitorrent',
  'nyaatorrent',
  'ptorrent',
};

class Extensions {
  static Future<SharedPreferences> get _prefs =>
      SharedPreferences.getInstance();

  static Future<List<ExtensionRepo>> repos() async => [
    for (final r in jsonDecode(
      (await _prefs).getString('extension_repos') ?? '[]',
    ))
      ExtensionRepo.fromJson(r),
  ];

  static Future<void> _saveRepos(List<ExtensionRepo> repos) async =>
      (await _prefs).setString('extension_repos', jsonEncode(repos));

  /// Adds the repo at [url] (its index.min.json, or the folder it's in), named and keyed by its repo.json.
  static Future<ExtensionRepo> addRepo(String url) async {
    var index = url.trim();
    if (!index.endsWith('.json')) {
      index = '${index.replaceFirst(RegExp(r'/+$'), '')}/index.min.json';
    }
    final base = index.substring(0, index.lastIndexOf('/'));
    final Map meta;
    try {
      meta = jsonDecode(await fetch('$base/repo.json'))['meta'];
    } catch (_) {
      throw Exception("That isn't an extension repo: it has no repo.json");
    }
    // Checks the index is there too, before it's saved.
    jsonDecode(await fetch(index)) as List;
    final repo = ExtensionRepo(
      index,
      meta['name'] ?? Uri.parse(index).host,
      meta['signingKeyFingerprint'],
    );
    await _saveRepos([...(await repos()).where((r) => r.index != index), repo]);
    return repo;
  }

  static Future<void> removeRepo(ExtensionRepo repo) async =>
      _saveRepos((await repos()).where((r) => r.index != repo.index).toList());

  /// What the repos offer that the app can run, by name.
  static Future<List<ExtensionInfo>> available(
    List<ExtensionRepo> repos,
  ) async {
    final lists = await Future.wait(
      repos.map(
        (repo) async => [
          for (final e in jsonDecode(await fetch(repo.index)) as List)
            ExtensionInfo(repo, e),
        ],
      ),
    );
    return [
      for (final e in lists.expand((l) => l))
        if (e.supported && !_hidden.contains(e.pkg.split('.').last)) e,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  static Future<Map<String, InstalledExtension>> installed() async {
    final byPkg = <String, InstalledExtension>{};
    for (final s in await ExtensionHost.current.sources()) {
      byPkg[s.pkg] = (
        pkg: s.pkg,
        version: s.version,
        sources: [...?byPkg[s.pkg]?.sources, s.name],
      );
    }
    return byPkg;
  }

  /// Downloads [extension] and hands it to Android, which only loads it if it's signed with its repo's key. The site
  /// list picks up the change.
  static Future<void> install(ExtensionInfo extension) async {
    final res = await http.get(
      Uri.parse('${extension.repo.base}/apk/${extension.apk}'),
    );
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode}');
    }
    final file = File(
      '${(await getTemporaryDirectory()).path}/${extension.apk}',
    );
    await file.writeAsBytes(res.bodyBytes);
    try {
      await ExtensionHost.current.install(
        file.path,
        extension.repo.fingerprint,
      );
    } finally {
      await file.delete();
    }
    Sites.reload();
  }

  static Future<void> uninstall(String pkg) async {
    await ExtensionHost.current.uninstall(pkg);
    Sites.reload();
  }
}

/// Settings → Extensions: the repos, and the extensions installed from them and on offer.
class ExtensionsScreen extends StatefulWidget {
  const ExtensionsScreen({super.key});

  @override
  State<ExtensionsScreen> createState() => _ExtensionsScreenState();
}

typedef _Catalog = ({
  List<ExtensionRepo> repos,
  Map<String, InstalledExtension> installed,
  List<ExtensionInfo> available,
});

class _ExtensionsScreenState extends State<ExtensionsScreen> {
  late Future<_Catalog> _catalog = _load();

  /// Packages being installed, updated or removed.
  final _busy = <String>{};
  String _filter = '';
  bool _nsfw = false;

  Future<_Catalog> _load() async {
    final repos = await Extensions.repos();
    final (installed, available) = await (
      Extensions.installed(),
      Extensions.available(repos),
    ).wait;
    return (repos: repos, installed: installed, available: available);
  }

  void _reload() => setState(() => _catalog = _load());

  Future<void> _addRepo() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => PanelDialog(
        title: const Text('Add repo'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://…/index.min.json',
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (url == null || url.trim().isEmpty || !mounted) return;
    try {
      final repo = await Extensions.addRepo(url);
      if (mounted) showSuccess(context, 'Added ${repo.name}');
    } catch (e) {
      if (mounted) showError(context, e);
    }
    _reload();
  }

  Future<void> _removeRepo(ExtensionRepo repo) async {
    final sure = await confirmDestructive(
      context,
      title: 'Remove ${repo.name}?',
      message: 'Its installed extensions stay until you remove them.',
      action: 'Remove',
    );
    if (!sure) return;
    await Extensions.removeRepo(repo);
    _reload();
  }

  Future<void> _run(String pkg, Future<void> Function() task) async {
    setState(() => _busy.add(pkg));
    try {
      await task();
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (!mounted) return;
    _busy.remove(pkg);
    _reload();
  }

  Future<void> _install(ExtensionInfo extension) async {
    // Extension code runs inside the app, so it's only installed once the user knows that.
    final trusted = await showDialog<bool>(
      context: context,
      builder: (context) => PanelDialog(
        title: Text('Install ${extension.name}?'),
        content: Text(
          'Extensions run their own code inside AniView. Only install ones '
          'from ${extension.repo.name} if you trust it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Install'),
          ),
        ],
      ),
    );
    if (trusted != true) return;
    await _run(extension.pkg, () => Extensions.install(extension));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Extensions'),
      actions: [
        IconButton(
          tooltip: 'Add repo',
          icon: const Icon(Icons.add_rounded),
          onPressed: _addRepo,
        ),
        const SizedBox(width: 8),
      ],
    ),
    body: FutureBuilder(
      future: _catalog,
      builder: (context, snap) {
        if (snap.hasError) {
          return ErrorState(snap.error!, onRetry: _reload);
        }
        final catalog = snap.data;
        if (catalog == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (catalog.repos.isEmpty && catalog.installed.isEmpty) {
          return EmptyState(
            icon: Icons.extension_outlined,
            title: 'No extension repos',
            message:
                'Add an Aniyomi extension repo to watch from more sites. '
                'AniView doesn\'t come with one.',
            action: FilledButton.icon(
              autofocus: isTv,
              onPressed: _addRepo,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add repo'),
            ),
          );
        }
        return _list(context, catalog);
      },
    ),
  );

  Widget _list(BuildContext context, _Catalog catalog) {
    final byPkg = {for (final e in catalog.available) e.pkg: e};
    final query = _filter.toLowerCase();
    final offered = [
      for (final e in catalog.available)
        if (!catalog.installed.containsKey(e.pkg) &&
            (_nsfw || !e.nsfw) &&
            (query.isEmpty || e.name.toLowerCase().contains(query)))
          e,
    ];
    return ListView(
      padding: EdgeInsets.only(
        bottom: 32 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        const SectionHeader('Repos'),
        for (final repo in catalog.repos)
          ListTile(
            leading: const Icon(Icons.inventory_2_outlined),
            title: Text(repo.name),
            subtitle: Text(
              repo.index,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              tooltip: 'Remove repo',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () => _removeRepo(repo),
            ),
          ),
        if (catalog.installed.isNotEmpty) ...[
          const SectionHeader('Installed'),
          for (final ext in catalog.installed.values)
            _tile(
              icon: byPkg[ext.pkg]?.icon,
              title: ext.sources.join(', '),
              subtitle: [
                if (byPkg[ext.pkg]?.lang case final lang?) lang.toUpperCase(),
                'v${ext.version}',
              ].join(' · '),
              busy: _busy.contains(ext.pkg),
              actions: [
                if (byPkg[ext.pkg] case final listed?
                    when listed.version != ext.version)
                  TextButton(
                    onPressed: () =>
                        _run(ext.pkg, () => Extensions.install(listed)),
                    child: const Text('Update'),
                  ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () =>
                      _run(ext.pkg, () => Extensions.uninstall(ext.pkg)),
                ),
              ],
            ),
        ],
        if (catalog.available.isNotEmpty) ...[
          const SectionHeader('Available'),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: side, vertical: 8),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Search extensions',
              ),
              onChanged: (v) => setState(() => _filter = v),
            ),
          ),
          SwitchListTile(
            title: const Text('Show 18+ extensions'),
            value: _nsfw,
            onChanged: (v) => setState(() => _nsfw = v),
          ),
          for (final e in offered)
            _tile(
              icon: e.icon,
              title: e.name,
              subtitle: [
                e.lang.toUpperCase(),
                'v${e.version}',
                if (e.nsfw) '18+',
              ].join(' · '),
              busy: _busy.contains(e.pkg),
              actions: [
                TextButton(
                  onPressed: () => _install(e),
                  child: const Text('Install'),
                ),
              ],
            ),
        ],
      ],
    );
  }

  Widget _tile({
    required String? icon,
    required String title,
    required String subtitle,
    required bool busy,
    required List<Widget> actions,
  }) => ListTile(
    leading: ClipRRect(
      borderRadius: BorderRadius.circular(radiusMedium),
      child: SizedBox.square(
        dimension: 40,
        child: Artwork(icon, placeholder: const Icon(Icons.extension_outlined)),
      ),
    ),
    title: Text(title),
    subtitle: Text(subtitle),
    trailing: busy
        ? const SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Row(mainAxisSize: MainAxisSize.min, children: actions),
  );
}
