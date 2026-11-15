# Mac App Store screenshots

Five screenshots per language, 2880 × 1800 (16:10), RGB PNG without alpha.
`contact-sheet.png` shows both sets at a glance. Nothing here has been uploaded
to App Store Connect.

| # | File | zh-Hans | en |
|---|------|---------|----|
| 1 | `01-hero.png` | 刘海里，藏着一页笔记 / 鼠标移到屏幕顶部，笔记就从刘海里展开。 | A notepad, tucked in the notch. / Move to the top of the screen and your note unfolds from the island. |
| 2 | `02-hover.png` | 不用时，它就是刘海 / 安静地收在屏幕顶端。悬停即可唤出，移开自动收起。 | Out of sight until you need it. / It rests quietly in the notch. Hover to open, move away to tuck it back. |
| 3 | `03-markdown.png` | Markdown，边写边排版 / 标题、待办、引用实时渲染。写完按 Esc，随手收起。 | Markdown, rendered as you type. / Headings, to-dos and quotes render live. Press Esc to put it away. |
| 4 | `04-drag.png` | 一拖，就成浮动便签 / 拖出来放在任意位置，边角自由缩放；拖回刘海，自动吸附归位。 | Pull it out. Pin it anywhere. / Drag the note free, resize from any edge, and drop it back to snap home. |
| 5 | `05-file.png` | 就是一个 Markdown 文件 / 存在你选的位置，iCloud Drive、Obsidian 库都可以。无需账号，不联网。 | Just a Markdown file. Yours. / Keep it anywhere, from iCloud Drive to your Obsidian vault. No account, no network. |

Flomo sync isn't advertised: the App Store build runs sandboxed without network access.

## How they are made

- **Real UI.** `capture/run.sh` clones the repo into `/tmp`, applies
  `capture/shots-harness.patch`, and builds a debug binary with its own bundle
  id (`local.projects.island-note.shots`). The patch is env-driven and only
  active under `ISLAND_SHOTS_*`. It uses a demo note in `/Users/Shared/Island Note`
  and a temporary config folder, never touches flomo, and pins one state
  (rest, hover, expanded, floating, docking, or settings). Each window is captured with
  `screencapture -l` at 2×, alongside a JSON of window frames and screen geometry.
  The driver removes the demo note and prefs afterwards.
- **Scene.** `tools/compose.py` (skia-python) puts the captured windows at their
  real screen positions on a 1512 × 982 pt MacBook Pro 14" display with the
  macOS 27 "Celosia" light wallpaper, a transparent menu bar, the 185 × 32 pt
  notch (from `NSScreen.auxiliaryTopLeftArea`/`safeAreaInsets`) and the app's
  own `StatusIcon.svg`.
- **Corners.** Every shape the compositor draws (display, bezel, lip, notch,
  cards, emblems) uses the same 60%-smoothing continuous corner construction
  as `Resources/AppIcon.svg`. The display, bezel and lip radii are concentric
  (10.5 + 15 + 2.2 pt, scaled with the device). App windows keep their captured radii.
- **Texture.** The backdrop follows zhuhanyu.me: #f4f2ec paper, a 12 pt dot grid
  (0.95 pt dots, ink at 8.5%), and a few faint floating dot-matrix emblems
  around the headline. Nothing is drawn over the app UI.

Fonts (SF Pro / PingFang, copied from macOS) and the wallpaper are not committed.
To re-render, put `SFNS.ttf`, `PingFang.ttc`, static SF instances (`assets/inst/`,
see the font helper in `compose.py`) and `Gold-Gate-wallpaper.png` in `assets/`,
the capture output in `out/`, and `StatusIcon.svg` in `src-res/`.
