---
name: AniView
description: An anime discovery, watching, and tracking interface for phones and TV.
colors:
  brand-cyan: "#01C4FA"
  violet-seed: "#6750A4"
  forest-seed: "#006B5F"
  episode-highlight: "#FFC857"
typography:
  headline:
    fontSize: "28px"
    fontWeight: 600
    lineHeight: 1.15
    letterSpacing: "-0.5px"
  title:
    fontSize: "18px"
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: "-0.2px"
  body:
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.5
  label:
    fontSize: "14px"
    fontWeight: 600
    lineHeight: 1.3
  caption:
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.4
    letterSpacing: "0.2px"
rounded:
  small: "4px"
  control: "8px"
  art: "12px"
  card: "16px"
  dialog: "24px"
spacing:
  xsmall: "4px"
  small: "8px"
  medium: "12px"
  page: "16px"
  large: "24px"
  tv-page: "48px"
components:
  button:
    rounded: "{rounded.control}"
    height: "48px"
  card:
    rounded: "{rounded.card}"
  input:
    rounded: "{rounded.art}"
---

# Design System: AniView

## Overview

AniView is a content-first Material 3 app. Artwork carries the visual character; controls stay quiet, legible, and consistent. The existing dark custom theme is the default. Users can choose from seven predefined themes: AniView Custom and Cyan, Violet, or Forest in light and dark. Flutter's `ColorScheme` roles are the source of truth for surfaces, text, actions, and errors.

## Colors

Use `ColorScheme.fromSeed` with the selected preset seed: Cyan `#01C4FA`, Violet `#6750A4`, or Forest `#006B5F`. AniView Custom uses the cyan seed with the dark fidelity variant; Material presets use the standard tonal variant with their selected brightness. Use semantic roles (`surface`, `surfaceContainer*`, `onSurface`, `onSurfaceVariant`, `primary`, `error`, and matching `on*` colors) rather than fixed light or dark colors. The episode highlight yellow is reserved for episode status. Video overlays may use fixed black and white to maintain contrast against the picture. Text and controls must meet 4.5:1 and 3:1 contrast respectively on their actual backgrounds.

## Typography

The custom theme uses the platform sans-serif with the sizes above. Material themes use Flutter's Material 3 type scale. Screen headings, card titles, body copy, labels, and captions keep distinct roles. Respect device text scaling; shorten or wrap labels before clipping text.

## Layout

Use an 8dp rhythm with 4dp for tight gaps, 12dp between peer cards, 16dp phone page margins, and 24dp between sections. TV uses 48dp side overscan and 24dp vertical overscan. Phones have the floating bottom navigation pill in every theme. Wider layouts use a navigation rail; TV uses a focusable drawer. Vertical page scrolling is allowed. Horizontal scrolling is reserved for intentional media or date carousels, never for the page itself. Controls have at least 48dp touch targets on phones and 56dp on TV.

## Elevation & Depth

Use Material tonal surfaces for resting depth. The custom theme uses outlines and surface layers for controls and cards; focused TV controls invert for clear focus. Reserve shadows for artwork, floating overlays, or focus treatment.

## Shapes

Use 4dp for small details, 8dp for controls, 12dp for art, 16dp for cards, and 24dp for dialogs and sheets. Cards with controls inset by 16dp may use 24dp corners. When a control sits inside a padded surface, increase the outer radius by the inset so corners remain concentric.

## Components

Buttons of the same role share height, corner shape, text style, and hover, pressed, focus, and disabled feedback. Custom buttons use the app's outlined and tonal treatments; Material themes use Material 3 component defaults. Cards use semantic container colors and the card radius. Inputs share filled surfaces, a visible focus outline, and inline error text. Selection controls use primary color plus an icon, border, or position cue. Dialogs and sheets use the platform Material transitions and keep actions visible when text is enlarged. Loading, empty, and error states use the shared skeleton, `EmptyState`, and `ErrorState` components.

### Patterns

- **Headers over art:** a pinned app bar may sit over key art. Put a surface-to-transparent scrim behind it (85% at the top) and use `onSurface` for its icons, not the dimmer default, so the logo and buttons stay readable in light and dark themes.
- **Selection:** long-press starts picking; tapping then toggles. Picked posters and rows share the primary tint (22% on art, 12% on rows) and a primary check. The shared `SelectionBar` shows the count, Done, All and icon actions, with a progress line while a change saves. It sits on the page surface at the top of a list, or in a `Panel` where the main action floats at the bottom.
- **Filters:** a choice among values is a dropdown chip that opens a picker. An on/off filter is a `SwitchListTile`, never a chip.
- **Tabs:** `TabBar` under a page's header, with the primary indicator under the label and `labelLarge` text. The new tab's content fades in over 200ms.
- **Row actions:** every action in a list row keeps its 48dp target. When a row needs two, put them side by side at its end rather than shrinking or stacking them.
- **Sections with tabs:** the tabs lead the section and replace its heading. Controls that apply to one tab only (an episode list's site and audio) sit at the top of that tab, not above the tabs.
- **Loading:** grids load as poster skeletons, people and thread lists as skeleton rows (a round picture and two lines). A spinner only appears for loading more at the end of a list, or inside the button that started an action.
- **Forms:** disable a submit button until there's something to submit, show the spinner in it while submitting, put a failure under the field it belongs to, and confirm success with a snackbar.
- **Discussion:** comments show the avatar, name and age, then the text, with Like and Reply as full-size text buttons. Replies indent 8dp with a 2dp outline-variant rule, up to four levels. Spoilers stay hidden on a `surfaceContainerHighest` background until tapped.
- **Naming:** name a feature for what the user already has. A phone that has never paired a TV offers to set one up; it says "TV remote" only once a TV is paired.

## Do's and Don'ts

- Do use `Theme.of(context)` and semantic color roles for new UI.
- Do use the spacing, radius, and type roles above instead of one-off values.
- Do preserve text scale, focus order, touch targets, and visible control states.
- Don't put light text directly on a light surface or dark text directly on a dark surface.
- Don't let a mobile navigation label or action force the page wider than the viewport.
