# Termight guide

The details the README leaves out: keys, snippet rules, what each feature
does under the hood, and the limits worth knowing about.

## Keys

| Key | Does |
|---|---|
| Return | Run |
| ⇧Return | Run even if the command isn't recognized |
| ⌘Return | Open in Terminal |
| ⌥Return | Watch: run again every 2 seconds until Esc |
| Tab | Complete a command, path or snippet name |
| ↑ / ↓ | History, showing each command's last output without running it; or move through a snippet's choices |
| ⌃R | Search history; the highlighted command's last output shows below |
| ⇧⌘C / ⌘R / ⌘L | Copy all output / run again / open the full log |
| ⌘F | Find in the shown output; Return or ↓ next, ↑ previous |
| ⌘D | Compare with the previous kept run of the same command: new or changed lines are tinted |
| ⌘K | Keep this output, so newer runs never push it out (up to 5) |
| ⌘P | Pin the bar so it stays open and on top |
| Esc | Cancel or stop the running command, then clear, then close |

The dot next to what you type: green runs, blue opens in Terminal (or is a
snippet that will ask for values), orange isn't a command. With "Only run
recognized commands" on (the default), Return won't run an orange line;
⇧Return will.

Drag the bar to a screen edge to tile it, as with other windows: the left or
right edge for half the screen, a corner for a quarter, the top for the whole
screen. Drag it away from the edge and it goes back to its earlier size. It
follows System Settings → Desktop & Dock (tiling on or off, and margins), and
an edge shared with another display doesn't tile.

## Snippets

Type a snippet's name to run it. Words after the name fill its placeholders in
order; anything left over is added to the end of the command as you typed it.
Placeholders you didn't fill are asked for one at a time.

| Placeholder | Takes |
|---|---|
| `{name}`, `{name:default}` | Text, with an optional fallback |
| `{#name}`, `{#name:5}` | A whole number |
| `{env\|dev\|staging\|prod}` | One of the listed choices (`{env\|dev\|prod:prod}` preselects one) |
| `{!name}` | A secret from the Keychain |
| `{files}` | The files you sent from Finder |
| `{{name}}` | A literal `{name}` |

Not placeholders, so left alone: `${VAR}`, `@{upstream}`, `%{http_code}`,
`\{name}`, and braces that don't hold a plain name, like `{1..3}`, `{}` or
awk's `{print $1|"sort"}`.

### How values are passed

A value is never pasted into the command text. Termight hands it to the shell
as an environment variable and the command refers to that variable, so a value
stays one literal word whatever it contains: spaces, quotes, `;`, `$(…)`. That
holds unquoted and inside `'…'`, `"…"`, `$'…'`, `$(…)` and backticks.

Limits:

- **Arithmetic.** Shell arithmetic reads a variable's contents as an
  expression, and `a[$(cmd)]` in there runs `cmd`. So inside `$(( ))` and
  `(( ))` only `{#name}` and choices are allowed, and anywhere else a typed
  value containing `[` followed by `$` or a backtick is refused. In arithmetic
  Termight can't detect (`let`, `[[ a -eq b ]]`, array subscripts), a text
  value can still set a shell variable, such as `x=5`. Use `{#name}` there.
- **Commands that parse again.** If the snippet hands a value to something that
  parses it a second time (`eval {x}`, `sh -c {cmd}`, `ssh host {cmd}`), that
  program will read it as code. That's the snippet's choice, not something
  Termight can prevent.
- **Numbers** are plain whole numbers: an optional `-` and the digits 0–9,
  within 64 bits. `1.5`, `+3`, `1e3` and non-ASCII digits are refused. Leading
  zeros are dropped, so `010` is ten, not octal eight.
- **Choices** must match one of the listed options exactly. Options can't
  contain spaces.
- **Name clashes.** A snippet with the same name as a real command runs instead
  of it. Settings warns you when that happens. If two snippets share a name,
  the first one runs.

### Secrets

`{!token}` reads its value from your login keychain (service
`ca.nordqvist.termight.secret`). The first time, Termight asks in a hidden
field and saves what you type. Settings → Snippets lists saved secrets and lets
you replace or delete them.

- The value is never part of what you type, your history or the logs.
- If a command prints it, Termight shows `••••` instead, on screen and in the
  logs. That only covers values of 4 characters or more.
- While a command runs, the secret is in its environment, so other programs
  running as you could read it with `ps eww`.
- A snippet with a secret won't open in Terminal with ⌘Return, because that
  would write the value into a script file.
- Secret names can use only letters, digits and `_`.
- macOS may ask once to let a new build of Termight read its Keychain items.

### Files from Finder

Select files, right-click → Quick Actions → **Run in Termight**. The bar opens
in the files' folder with them attached. A snippet with `{files}` gets each
file as its own word; any other command gets the files added to its end.
Nothing runs until you press Return, and Esc drops the files.

- `{files}` only works unquoted. Inside quotes or `$( )` it's refused, because
  the files wouldn't stay one word each.
- A snippet that uses `{files}` can't be run by typing alone.
- **New Termight Command Here** on a folder opens the bar in that folder.
- If the actions don't show up, turn them on in System Settings → Keyboard →
  Keyboard Shortcuts → Services → Files and Folders. macOS can take a moment
  to list them after an install.

## Colors

With Show colors on (Settings → General → Window), commands run on a pseudo-terminal, as
they would in Terminal. Programs that only color for a terminal (`ls`, `git`,
`grep`) do, and output fits the bar's width.

- A pipe inside the command still gets plain text, so `ls | xargs …` behaves
  the way it does in Terminal.
- Pagers are set to print straight through (`PAGER`, `GIT_PAGER`, `MANPAGER`
  and others are set to `cat`), so `git log` doesn't wait for a keypress.
- Only colors and styles come through. Cursor movement is dropped, so
  full-screen and multi-line progress displays look rough. A one-line
  progress bar that redraws with `\r` shows only its latest state.
- There's still no keyboard input and no controlling terminal, so `sudo`
  password prompts and the like still need Terminal.
- A command that needs a real terminal, forced to run here with ⇧Return,
  runs without colors, so a pager prints and ends instead of waiting.
- Copy (⇧⌘C) and the logs are plain text.
- Turn colors off to run commands on a plain pipe, as earlier versions did.

## Window look

Settings → General → Window has themes, each a background, a text color and
an accent together: System, Amber, Phosphor, Matrix, Paper, Midnight, Winter,
Spring, Summer, Fall and Cyberpunk. Most also change the colors of command
output so `ls` and `git` match and stay readable: Matrix makes everything a
shade of green on pure black; Paper, Winter and Spring use dark inks on their
light backgrounds; Summer (sand and coral on deep sea) and Fall (amber and
rust on dark brown) use warm bright ones; Cyberpunk uses neon (hot pink,
electric cyan, acid yellow). System, Amber, Phosphor and Midnight keep the
usual output colors.
**Custom…** starts from what's set now and shows the detailed controls:
background (System or a color) and text (Automatic or a color).

Opacity (30% to 100%) and blur apply to every theme. Opacity sets how much
shows through: lower opacity thins the frost as well as the color, down to a
faint frost at 30%. With blur off, the bar is plain see-through at your
opacity. When text might be hard to read over some desktops (under 4.5:1
contrast over pure black or pure white behind the bar), Settings says so; it
doesn't stop you.

With Automatic text on a color, text is dark or light, whichever has more
contrast with that color. A chosen text color is used for what you type and
for output without colors of its own; output with its own colors keeps them
(or a theme's own), and secondary text is the same color, fainter. Reset goes
back to the System theme at 100% with blur and colors on.

## Watch

⌥Return runs a command, then runs it again every 2 seconds (Settings →
Commands) until you press Esc. Each run's output appears when that run
finishes, with lines that changed since the previous run highlighted. Only the
lines that are new or different are marked, so one inserted line marks just
itself. Above about 2,000 lines per run, lines are compared by position
instead, and one inserted line marks everything below it.
Commands that need a real terminal can't be watched. A watched command goes into
your history once, not on every run.

## Menu bar output

Settings → Menu Bar holds up to five commands. Each gets its own menu bar item
showing the first line of its output, refreshed on its own schedule (every 5
seconds to once a day). Click the item for more of the output, Refresh Now, or
Open in Termight.

- They run by themselves, so keep them quick and harmless.
- Each run is limited to 60 seconds (less for short intervals).
- They write no history and no logs.
- Snippets work, but extra words beyond a snippet's placeholders are refused,
  and a snippet that still needs values shows a warning.
- The title is cut at 40 characters.

## Spotlight and Shortcuts

**Run Command** and **Run Snippet** do nothing until you turn on Settings →
Commands → **Allow Spotlight and Shortcuts to run commands**. Once that's on,
they run without asking, and so does any shortcut or automation that uses
them, including ones you imported. Leave it off if you install shortcuts you
haven't read.

- Run Snippet refuses text beyond the snippet's placeholders instead of adding
  it to the command.
- Run Snippet reads a snippet's `{!secrets}` from the Keychain. Run Command
  never does, since extra text on its line could print them.
- Spotlight runs have a 30-second limit and show the first 40 lines; the rest
  is in `~/Library/Logs/termight/last.log`.
- Spotlight indexes snippet names, never their commands.
- The actions need a build signed with a developer team. macOS won't register
  them for an unsigned app, and a second copy of Termight elsewhere on disk can
  hide them.

## Updates

Termight checks GitHub for a new release once a day and shows **Update to …**
in the menu bar when one is out. Settings → General → Updates turns the check
off or checks now. The check asks GitHub's public API for the latest release
and sends nothing about you or your commands.

**Install and Relaunch** downloads the release, installs it only if Apple
notarized it and it's signed by the same developer as your copy, then swaps
the app and reopens it. Running commands are stopped first, after asking.

- A copy you built yourself is signed by your team, so it won't accept
  official releases. Update it with `git pull` and `./build.sh`.
- Termight can't ask for an admin password. If it lives somewhere you can't
  write to, it sends you to the release page instead.

## What Termight stores

Everything stays on your Mac, in files only your user can read:

| Where | What |
|---|---|
| `~/Library/Logs/termight/history.log` | Every command you ran, with snippet values, cut to the last 5,000 |
| `~/Library/Logs/termight/last.log` | Output of the last command, up to 1 MB |
| `~/Library/Logs/termight/jobs/` | Output of recent commands run in the bar, kept across restarts so ↑↓, ⌃R and ⌘D can use it: up to 1 MB each, the last 100 commands plus up to 5 you keep with ⌘K, and never more than 10 MB in all, so a few large outputs push older ones out sooner (the oldest go first) |
| `~/Library/Application Support/Termight/snippets.tsv` | Your snippets |
| `~/Library/Caches/termight/` | Your login shell's PATH and alias names |
| Login keychain | Snippet secrets |

A command's log keeps its first 256 KB and its last 768 KB, with a note where
the middle was left out. The history file is cut to its last 5,000 commands.
Altogether Termight's logs stay around 12 MB at most.

Start a line with a space to keep it out of the history and its output out of
`jobs/` after a restart. Settings → Commands → **Clear History** deletes the
history and the kept output, including outputs kept with ⌘K. A notification for a finished command
shows the command, unless it started with a space.

## Other limits

- Requires macOS 26 or later on Apple Silicon.
- The bar keeps the last 500 lines on screen (Settings → Commands) and at most
  1 MB. The job's log (⌘L) keeps up to 1 MB: the start and the end of the
  output.
- Commands time out after 5 minutes in the bar (adjustable).
- A command that leaves something running with its output attached
  (`sleep 60 &`) has that process stopped when the command ends. Detach it
  (`nohup … >/dev/null 2>&1 &`) to keep it running.
- Quitting Termight stops the commands it's running.
- Your shell's `~/.zshrc` isn't loaded unless you turn that on in Settings →
  Commands, so aliases and functions defined there aren't available by default.
  Your login PATH is.
- Commands run in zsh or bash. Another `$SHELL` (fish, for example) falls back
  to zsh.
- Termight isn't sandboxed, which is also why it can't be in the Mac App
  Store: a sandboxed app's commands can't reach your files.

## Building

`./build.sh` builds and installs `/Applications/Termight.app`. It needs Xcode
and Rust, and a signing team: set yours in Xcode (Signing & Capabilities) or
run `TERMIGHT_TEAM=<team ID> ./build.sh`. A free Apple ID added in Xcode →
Settings → Accounts is enough.

| Path | What |
|---|---|
| `src/` | Rust core (`termight-core`): runs commands, streams output, checks and completes what you type, expands snippets. `cargo test` runs its tests. |
| `Termight/Termight/` | Swift app: the bar, menu bar, settings, Finder actions and Spotlight actions. Every command goes through the Rust core. |
