# DESIGN.md — Zennox Music Player

> Source of truth for how the app looks and feels on every platform. Propose changes here first.

Design Read: personal lossless music player for people who own their files, product surface,
artwork-first quiet minimal on native chrome (Liquid Glass on Apple, Material 3 on Android,
Fluent on Windows), SwiftUI / Compose / WinUI.
Dials: Variance 3 · Motion 3 · Density 6

## 1. Visual theme & atmosphere
The music is the colour. Chrome is near-monochrome and recedes; album artwork carries the
mood. Typography is calm system type with tabular numerals for times and audio specs. The app
should feel like a well-made hi-fi component: precise, quiet, honest about quality. It must
never feel like a streaming service storefront: no carousels of "for you", no promos, no
gradient hero banners.

## 2. Colour palette & roles
One accent ("Zennox amber"), everything else tinted neutral (hue 60, very low chroma).
Platform constants are generated from this table (Swift `ZennoxTheme`, Kotlin `ZennoxColors`).
| Role | Light (OKLCH) | Dark (OKLCH) | Use |
|---|---|---|---|
| bg | oklch(98.5% 0.004 60) | oklch(16% 0.006 60) | Window / screen background |
| surface | oklch(100% 0 0) | oklch(20% 0.008 60) | Lists, sheets |
| surface2 | oklch(95.5% 0.006 60) | oklch(25% 0.009 60) | Mini-player, grouped rows |
| text | oklch(21% 0.01 60) | oklch(94% 0.006 60) | Primary text |
| textMuted | oklch(46% 0.012 60) | oklch(71% 0.01 60) | Artist, album, durations |
| border | oklch(90% 0.006 60) | oklch(31% 0.008 60) | Hairlines |
| accent | oklch(62% 0.15 62) | oklch(76% 0.13 70) | Play, current track, focus fallback |
| accentContrast | oklch(18% 0.02 60) | oklch(18% 0.02 60) | Text/icons on accent |
| lossless | oklch(52% 0.09 165) | oklch(74% 0.09 165) | "Lossless" quality badge only |
| warning / danger | oklch(70% 0.15 80) / oklch(56% 0.19 28) | oklch(80% 0.13 85) / oklch(68% 0.16 28) | Missing file / errors only |
On Apple, prefer semantic system colours (`.primary`, `.secondary`, system backgrounds) and use
the table only for accent, lossless and states. Now Playing may tint its background from the
artwork's dominant colour, clamped to L 20–35% (dark) / 88–96% (light) so text keeps AA contrast.

## 3. Typography
- System fonts only (SF on Apple, Roboto Flex on Android, Segoe UI Variable on Windows) via
  platform text styles so Dynamic Type / font scaling work. No bundled fonts.
- Display moments: Now Playing title uses `.title2.weight(.semibold)`; album headers `.largeTitle`.
- Audio specs (e.g. "FLAC · 24-bit · 96 kHz · Stereo") and times use monospaced digits
  (`.monospacedDigit()`), `.caption` size, textMuted.

## 4. Component styling
- Track row: 56 pt min height, artwork 40 pt radius 6, title + artist/album two lines, trailing
  duration; source glyph (SF Symbol `internaldrive` / `icloud`-style cloud glyph for Drive) and
  favourite heart only when relevant. Missing files: row at 50% opacity + warning glyph + "File
  missing" text (never colour alone).
- Quality badge: small capsule, text "Lossless" or codec name; lossless colour only when codec is
  FLAC/ALAC/PCM (from decoded format, never the extension).
- Mini-player: control layer → Liquid Glass on iOS 26+ / macOS 26+, surface2 fallback; artwork,
  title, play/pause (44 pt), next; tap opens Now Playing.
- Buttons: system styles; primary play = `.glassProminent` tinted accent on Apple.
- Icons: SF Symbols (Apple), Material Symbols Rounded (Android), Fluent System Icons (Windows).
  Never emoji.
- Every interactive element: pressed, focused (keyboard), disabled, loading states.

## 5. Layout principles
- Macrostructure: iPhone/Android phone = tab bar (Home · Library · Search) + navigation stacks +
  persistent mini-player; iPad/macOS/Windows = sidebar (Library sections, Playlists) + content
  list + Now Playing inspector/bottom bar. Master-detail, not dashboards.
- Home is a plain list of sections: Recently Played, Recently Added, Favorites shortcut. No cards grid.
- Spacing scale (pt): 4 · 8 · 12 · 16 · 24 · 32 · 48.

## 6. Depth & elevation
Flat content; glass only on control layer (tab bar, toolbar, mini-player, Now Playing controls).
Radii: artwork small 6 · large 12 · sheets system. No drop shadows except Now Playing artwork
(one soft shadow).

## 7. Do's and don'ts
- Do: show true format and source honestly; explain empty states with a first action
  ("Add music from this Mac", "Choose songs from Google Drive").
- Do: undo for destructive library actions (remove from playlist, unfavourite).
- Don't: label lossy as lossless; claim "Hi-Res" based on file alone (output device may resample —
  show "Output: 48 kHz" separately when known).
- Don't: purple-pink gradients, emoji icons, equal card grids, glow, autoplaying visuals.

## 8. Responsive behaviour
- Compact width → tabs; regular width → sidebar. Window min 720×480 on desktop.
- Touch targets ≥ 44 pt / 48 dp; desktop: full keyboard (Space play/pause, ⌘/Ctrl+→ next,
  ⌘/Ctrl+F search, ⌘/Ctrl+L favourite), menu bar items for every action on macOS.
- Reduce Motion: artwork transitions become cross-fades; Reduce Transparency: solid surface2.

## 9. Agent prompt guide
- "Build <screen> following DESIGN.md: master-detail, density 6, system text styles, glass on
  controls only, include empty/loading/error states."
- Motion tokens: fast 150 ms, base 250 ms, spring(response 0.35, damping 0.85); none for list updates.
