import 'cloudflare.dart';
import 'sources.dart';

/// A show's entry on one site: which entry of the site it is, its episodes, and the streams of an episode. The
/// **listing** of CONTEXT.md.
///
/// Matching is the person's pick when they made one ([pick]), else the site's own guess; a site's Cloudflare check goes
/// to [onChallenge], which differs by caller (a verification page on a screen, nothing in a download).
class SiteListing {
  SiteListing(this.source, this.media, {this.onChallenge});

  /// The listing of [media] on the site saved under [name]; null when it's no longer one of the sites.
  static Future<SiteListing?> of(
    String name,
    Map media, [
    ChallengeHandler? onChallenge,
  ]) async => switch (await Sites.named(name)) {
    final source? => SiteListing(source, media, onChallenge: onChallenge),
    null => null,
  };

  final Source source;
  final Map media;
  final ChallengeHandler? onChallenge;

  /// The show's episodes on the site, with titles and artwork from ani.zip; empty when the show isn't matched.
  Future<List<Episode>> episodes() =>
      withChallenge(onChallenge, () => loadEpisodes(source, media));

  /// The servers playing [episode], in the audio asked for.
  Future<List<VideoStream>> streams(Episode episode, {required bool dub}) =>
      withChallenge(
        onChallenge,
        () => source.streams(media, episode, dub: dub),
      );

  /// The site's shows matching [query], for the person to pick from.
  Future<List<SearchResult>> search(String query) =>
      withChallenge(onChallenge, () => source.search(query));

  /// Remembers [id] as this show's entry on the site, for [episodes] from now on.
  Future<void> pick(String id) => setMatch(source, media, id);
}
