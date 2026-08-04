# AeroSpace Glass

<img src="./resources/Assets.xcassets/AppIcon.appiconset/icon.png" width="40%" align="right">

AeroSpace is an i3-like tiling window manager for macOS. This fork adds an i3-style tabbed layout
with Liquid Glass tab bars, optional window borders, and i3-compatible splitting.

## About this fork

A fork of [nikitabobko/AeroSpace](https://github.com/nikitabobko/AeroSpace) that adds the window
decorations upstream deliberately leaves out, and closes the remaining gaps between AeroSpace's
`split` and i3's. Everything else tracks upstream unchanged.

Upstream declines window decorations on purpose — see
[#85](https://github.com/nikitabobko/AeroSpace/issues/85) for borders and the project's
"[non-values](https://github.com/nikitabobko/AeroSpace#non-values)" on ricing — and recommends
running [JankyBorders](https://github.com/FelixKratz/JankyBorders) alongside it instead. This fork
takes the other path and draws them in-process, which turns out to matter (see
[Why in-process](#why-in-process)).

Full reference: [`docs/glass.adoc`](docs/glass.adoc).

---

### The `tabbed` layout

A third tiling layout beside `tiles` and `accordion`. Every window in the container gets the same
rect, minus a strip reserved at the top for a tab bar, so only the visible one is on top.

```bash
aerospace layout tabbed         # tab up the focused window
aerospace layout tiles tabbed   # toggle
```

This is i3's tabbed layout. Upstream maps i3's tabbed onto `h_accordion`, which offsets each window
so a sliver of its neighbour peeks out — it never shows titles, and you can't tell how many windows
are stacked. Upstream's own [#24](https://github.com/nikitabobko/AeroSpace/issues/24) asks for a
`stack` layout with indicators for exactly this reason.

Behaviour worth knowing:

- **It scopes to the focused window**, not its whole parent. Tabbing up a window in the corner puts
  a bar over *that tile* rather than swallowing the workspace. The window is wrapped in a new tabbed
  container holding just itself, showing one tab.
- **Windows move in and out** with the ordinary `move` command. A tabbed container is a terminal
  move-in target, so a window moved into it becomes another tab instead of descending into whatever
  the visible tab holds.
- **A tab group is always horizontal.** Tabs run left to right in the bar, so `focus left`/`right`
  step between them and then out of the group, while `focus up`/`down` leave directly — the same
  split i3 draws between its tabbed and stacked layouts. This is derived, not stored, so no creation
  path or normalization can get it wrong.
- **It survives `enable-normalization-flatten-containers`.** Without an exemption, a container
  holding a single tab would be dissolved the instant it was created.
- **Every tab resizes with the container**, including the hidden ones. Only resizing the visible tab
  leaves the others overflowing their tile the moment the container shrinks.

### Glass decorations

Drawn with macOS 26 Liquid Glass (`NSGlassEffectView` / SwiftUI `glassEffect`), falling back to
`NSVisualEffectView` blur materials on macOS 25 and earlier.

**Tab bars** — one blurred strip per tab group, one tab per window with its app icon and title. The
tabs form a value ramp against the strip: unselected a shade darker, selected the lightest thing in
the bar. Label colors are derived from each tab's fill luminance rather than the system appearance,
because a decoration floats over arbitrary application content and the light/dark setting says
nothing about what a label will actually sit on. Clicking a tab focuses that window without
activating AeroSpace.

**Borders** — an optional outline around each tiled window showing which has focus. Off by default,
since it costs one overlay panel per visible window.

<a name="why-in-process"></a>
**Why in-process.** AeroSpace implements virtual workspaces by parking the windows of inactive
workspaces in a screen corner. A border tool that doesn't know that — JankyBorders included — draws
for those parked windows too, which is the familiar pile of stray borders in the corner of the
screen. Because these decorations read AeroSpace's own tree, they simply don't draw them. They also
know which tab of a group is visible, so a tab group gets one border rather than N stacked ones.

No private APIs and no Screen Recording permission: the window server composites the blur, so it
picks up other applications' windows through public AppKit alone.

### i3-compatible `split`

Upstream's `split` refuses to run at all under the default
`enable-normalization-flatten-containers`:

```
'split' has no effect when 'enable-normalization-flatten-containers' normalization enabled.
```

The complaint is real — that normalization dissolves any container holding a single child, so a
freshly split container would vanish before anything could join it. This fork creates the container
immediately anyway, the way i3 does, and marks it deliberate so the normalization leaves it alone
while it holds a child:

```bash
aerospace split vertical   # the focused window is now alone in a vertical container
aerospace move left        # from the tile beside it: stacks below, inside the split
```

New windows opening beside the split window land inside it too.

Two further fixes, both cases where the command did the opposite of what it says:

- **A split keeps the orientation you named.** `enable-normalization-opposite-orientation-for-nested-containers`
  flips a nested container to the opposite of its parent, which silently turned `split horizontal`
  inside a horizontal parent into a vertical split. Containers created any other way still normalize
  as before.
- **Splitting from inside a tab divides the whole tab group**, rather than nesting a split within
  the focused tab — which would shrink only the visible tab and leave its siblings at full size. i3
  reaches the group with `focus parent` first; AeroSpace has no equivalent, so the group is split
  directly.

---

### Configuration

All keys optional, all under `glass.*`. Sizes are whole points (AeroSpace's TOML parser has no float
type). Colors accept `#RRGGBB`, `#RRGGBBAA`, or JankyBorders-style `0xAARRGGBB`, so a color can be
pasted straight out of an existing `borders` setup.

```toml
glass.borders.enabled =        false   # draw borders at all
glass.borders.width =          3
glass.borders.corner-radius =  11      # macOS 26 windows are ~11pt rounded
glass.borders.padding =        2       # outward offset, so the stroke hugs rather than covers
glass.borders.show-inactive =  true
glass.borders.active-color =   '#8CC7FF'
glass.borders.inactive-color = '#FFFFFF2E'

glass.tabs.enabled =       true
glass.tabs.height =        30          # height of the reserved strip
glass.tabs.spacing =       4           # gap between the strip and the windows below
glass.tabs.corner-radius = 10
glass.tabs.font-size =     12
glass.tabs.show-icons =    true
glass.tabs.bar-tint =      '#00000038'  # the ramp: dim strip,
glass.tabs.inactive-tint = '#00000047'  # unselected a shade darker,
glass.tabs.active-tint =   '#FFFFFFD1'  # selected lightest
```

> **TOML gotcha:** these are dotted keys, so they must appear *before* the first `[table]` header in
> your config. Placed after one they become keys of that table and the config fails to parse.

An i3-style keybinding set:

```toml
[mode.main.binding]
alt-period = 'layout tabbed tiles'   # toggle a tab group
alt-h = 'split horizontal'
alt-v = 'split vertical'
alt-left = 'focus left'              # steps through tabs, then out of the group
alt-right = 'focus right'
alt-shift-left = 'move left'         # moves a window into or out of a tab group
alt-shift-right = 'move right'
```

### Building and installing

Requires macOS 26 for Liquid Glass (it builds and runs on macOS 13+, using blur materials instead).

```bash
swift build -c release --product AeroSpaceApp
swift build -c release --product aerospace
```

Upstream's `build-release.sh` additionally wants bash 5, Ruby, Rust and a signing certificate. To
install without those, assemble a bundle from an existing AeroSpace.app — keeping its `Info.plist`,
icon and assets — replace `Contents/MacOS/AeroSpace` with the binary above, re-sign ad-hoc with
`codesign --force --deep -s -`, and put the `aerospace` CLI on your `PATH`. Keep the
`bobko.aerospace` bundle identifier: the CLI socket and your Accessibility grant both key off it.

### Compatibility

The new config keys and layout are fork-only. Stock AeroSpace rejects `layout tabbed` outright:

```
ERROR: Can't parse 'tabbed'
```

so a config using `tabbed`, the `glass.*` keys, or `split` under the flatten normalization will not
load there. Keep that in mind before switching back to a release build.

### Relationship to upstream

`main` tracks upstream; the work lives on `glass`. To pull upstream changes:

```bash
git fetch upstream && git rebase upstream/main
```

The fork touches the tree model (`TilingContainer`, `normalizeContainers`), the layout pass, and
adds `Sources/AppBundle/ui/glass/`. Upstream issue
[#1215](https://github.com/nikitabobko/AeroSpace/issues/1215) proposes rewriting `TreeNode` as an
immutable persistent tree, which would conflict heavily.

Licensed MIT, same as upstream. Copyright (c) 2023 Nikita Bobko.

---

Videos:
- [YouTube 91 sec Demo](https://www.youtube.com/watch?v=UOl7ErqWbrk)
- [YouTube Guide by Josean Martinez](https://www.youtube.com/watch?v=-FoWClVHG5g)

Docs:
- [AeroSpace Guide](https://nikitabobko.github.io/AeroSpace/guide)
- [AeroSpace Commands](https://nikitabobko.github.io/AeroSpace/commands)
- [AeroSpace Goodies](https://nikitabobko.github.io/AeroSpace/goodies)

## Key features

- Tiling window manager based on a [tree paradigm](https://nikitabobko.github.io/AeroSpace/guide#tree)
- [i3](https://i3wm.org/) inspired
- Fast workspaces switching without animations and without the necessity to disable SIP
- AeroSpace employs its [own emulation of virtual workspaces](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces) instead of relying on native macOS Spaces due to [their considerable limitations](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces)
- Plain text configuration (dotfiles friendly). See: [default-config.toml](https://nikitabobko.github.io/AeroSpace/guide#default-config)
- CLI first (manpages and shell completion included)
- Doesn't require disabling SIP (System Integrity Protection)
- [Proper multi-monitor support](https://nikitabobko.github.io/AeroSpace/guide#multiple-monitors) (i3-like paradigm)

## Installation

Install via [Homebrew](https://brew.sh/) to get autoupdates (Preferred)

```
brew install --cask nikitabobko/tap/aerospace
```

In multi-monitor setup please make sure that monitors [are properly arranged](https://nikitabobko.github.io/AeroSpace/guide#proper-monitor-arrangement).

Other installation options: https://nikitabobko.github.io/AeroSpace/guide#installation

> [!NOTE]
> By using AeroSpace, you acknowledge that it's not [notarized](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution).
>
> Notarization is a "security" feature by Apple.
> You send binaries to Apple, and they either approve them or not.
> In reality, notarization is about building binaries the way Apple likes it.
>
> I don't have anything against notarization as a concept.
> I specifically don't like the way Apple does notarization.
> I don't have time to deal with Apple.
>
> [Homebrew installation script](https://github.com/nikitabobko/homebrew-tap/blob/main/Casks/aerospace.rb) is configured to
> automatically delete `com.apple.quarantine` attribute, that's why the app should work out of the box, without any warnings that
> "Apple cannot check AeroSpace for malicious software"

## Community, discussions, issues

AeroSpace project doesn't accept Issues directly - we ask you to create a [Discussion](https://github.com/nikitabobko/AeroSpace/discussions) first.
Please read [CONTRIBUTING.md](./CONTRIBUTING.md) for more details.

Community discussions happen at GitHub Discussions.
There you can discuss bugs, propose new features, ask your questions, show off your setup, or just chat.

There are 7 channels:
-   [#all](https://github.com/nikitabobko/AeroSpace/discussions).
    [RSS](https://github.com/nikitabobko/AeroSpace/discussions.atom?discussions_q=sort%3Adate_created).
    Feed with all discussions.
-   [#announcements](https://github.com/nikitabobko/AeroSpace/discussions/categories/announcements).
    [RSS](https://github.com/nikitabobko/AeroSpace/discussions/categories/announcements.atom?discussions_q=category%3Aannouncements+sort%3Adate_created).
    Only maintainers can post here.
    Highly moderated traffic.
-   [#announcements-releases](https://github.com/nikitabobko/AeroSpace/discussions/categories/announcements-releases).
    [RSS](https://github.com/nikitabobko/AeroSpace/discussions/categories/announcements-releases.atom?discussions_q=category%3Aannouncements-releases+sort%3Adate_created).
    Announcements about non-patch releases.
    Only maintainers can post here.
-   [#feature-ideas](https://github.com/nikitabobko/AeroSpace/discussions/categories/feature-ideas).
    [RSS](https://github.com/nikitabobko/AeroSpace/discussions/categories/feature-ideas.atom?discussions_q=category%3Afeature-ideas+sort%3Adate_created).
-   [#general](https://github.com/nikitabobko/AeroSpace/discussions/categories/general).
    [RSS](https://github.com/nikitabobko/AeroSpace/discussions/categories/general.atom?discussions_q=sort%3Adate_created+category%3Ageneral).
-   [#potential-bugs](https://github.com/nikitabobko/AeroSpace/discussions/categories/potential-bugs).
    [RSS](https://github.com/nikitabobko/AeroSpace/discussions/categories/potential-bugs.atom?discussions_q=category%3Apotential-bugs+sort%3Adate_created).
    If you think that you have encountered a bug, you can discuss your bugs here.
-   [#questions-and-answers](https://github.com/nikitabobko/AeroSpace/discussions/categories/questions-and-answers).
    [RSS](https://github.com/nikitabobko/AeroSpace/discussions/categories/questions-and-answers.atom?discussions_q=category%3Aquestions-and-answers+sort%3Adate_created).
    Everyone is welcome to ask questions.
    Everyone is encouraged to answer other people's questions.

## Project status

Public Beta. AeroSpace can be used as a daily driver, but expect breaking changes until 1.0 is reached.

What stops us from 1.0 release:
- [x] https://github.com/nikitabobko/AeroSpace/issues/131 Performance. Implement thread-per-application to circumvent macOS blocking AX API.
- [ ] https://github.com/nikitabobko/AeroSpace/issues/1215 _Big refactoring_. Rewrite mutable double-linked core tree data structure to immutable single-linked persistent tree.
  Important for: stability and potential performance
  - [ ] https://github.com/nikitabobko/AeroSpace/issues/1216 The big refactoring will help us to fix stability issue that windows may randomly jump to the focused workspace
  - [ ] https://github.com/nikitabobko/AeroSpace/issues/68 The big refactoring will help us to support macOS native tabs
- [x] https://github.com/nikitabobko/AeroSpace/issues/278 Implement shell-like combinators.
  Ignore a lot of crazy fuss in the issue,
  We are most probably going with the minimal approach to only introduce common shell-combinators: `||`, `&&`, `;` and `eval` command to send multiple commands in one go.
- [ ] https://github.com/nikitabobko/AeroSpace/issues/1012 Investigate a possibility to use `CGEvent.tapCreate` API for global hotkeys
  - [ ] https://github.com/nikitabobko/AeroSpace/issues/28 Maybe it will allow to distinguish left and right modifiers. Maybe not

Big and important issues which will go after 1.0 release:
- [ ] https://github.com/nikitabobko/AeroSpace/issues/2 sticky windows
- [ ] https://github.com/nikitabobko/AeroSpace/issues/260 Dynamic TWM

## Development

A notes on how to setup the project, build it, how to run the tests, etc. can be found here: [dev-docs/development.md](./dev-docs/development.md)

## Project values

**Values**
- AeroSpace is targeted at advanced users and developers
- Keyboard centric
- Breaking changes (configuration files, CLI, behavior) are avoided as much as possible, but it must not let the software stagnate.
  Thus breaking changes can happen, but with careful considerations and helpful message.
  [Semver](https://semver.org/) major version is bumped in case of a breaking change (It's all guaranteed once AeroSpace reaches 1.0 version, until then breaking changes just happen)
- AeroSpace doesn't use GUI, unless necessarily
  - AeroSpace will never provide a GUI for configuration.
    For advanced users, it's easier to edit a configuration file in text editor rather than navigating through checkboxes in GUI.
  - Status menu icon is ok, because visual feedback is needed
- Provide _practical_ features. Fancy appearance features are not _practical_ (e.g. window borders, transparency, animations, etc.)
- "dark magic" (aka "private APIs", "code injections", etc.) must be avoided as much as possible
  - Right now, AeroSpace uses only a single private API to get window ID of accessibility object `_AXUIElementGetWindow`.
    Everything else is [macOS public accessibility API](https://developer.apple.com/documentation/applicationservices/axuielement_h).
  - AeroSpace will never require you to disable SIP (System Integrity Protection).
  - The goal is to make AeroSpace easily maintainable, and resistant to macOS updates.

**Non Values**
- Play nicely with existing macOS features.
  If limitations are imposed then AeroSpace won't play nicely with existing macOS features
  (For example, AeroSpace doesn't acknowledge the existence of macOS Spaces, and it uses [emulation of its own workspaces](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces))
- Ricing.
  AeroSpace provides only a very minimal support for ricing - gaps and a few callbacks for integrations with bars.
  The current maintainer doesn't care about ricing.
  Ricing issues are not a priority, and they are mostly ignored.
  The ricing stance can change only with the appearance of more maintainers.

## macOS compatibility table

* AeroSpace binary runs on: macOS 13+
* AeroSpace debug build from sources is supported on: macOS 14+
* AeroSpace release build from sources is supported on: macOS 15+ (Requires Xcode 26+)

## Sponsorship

AeroSpace is developed and maintained in my free time.
If you find it useful, [consider sponsoring](https://github.com/sponsors/nikitabobko#sponsors).

## People who have write access

In alphabetical order:

- [@mobile-ar](https://github.com/mobile-ar)
- [@nikitabobko](https://github.com/nikitabobko)
- [@rickyz](https://github.com/rickyz)

## Tip of the day

```bash
defaults write -g NSWindowShouldDragOnGesture -bool true
```

Now, you can move windows by holding `ctrl`+`cmd` and dragging any part of the window (not necessarily the window title)

Source: [reddit](https://www.reddit.com/r/MacOS/comments/k6hiwk/keyboard_modifier_to_simplify_click_drag_of/)

## Related projects

- [Amethyst](https://github.com/ianyh/Amethyst) - tiling window manager à la xmonad
- [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) - Instant space switching by synthesizing trackpad gesture with an artificially high velocity
- [yabai](https://github.com/koekeishiya/yabai) - a tiling window manager for macOS based on binary space partitioning
