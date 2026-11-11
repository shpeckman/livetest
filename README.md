# livetest

Live-testing harness for GUI apps. It starts the app per test case,
drives it with keyboard and pointer input, screenshots its window and
compares the shots with golden PNGs. A built-in `Livetest::Terminal`
covers terminal emulators.

| Mode (`-m`)     | Where the app runs                           | Screenshots      |
|-----------------|----------------------------------------------|------------------|
| `kde` (default) | your KDE Plasma session                      | KWin ScreenShot2 |
| `sway`          | a nested sway, headless or windowed (`-S`)   | `grim`           |
| `offscreen`     | the app's worker on a headless display       | framebuffer      |

`kde` mode **takes over your keyboard and pointer**; press Escape three
times within a second to abort. The modes share the goldens.

## Requirements

- Crystal >= 1.22, libxkbcommon and libwayland-client.
- `kde`: KDE Plasma 6 on Wayland, write access to `/dev/uinput`, read
  access to `/dev/input/event*`, `kbuildsycoca6`.
- `sway`: sway and `grim`.
- `offscreen`: a worker executable from the app (see below).
- `wl-clipboard` for clipboard steps in `kde` and `sway`.

## Installation

```yaml
dependencies:
  livetest:
    github: shpeckman/livetest
```

## Usage

The harness is an executable of your own: describe the app with a
`Livetest::Subject` and hand it to `Livetest.run`. The app must take the
given app id as its window class (Wayland app id).

```crystal
require "livetest"

class MyApp < Livetest::Subject
  def name : String
    "myapp"
  end

  def arguments(test : Livetest::Case, app_id : String) : Array(String)
    ["--class", app_id]
  end
end

exit Livetest.run(ARGV, MyApp.new)
```

A `Subject` may also declare extra case keys (`#keys`, validated in
`#check`), add environment (`#env`), clean up after the app (`#cleanup`)
and name its offscreen worker (`#worker`).

For a terminal emulator subclass `Livetest::Terminal`: cases take
`size`, `font` and `run`, and the shell is `/bin/sh` with `PS1='$ '`, no
`ENV` and its history in the case's output directory, so shell output
matches on every machine.

```crystal
class MyTerm < Livetest::Terminal
  def name : String
    "myterm"
  end

  def arguments(options : Options, app_id : String) : Array(String)
    ["--size", "#{options.cols}x#{options.rows}", "--class", app_id,
     "-e", "sh", "-c", options.command]
  end
end
```

The resulting executable:

```
HARNESS [-m MODE] [-S] [-b BINARY] [-c FILE] [-o DIR] [-u] [-x] [-v] [CASE...]
HARNESS setup
```

Runs the named cases of the cases file, all of them when none are named,
in the file's order. `-b` app executable (default `Subject#binary`), `-c`
cases file (default `cases.yml`), `-o` output directory (default `out`),
`-u` write goldens, `-x` stop at the first failure, `-v` verbose. Exit
status: 0 all passed, 1 a case failed, 2 usage or cases-file error. Each
case writes `out/<case>/`: the app's log, the shots and
`<shot>.diff.png` on mismatch. `setup` lets the executable take window
screenshots in `kde` mode; run it once per executable path.

The app gets `LIVETEST_FIFO`, a FIFO its commands signal the harness
through (`echo LINE > "$LIVETEST_FIFO"`, awaited by `expect LINE`), and
`LIVETEST_DIR`, the case's output directory.

## Offscreen worker

Mode `offscreen` runs `Subject#worker`, an executable that takes the
app's arguments and runs the app's window code without a compositor. It
requires `livetest/worker`, implements `Livetest::Worker::Surface` for
its window, reads the keymap the key codes refer to from
`Livetest::Worker.keymap` and polls `Livetest::Worker#fd`:

```crystal
require "livetest/worker"

worker = Livetest::Worker.new(MySurface.new(window))
loop.watch(worker.fd) { worker.readable }
```

## Cases file

`cases.yml` maps each case name (letters, digits, `_`, `.`, `-`) to its
keys and its `steps`, a list of strings; `#` starts a comment. Quote a
string that holds `: ` or ` #`; single quotes keep backslashes for the
escapes below. Coordinates are logical pixels in the window's client
area. Goldens live in `goldens/<case>/<shot>.png` next to the cases
file.

| Key                            | Meaning                                  | Default                   |
|--------------------------------|------------------------------------------|---------------------------|
| `at: X Y`                      | position of the client area              | `100 100`                 |
| `timeout: SECONDS`             | limit for the whole case                 | `30`                      |
| `modes: [MODE, …]`             | runs only in these modes                 | every mode                |
| `steps: [STEP, …]`             | the steps below, in order                |                           |

`Livetest::Terminal` adds:

| Key                            | Meaning                                  | Default                   |
|--------------------------------|------------------------------------------|---------------------------|
| `size: COLSxROWS`              | terminal size                            | `80x24`                   |
| `font: NAME`                   | font; a path with `/` is relative to the cases file | `Terminal#default_font` |
| `run: COMMAND`                 | shell command (`sh -c`)                  | `exec sleep infinity`     |

| Step                                  | Meaning                                              |
|---------------------------------------|------------------------------------------------------|
| `expect TEXT`                         | waits for the line TEXT on the FIFO                  |
| `type TEXT`                           | types TEXT                                           |
| `key COMBO...`                        | presses combinations: `ctrl+shift+c`, `Return`       |
| `press KEY` / `release KEY`           | holds or releases a key                              |
| `move X Y`                            | moves the pointer                                    |
| `click [BUTTON] [COUNT]`              | clicks (`left`, `middle`, `right`; default `left 1`) |
| `down [BUTTON]` / `up [BUTTON]`       | presses or releases a button                         |
| `drag X1 Y1 X2 Y2 [BUTTON]`           | drags from the first point to the second             |
| `scroll DY [DX]`                      | wheel clicks; positive is down or right              |
| `sleep MS`                            | waits                                                |
| `settle`                              | waits until the window stops changing                |
| `shoot NAME [tolerance=N] [pixels=N] [mask=X,Y,W,H]...` | screenshots and compares with the golden |
| `clipboard TEXT`                      | the clipboard equals TEXT within 3 s                 |
| `copy TEXT`                           | puts TEXT on the clipboard                           |
| `resize WIDTH HEIGHT`                 | resizes the client area                              |
| `title TEXT`                          | the window title equals TEXT within 3 s              |
| `close`                               | closes the window; the app must exit                 |
| `exit [CODE]`                         | the app exits, optionally with status CODE           |

Text arguments decode `\n`, `\r`, `\t`, `\e`, `\s`, `\\`, `\xHH` and
`\u{H...}`.

```yaml
# Selects a word by dragging, copies it and checks the clipboard.
selection:
  size: 30x5
  run: |-
    printf 'alpha bravo charlie\n'; echo shown > "$LIVETEST_FIFO"; exec sleep infinity
  steps:
    - expect shown
    - copy nothing
    - drag 4 8 40 8
    - key ctrl+shift+c
    - clipboard alpha
```

## License

MIT, see `LICENSE`.
