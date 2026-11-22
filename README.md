# MKV Pipeline

A macOS app for working through a folder of MKV files: compare them in a grid, inspect
one in detail, preview it in a floating player, fix its headers in MKVToolNix, and
archive it into Movies, Documentaries or TV Shows.

## Requirements

- macOS 14 or later
- Swift 6 toolchain — the Xcode Command Line Tools are enough, Xcode itself is not needed
- [Homebrew](https://brew.sh) libraries: `brew install mpv libmediainfo`
- [MKVToolNix](https://mkvtoolnix.download) in `/Applications`, for **Edit MKV headers** and for
  editing segment titles (a Homebrew `mkvtoolnix` also works for the latter)

The app links against the Homebrew copies of libmpv and libmediainfo, so the built
bundle runs on the machine it was built on rather than being redistributable.

## Build and run

```sh
Scripts/build-app.sh            # release build → build/MKV Pipeline.app
open "build/MKV Pipeline.app"

Scripts/test.sh                 # unit tests; arguments are passed to `swift test`
```

The tests include one playback test that starts libmpv (muted) for a few seconds.

## Using it

**Top bar**

- **MKV folder** – the folder to list. Type or paste a path and press Return, or use
  the **Change…** button inside the box. **Include subfolders** finds files recursively.
- **Archive folder** – parent of the `Movies`, `Documentaries` and `TV Shows` folders
  that **Archive** moves files into. Those three folders are left out of the listing
  when the archive folder sits inside the MKV folder.
- **Filter** – a case-insensitive regular expression matched against filename, relative
  path and segment title. The star at the right of the box saves the current filter
  (click a filled star to remove it); the magnifying glass lists the saved ones.
- **Refresh metadata** – looks for new and removed files and reads every file's
  media info again. (Switching back to the app already picks up changed files.)

The status bar at the bottom shows what is in progress – scanning the folder, reading
media info (with a count and the file just read), archiving – and a progress bar.

**Grid** – Filename, File size, Relative path, Segment title, Video resolution and Audio
tracks. Right-click the header to show or hide columns, drag headers to rearrange them,
click one to sort. Audio tracks lists each language with its number of tracks as a
badge. Double-click a row to preview it; right-click it for Open (in the default
application), Preview, Edit MKV headers, Archive… and Show in Finder.

**Sidebar** – segment title, filename and size; path and created / modified dates;
media details from MediaInfo – video (duration, codec, bitrate, dimensions, source)
and one row per audio track (title, codec, language, channels). Files are read in
MediaInfo's fastest mode (headers and first packets only), so a large library lists
quickly; frame rate, which that mode cannot always determine, is not shown. The
pencil next to the title edits it: Return writes the new segment title into the file
with `mkvpropedit`, Esc cancels, and an empty title removes it. Then the actions:

- **Preview** opens the floating preview window.
- **Edit MKV headers** opens the file in MKVToolNix's header editor. The list refreshes
  when you switch back.
- **Archive…** asks for Movies, Documentaries or TV Shows and moves the file there.
  It never overwrites an existing file, and a move to another volume is copied in
  full and flushed to disk before the original is removed.

**Preview window** – a resizable floating panel that stays open and follows the
selection in the grid: selecting a row loads that file paused on its first frame, while
an explicit Preview (the sidebar button, a double-click, the context menu or `P`) plays
it. Its size and position are remembered. Play / pause, rewind and
fast-forward at 2×, 3× and 4×, a seekable timeline, audio and subtitle track menus,
volume, and the segment title, filename and duration. Click the picture to play or
pause; drag it to move the panel. Audio is silent while rewinding.

**Keyboard shortcuts** – active in the main window and the preview, except while
typing in a text field. Press `?` to see them on screen. The playback keys need the
preview open; `O`, `E` and `A` act on the selected file.

| Key | Action |
| --- | --- |
| `Space` | Play / pause |
| `[` / `]` | Slower, then reverse / faster: −4× −3× −2× 1× 2× 3× 4× |
| `←` / `→` | Back / forward one minute |
| `-` / `+` | Volume down / up |
| `F` | Full screen (`Esc` leaves it) |
| `P` | Open or close the preview |
| `O` | Open in the default application |
| `E` | Edit MKV headers |
| `A` | Archive… |
| `?` | Show or hide the shortcut list |

## Layout

| Path | Contents |
| --- | --- |
| `Sources/MKVPipelineCore` | Folder scanning, MediaInfo reading and parsing, search filter, file moves |
| `Sources/MKVPipeline` | The SwiftUI app, and the libmpv-based player in `Player/` |
| `Sources/CMPV`, `Sources/CMediaInfo` | Module maps for the two C libraries |
| `Tests/MKVPipelineTests` | Unit tests and their small MKV fixtures |
| `Resources/Info.plist`, `Scripts/` | App bundle metadata, build and test scripts |
