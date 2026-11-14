# livetest

Live-testing harness library for GUI apps: starts the app per case,
drives keyboard and pointer, screenshots the window, compares shots with
golden PNGs. Modes: `kde` (the user's Plasma session), `sway` (nested),
`offscreen` (the app's worker). Namespace `Livetest`. Usage and the case
grammar: README.md. First user: asekii's harness (`../asekii/test`).

## Layout

```
.
├─╴src/livetest.cr             # Livetest.run(args, subject)
├─╴src/livetest/
│  ├─╴subject.cr               # Subject: the app (public, abstract)
│  ├─╴terminal.cr              # Terminal < Subject: size/font/run keys
│  ├─╴case.cr                  # Case, Field, Item (public); steps :nodoc:
│  ├─╴worker.cr                # Worker, Surface: worker side of offscreen
│  ├─╴cli.cr runner.cr app.cr  # command line, case runner, app process
│  ├─╴backend.cr backends/     # kde, sway, offscreen
│  ╰─╴kwin dbus uinput wayland keymap input image screenshot setup abort
╰─╴spec/                       # case parsing, worker protocol, images, keymap
```

## Extension points

- `Subject` (public): `name`, `arguments(test, app_id)`; optional
  `binary`, `keys`, `check`, `env`, `worker`, `cleanup`. Runner calls
  `cleanup(dir)` before each case and in its `ensure`.
- Extra case keys: `Case.read(path, subject.keys)` keeps them as
  `Case::Field` (items with lines); `Subject#check` validates at load
  time, raising `field.error(msg[, item])` → `path:line: msg`.
- `Terminal#options(test)` parses `size`/`font`/`run`; `default_font`
  hook; `env` sets `SHELL=/bin/sh`, `PS1='$ '`, `ENV` unset,
  `HISTFILE=<dir>/history`.
- Environment: app gets `LIVETEST_FIFO`, `LIVETEST_DIR`; offscreen
  worker gets `LIVETEST_CONTROL` (socket) and `LIVETEST_KEYMAP` (xkb
  file). App ids `livetest-<pid>-<n>`; tmp dirs `livetest-<pid>`.
- Worker protocol (`Worker#run`, :nodoc: table there): one line per
  command, answers `ok [words]` / `error message`; `shot` answers
  `ok W H` then W*H*4 RGBA bytes. Surface exceptions fail only the
  command.
- `kde` setup: `HARNESS setup` writes
  `applications/<basename>.desktop` so KWin grants ScreenShot2.

## Commands

```
make spec       crystal spec
make docs       crystal docs src/livetest.cr src/livetest/worker.cr
make clean      rm -rf lib shard.lock docs
```

- Format only touched files: `dev crystal tool format <files>`.
- Docs check: `crystal docs src/livetest.cr src/livetest/worker.cr -o
  /tmp/<dir>`, then delete it. Public: `Livetest.run`, `VERSION`,
  `Subject`, `Terminal`(+`Options`), `Case`(+`Field`, `Item`, `Error`),
  `Worker`(+`Surface`, `Error`). Everything else `:nodoc:` or private.

## Modes

- `kde`: takes over the real keyboard and pointer: never run unasked.
  KWin places and screenshots, input through uinput. ScreenShot2 keeps
  the window's alpha (usually premultiplied); `Screenshot.decode`
  composites over black to match grim's opaque output captures. Escape three times
  within a second aborts. A KWin script reports activations; each key
  press checks the case's window is active, else fails the case.
  wl-clipboard < 2.3.0 steals focus; clipboard steps give it back.
- `sway`: nested, headless or a window (`-S`); Wayland virtual input,
  `grim`. Pointer hidden by a generated 1x1 transparent cursor theme
  (never `hide_cursor`: drops pointer focus).
- `offscreen`: `Subject#worker` over a socket per case.

## Code standards

- Compiler-friendly, performance-focused, idiomatic Crystal.
- Data-driven: tables and records over branches.
- Ergonomic public API. One change, one place.
- No stubs, no placeholders, nothing unasked. Never change shard.yml's
  version.
- Visibility: `private` internal, `protected` same-namespace callers,
  `# :nodoc:` first doc line for public-but-internal code. Check with
  `crystal docs`.
- Doc comments: third person present, *param* italic, backtick
  references, `:ditto:`; no implementation details; public docs never
  reference private or `:nodoc:` code.
- README.md and AGENTS.md in sync with the code.
- Work on `dev`, never `main`. Prefix file-changing shell commands with
  `dev`.
