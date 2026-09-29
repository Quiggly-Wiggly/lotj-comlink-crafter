# LotJ Comlink Crafter

Queue, craft, optionally tune, and pack comlinks in repeated batches in Mudlet.
Adapted from **Ruusm's LotJComlink MUSHclient plugin v1.3**; Mudlet conversion
and maintenance by **Quiggly-Wiggly**.

## Install

Download **LotJ Comlink Crafter.mpackage** from
[Releases](https://github.com/Quiggly-Wiggly/lotj-comlink-crafter/releases/latest)
and install it through Mudlet's Package Manager. Requires Mudlet 4.20+.
Type `mclhelp` for the compact colored menu. Links fill the command line;
review and press Enter to run them.

When upgrading, stop your batch with `mclstop` and wait for any craft already
underway to finish. Uninstall the old **LotJComlink** package, then install the
new package. The installed ID remains `LotJComlink`, and existing profile-local
`LotJComlink-settings.lua` settings are retained. Remove duplicate standalone
`mcl…` aliases/triggers if you imported the XML separately. The separate comlink
contact tracker and lotj-ui are not required or replaced.

## Commands

| Command | Action |
| --- | --- |
| `mcladd '<name>' [frequency]` | Queue a named comlink, optionally tuned |
| `mclremove <number>` | Remove a queue entry |
| `mclcontainer '<name>' [keyword]` | Make and fill one container per batch |
| `mclcontainer clear` | Skip container crafting; `none` also works |
| `mcliterations <n>` | Set the number of batches |
| `mcllist` | List designs, tuning, container, and totals |
| `mclstart` | Start from the first entry of batch one |
| `mclstatus` | Show progress and the craft being awaited |
| `mclstop` | Stop sending further batch commands |
| `mclclear` | Clear queue, container, and iteration settings while idle |
| `mclhelp` | Show commands |

Names must use single or double quotes. Use double quotes around a name that
contains an apostrophe. Tuning is optional. Container keywords are single words;
if omitted, the helper guesses from the name and shows its choice for review.

Fictional example (choose your own names, frequency, and container keyword):

```text
mcladd 'a sample comlink' 12345
mcladd 'another sample comlink'
mclcontainer 'a sample case' case
mcliterations 2
mcllist
mclstart
```

Queue edits are blocked during a batch. Names and frequencies display literally,
including game color codes and brackets. Control characters and command
separators are rejected. No queue, frequencies, or character data are bundled.

## Behavior and limits

Each comlink uses `makecomlink hold <name>`. On the game's completion message,
it optionally sends `tune comlink <frequency>`, then proceeds. After the last
comlink, it optionally uses `makecontainer hold <name>`, waits for completion,
and sends `put comlink <keyword>` once per queued comlink.

This retains the original targeting assumption: `comlink` and the container
keyword must select the items you intend. Tune and put commands do not wait for
acknowledgments; inspect the game output. A send error stops further commands.
Unrecognized crafting failures or interruptions leave the batch waiting; check
`mclstatus`, fix the issue, and stop before starting again. There are no automatic
retries or timeouts. `mclstart` restarts the entire batch sequence, not a partial
resume. A craft already sent to the server may still finish after `mclstop`;
wait for it before restarting to avoid confusing completion messages.

Loading and disconnecting leave automation stopped. Queue settings save per
Mudlet profile; active progress is never restored. Uninstalling retains saved
settings. Use `mclclear` before uninstalling to reset them. The `hold` wear
location and `comlink` target can be customized in `src/core.lua` before building.

## Development

```sh
python3 scripts/build.py
python3 -m unittest discover -s tests -v
```

The reproducible builder uses Python's standard library and reads only this
repository. Tests use LuaJIT/Lua 5.1 and simulated Mudlet UI/events. When local
Mudlet persistence helpers are available, the same behavior checks also run
with its real `table.save`/`table.load`. Tests cover every menu link, batch command
order, stop/disconnect behavior, settings migration, malformed input, send
failures, and release contents. Native rendering and live crafting remain
manual checks.
