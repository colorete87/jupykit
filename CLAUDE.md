# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`jupykit.sh` is a single ~1050-line bash script that orchestrates `nvim` + `jupyter` + `jupynium` with `.ipynb` ↔ `.ju.py` sync. The script **is** the distribution — there is no build step, no package manager, no other source files. Users either `curl` the file or `git clone` the repo.

## Common commands

```bash
bash -n jupykit.sh                   # Syntax check (the only "lint" available)
./jupykit.sh --help                  # See all flags
./jupykit.sh --doctor                # Diagnose the current setup (venv/nvim/port/PIDs)
./jupykit.sh --install               # Interactive 4-step wizard
./jupykit.sh --install --yes         # Non-interactive install with defaults
./jupykit.sh --sync-only             # Sync .ipynb/.ju.py pairs and exit (cheap smoke test)
```

There is **no test framework**. Verification is manual smoke tests, typically run against a sandboxed `HOME` so they don't touch your real config:

```bash
SANDBOX=$(mktemp -d); mkdir -p "$SANDBOX/proj"
( cd "$SANDBOX/proj" && HOME="$SANDBOX" /home/fzacchigna/projects/jupykit/jupykit.sh --install --yes )
( cd "$SANDBOX/proj" && HOME="$SANDBOX" /home/fzacchigna/projects/jupykit/jupykit.sh --doctor )
rm -rf "$SANDBOX"
```

## Script structure (jupykit.sh)

The file is organized as: **all function definitions → argv parser → validation → mode dispatch** at the very bottom. There is no top-level execution outside the final `case "$MODE"`.

- **Modes** (mutually exclusive, default `run`): `run`, `install`, `install-nvim`, `doctor` → dispatched to `cmd_run`, `cmd_install`, `cmd_install_nvim`, `cmd_doctor`.
- **Phases inside `cmd_run`**: `run_sync` → `start_jupyter` → `start_jupynium` → `nvim` foreground. An `EXIT` trap calls `cleanup` to tear down jupyter + the jupynium process group.
- **Wizard steps** (`cmd_install`): `wizard_step_venv` → `wizard_step_script` → `wizard_step_nvim` → summary. Each step honors override env vars (`WIZARD_VENV_CHOICE`, `WIZARD_BIN_CHOICE`, `WIZARD_NVIM_CHOICE`, `WIZARD_NVIM_LOAD`, `WIZARD_YES`) so flags like `--yes`, `--venv`, `--bin-only` flow through the same code paths as interactive prompts.

### Critical invariants (don't break these without thinking)

- **Bash 4+ only**: uses `${var^^}` case folding, `(( ))`, etc. No POSIX-sh constraint.
- **Venv discovery chain** in `resolve_venv()` (order matters): `$JUPY_VENV` → `./$JUPYKIT_PROJECT_VENV/` → walk up to `$HOME` looking for `$JUPYKIT_PROJECT_VENV/` → system `PATH`. Default basename is `.jupykit-venv` (env-overridable via `JUPYKIT_PROJECT_VENV`). Required bins: `jupynium jupyter ipynb2jupytext jupytext`.
- **`notebook<7` pin**: jupynium upstream does not support Notebook 7. The installer pins this; don't relax it.
- **Python 3.11 default**: `notebook<7` imports `distutils` (removed from stdlib in Python 3.12), so the installer runs `uv venv --python "$JUPYKIT_PYTHON"` with `JUPYKIT_PYTHON=3.11` by default. Don't drop the `--python` flag, and don't bump the default above 3.11 unless `notebook` is unpinned.
- **Firefox only**: jupynium is hard-coded to Firefox upstream (Chrome is commented out in jupynium's source). `--doctor` checks for Firefox; do not add Chrome fallbacks.
- **Dual config flags** in `start_jupyter`: both `--NotebookApp.*` and `--ServerApp.*` are passed so the script works against either NB6 or NB7-style installs without branching. Keep both.
- **Process group cleanup**: `start_jupynium` launches via `setsid` so `cleanup` can `kill -- -PID` the whole tree (jupynium + geckodriver + Firefox) in one shot. Don't drop `setsid` — orphan Firefox windows are the symptom.
- **Notebook URL match**: jupynium is started with `--notebook_URL localhost:8888` to match the nvim plugin's `default_notebook_URL`. If these diverge, jupynium opens a duplicate "home window" instead of reusing the tab.
- **Prompt helpers read from `/dev/tty`**: `prompt_letter` and `prompt_string` use `read -r ans </dev/tty` and print prompts to stderr (stdout is reserved for the captured answer). Keep this pattern when adding prompts.
- **Idempotent shellrc edits**: `_update_shellrc_jupy_venv` matches a marker comment (`# Added by jupykit (do not edit this line)`) to replace in place. Never duplicate the export.
- **Backup-before-overwrite**: any wizard step that writes a file the user might own (`~/.local/bin/jupykit`, nvim configs) first moves the existing file to `*.bak.YYYYMMDD-HHMMSS`.

## Sync semantics

`run_sync` walks `.ipynb` and `.ju.py` files in `$PWD` (skipping `.ipynb_checkpoints/`, `$JUPYKIT_PROJECT_VENV/`, `$JUPYKIT_RUN_DIR_NAME/`, plus the legacy `jupynium/` and `.run/` for forward-compat), compares mtimes, and regenerates the older sibling from the newer. After regeneration it `touch -r`s the output to keep mtimes equal — that's what makes consecutive runs no-ops. `--force-to-py` / `--force-to-ipynb` bypass mtime comparison; `--to-py` / `--to-ipynb` restrict the direction but still respect mtime.

## Runtime artifacts (`.jupykit-run/`)

`cmd_run` creates `$PWD/$JUPYKIT_RUN_DIR_NAME/` (default `.jupykit-run/`) and stores `jupyter.pid`, `jupyter.log`, `jupynium.pid`, `jupynium.log`. It also appends the run dir to `.gitignore` if one exists. PID files are checked for staleness (`kill -0`) before each start. The basename is env-overridable via `JUPYKIT_RUN_DIR_NAME`.

## Generated nvim files

The wizard writes ONE file into the user's nvim config:
- `~/.config/nvim/lua/plugins/jupynium.lua` — the lazy.nvim plugin spec, parametrized by load mode (`ft`/`cmd`/`eager`/`manual`) and keymap choice via `_generate_plugin_lua`.

The spec uses `opts = function() ... end` with an in-line lua resolver that walks `vim.fn.getcwd()` upward looking for `.jupykit-venv/bin/python`, then falls back to `~/.local/share/jupykit/venv/bin/python`, then `$JUPY_VENV/bin/python`. This makes a single spec file work across multiple projects and avoids depending on `vim.g.python3_host_prog`. There is intentionally no `lua/config/jupykit.lua` anymore — earlier versions wrote one but LazyVim does NOT auto-load arbitrary `lua/config/*.lua` (only `options.lua`/`keymaps.lua`/`autocmds.lua`), so that file was dead code. The wizard now detects and removes any legacy host file on re-install. The wizard also warns (but does not edit) when the user's own `lua/config/options.lua` sets `vim.g.python3_host_prog` to a different path.

The default plugin spec leaves jupynium's built-in keymaps intact (no `keys = {...}` override). The wizard offers one optional addition — `<leader>j<CR>` "execute cell and advance" — controlled by the `WIZARD_NVIM_KEYMAP=yes|no` env (or `--nvim-advance-keymap yes|no`). The default for `--yes` is `no` (conservative). Other extras (`<C-CR>`/`<S-CR>`, buffer-local `<C-x>`/`X`) live as copy-paste snippets in the README — don't bake them into the generated template.

For `ft` load mode the wizard emits a `BufReadPre`/`BufNewFile` pattern trigger on `*.ju.*`, NOT `ft = "python"`. Reason: lazy.nvim's FileType event fires after BufRead, so jupynium's pattern-keyed autocmds (`auto_attach_to_server`, `auto_start_sync` — both `*.ju.*`) would otherwise miss the buffer that loaded them and no Firefox tab would open.

- **`auto_start_sync` is disabled**: jupynium's built-in `auto_start_sync` passes `%:r:r` (which includes directory path) to `start_sync_with_filename`, but the Jupyter file browser shows only the basename. When the `.ju.py` lives in a subdirectory, the comparison fails and jupynium creates an Untitled.ipynb instead of opening the existing notebook. The `init` function replaces this with a custom BufWinEnter autocmd that (a) ensures the sibling `.ipynb` exists (creating it via jupytext if missing), and (b) calls `Jupynium_start_sync` with `%:t:r:r` (basename only) so the name matches.

## Reference docs

- `docs/superpowers/specs/2026-05-20-jupykit-design.md` — full design rationale (non-goals, distribution model, CLI surface, conflict policies).
- `docs/superpowers/plans/2026-05-20-jupykit-implementation.md` — task-by-task implementation plan with smoke-test recipes per task; useful when adding a new wizard step or mode.
