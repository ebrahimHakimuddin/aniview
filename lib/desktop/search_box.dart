import 'dart:async';

import 'package:flutter/material.dart';

import '../anilist.dart';
import '../details.dart';
import '../platform.dart';
import '../tracker.dart';
import '../ui.dart';
import 'motion.dart';

/// The top bar's search box: a pill in the middle of the bar that suggests shows as you type (their posters,
/// ↑ ↓ to move, Enter to open one) and, first of all, "Search for …" for the full results page. Cmd+K on macOS
/// (Ctrl+F elsewhere) puts the
/// cursor here from anywhere.
class DeskSearchBox extends StatefulWidget {
  const DeskSearchBox({
    super.key,
    required this.controller,
    required this.focus,
    required this.onSearch,
  });

  final TextEditingController controller;
  final FocusNode focus;

  /// The full results page for [text].
  final ValueChanged<String> onSearch;

  @override
  State<DeskSearchBox> createState() => _DeskSearchBoxState();
}

class _DeskSearchBoxState extends State<DeskSearchBox> {
  int _serial = 0;

  /// The first option, standing for the whole results page.
  static const _all = '_all';

  /// A pause in typing, then the first few matches; a newer keystroke drops this answer.
  Future<Iterable<Map>> _options(TextEditingValue value) async {
    final query = value.text.trim();
    final serial = ++_serial;
    if (query.length < 2) return const [];
    await Future<void>.delayed(const Duration(milliseconds: 280));
    if (serial != _serial) return const [];
    try {
      final (found, _) = await Tracker.search(query, const SearchFilters());
      return [
        {_all: query},
        ...found.take(6).cast<Map>(),
      ];
    } catch (_) {
      return [
        {_all: query},
      ]; // the page itself says what went wrong
    }
  }

  void _chosen(Map option) {
    if (option[_all] case final String query) {
      widget.onSearch(query);
    } else {
      openDetails(context, option);
    }
    widget.focus.unfocus();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => RawAutocomplete<Map>(
      textEditingController: widget.controller,
      focusNode: widget.focus,
      optionsBuilder: _options,
      // Choosing leaves what was typed as it was.
      displayStringForOption: (_) => widget.controller.text,
      onSelected: _chosen,
      fieldViewBuilder: (context, controller, focus, submit) => _Field(
        controller: controller,
        focus: focus,
        onSubmitted: () {
          if (controller.text.trim().length < 2) {
            widget.onSearch(controller.text.trim());
          } else {
            submit();
          }
        },
      ),
      optionsViewBuilder: (context, onSelected, options) => Align(
        alignment: Alignment.topLeft,
        child: _Pop(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Material(
              elevation: 8,
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(nested(8)),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: box.maxWidth,
                  maxHeight: 460,
                ),
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  shrinkWrap: true,
                  itemCount: options.length,
                  itemBuilder: (context, i) {
                    final option = options.elementAt(i);
                    return _Suggestion(
                      option,
                      highlighted:
                          AutocompleteHighlightedOption.of(context) == i,
                      onTap: () => onSelected(option),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The suggestions open out of the box they hang from: a hint of scale from its top edge and a fade, fast.
class _Pop extends StatelessWidget {
  const _Pop({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 140),
      curve: deskEaseOut,
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.scale(
          scale: .97 + .03 * t,
          alignment: Alignment.topCenter,
          child: child,
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.focus,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(buttonRadius),
      borderSide: BorderSide(color: color, width: width),
    );
    return SizedBox(
      height: 44,
      child: TextField(
        controller: controller,
        focusNode: focus,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => onSubmitted(),
        style: Theme.of(context).textTheme.bodyMedium,
        decoration: InputDecoration(
          hintText: 'Search anime',
          filled: true,
          fillColor: scheme.surfaceContainerHigh,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 0),
          prefixIcon: const Icon(Icons.search_rounded, size: 22),
          suffixIcon: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => controller.text.isEmpty
                ? Padding(
                    padding: const EdgeInsets.only(right: 14),
                    child: Center(
                      widthFactor: 1,
                      child: _Key(searchShortcutLabel),
                    ),
                  )
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: controller.clear,
                  ),
          ),
          border: border(Colors.transparent, 0),
          enabledBorder: border(Colors.transparent, 0),
          focusedBorder: border(scheme.primary, 1.5),
        ),
      ),
    );
  }
}

class _Suggestion extends StatelessWidget {
  const _Suggestion(
    this.option, {
    required this.highlighted,
    required this.onTap,
  });

  final Map option;
  final bool highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final all = option['_all'] as String?;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: highlighted ? scheme.onSurface.withValues(alpha: .08) : null,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: all != null
            ? Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: .16),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.search_rounded,
                      size: 20,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'Search for “$all”',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelLarge,
                    ),
                  ),
                  const _Key('Enter'),
                ],
              )
            : Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(radiusSmall),
                    child: SizedBox(
                      width: 36,
                      height: 54,
                      child: Artwork(
                        Show(option).cover,
                        color: Show(option).color,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          Show(option).title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          mediaMeta(option, genres: 2),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (Show(option).score case final score?) Pill.score(score),
                ],
              ),
      ),
    );
  }
}

/// A keyboard shortcut's cap, as a hint.
class _Key extends StatelessWidget {
  const _Key(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border.all(color: hairline),
      borderRadius: BorderRadius.circular(radiusSmall),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    ),
  );
}
