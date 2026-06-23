# Translation tool — `i18n.py`

`i18n.py` keeps the plugin's translations in sync with the code. It reads the
`_("...")` and `_n("...", "...", n)` strings out of the Lua source and maintains
the gettext files in `locale/` (`syncery.pot` is the template; `bg.po` and any
other `*.po` are the translations).

You do **not** need to understand gettext to use it — follow the workflow below.

## Setup (once)

```
pip install polib --break-system-packages
```

That is the only dependency. An optional `lua` interpreter unlocks an extra
self-check, but it is not required.

## Everyday workflow

1. Add or change `_("...")` strings in the `.lua` code, as usual.
2. Add them to the translation files:
   ```
   python3 tools/i18n.py sync
   ```
3. Open `locale/bg.po` and translate the new, empty `msgstr ""` lines. For a
   plural string (`_n`), fill in every `msgstr[0]`, `msgstr[1]`, … form.
4. Confirm everything is consistent:
   ```
   python3 tools/i18n.py check --lua
   ```

Running `python3 tools/i18n.py` with no command prints this same summary.

## Commands

| Command | What it does |
| --- | --- |
| `check [--lua]` | Reports new / untranslated / obsolete / broken strings. Changes nothing. `--lua` also loads each `.po` with the plugin's own parser as a final check. |
| `sync [--prune]` | Makes the `.pot` and every `.po` match the code: adds new strings, refreshes `#:` references, keeps existing translations. `--prune` also deletes strings that are no longer used in the code. |
| `refs` | Only refreshes the `#: file:line` references (handy after code moved but no strings changed). |
| `reword --map "OLD=NEW"` | Renames a string in the code **and** the translation files at once, carrying the translation across. Use the exact source spelling (including `\n`). Repeatable; or use `--from-file FILE` with one `OLD=NEW` per line. |
| `stats` | Shows how much of each language is translated. |

## Safety

* Every write command first saves a backup of your `locale/` files to a temp
  folder and prints the path — so you can always undo.
* Add `--dry-run` to any write command (`sync`, `refs`, `reword`) to preview the
  changes without writing anything.
* `check` exits with a non-zero status when it finds a real problem, so it also
  works in CI / pre-commit hooks.

## What counts as a translatable string

Both `_(...)` and `_n(...)` calls — the plugin's gettext aliases
(`local _ = require("syncery_i18n").translate`,
`local _n = require("syncery_i18n").ngettext`). A `_("...")` call is a single
string; a `_n("one", "many", n)` call is a plural string, stored with an
`msgid_plural` line and one `msgstr[N]` per plural form. The extractor understands
`..` concatenation across lines, the `\n \t \r \" \\` escapes, and `[[long]]`
string literals, and it ignores comments and text that merely appears inside other
strings.

## Notes

* Files are written LF-only (no CRLF) and entries stay sorted by message id,
  matching the rest of the repo.
* The first `sync`/`refs` after installing the tool may make a one-time
  formatting pass (e.g. normalising how long lines are wrapped). It is
  behaviour-preserving — `check --lua` confirms the plugin still loads exactly
  the same translations.
