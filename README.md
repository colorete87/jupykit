# jupykit

One-shot orchestrator for `nvim` + `jupyter` + `jupynium`, with automatic `.ipynb` ↔ `.ju.py` sync. Edit notebooks from neovim with the kernel running in a live-synced browser tab. Exit nvim and everything shuts down cleanly.

## Quickstart

### Method 1: curl-and-run (fastest)

```bash
curl -fsSLO https://raw.githubusercontent.com/colorete87/jupykit/main/jupykit.sh
chmod +x jupykit.sh
./jupykit.sh --install
```

### Method 2: clone

```bash
git clone https://github.com/colorete87/jupykit ~/.local/share/jupykit
~/.local/share/jupykit/jupykit.sh --install
```

The installer is interactive (4 steps, all with defaults). Press Enter through it for a sensible setup; or use `--install --yes` to skip prompts.

**Requirements:** bash 4+, `uv` ([install](https://docs.astral.sh/uv/getting-started/installation/)), Firefox (jupynium uses Selenium-controlled Firefox; Chrome is not supported upstream), `nvim` (optional; install configures the [jupynium.nvim](https://github.com/kiyoon/jupynium.nvim) plugin if found).

## Daily use

```bash
cd ~/my-notebook-project
./jupykit.sh
```

What happens:
1. Syncs every `.ipynb` ↔ `.ju.py` pair in the current directory.
2. Starts `jupyter notebook` on `localhost:8888` (background).
3. Starts `jupynium` (background; opens a Selenium-controlled Firefox).
4. Opens `nvim` in the current directory (foreground).

Open a `.ju.py` in nvim → if its sibling `.ipynb` exists in the same directory, jupynium opens that tab in Firefox and syncs to it; otherwise it creates a fresh `Untitled.ipynb` in the buffer's directory. Edit in nvim, see results in the browser. Exit nvim (`:qa!`) → cleanup trap kills jupyter, jupynium, and the Selenium Firefox in one shot.

## Common flags

| Flag | What it does |
|------|--------------|
| `--sync-only`         | Sync `.ipynb`/`.ju.py` pairs and exit |
| `--force-to-ipynb`    | Regenerate all `.ipynb` from `.ju.py` (useful pre-commit) |
| `--force-to-py`       | Regenerate all `.ju.py` from `.ipynb` |
| `--no-nvim`           | Start servers, leave them running, exit |
| `--install`           | Run the 4-step setup wizard (venv → script → nvim plugin → summary) |
| `--install-nvim`      | Only regenerate the nvim plugin spec (skip venv + script steps) |
| `--uninstall`         | Reverse `--install` (interactive; `--yes` for non-interactive) |
| `--doctor`            | Print diagnostic info (venv state, Python version, port, nvim configs, stale PIDs) |
| `--help`              | Full options list |

## Project setup snippet

To make jupykit usage discoverable in your own project's repo, paste this into your project's README and adjust:

```markdown
## Notebook development

This project uses [jupykit](https://github.com/colorete87/jupykit) for the nvim ↔ Jupyter workflow. To set up:

    curl -fsSLO https://raw.githubusercontent.com/colorete87/jupykit/main/jupykit.sh
    chmod +x jupykit.sh
    ./jupykit.sh --install

Then `./jupykit.sh` to start working.
```

Also add `.jupykit-venv/`, `.jupykit-run/`, `.ipynb_checkpoints/`, and `Untitled*.ipynb`/`Untitled*.ju.py` to your project's `.gitignore`. (jupykit auto-appends its own run dir to an existing `.gitignore` on first run.)

## Extras

The default install leaves jupynium's [built-in keymaps](https://github.com/kiyoon/jupynium.nvim#default-keybindings) intact — they use literal `<space>` (not `<leader>`):

- `<space>x` — execute cell  &nbsp;·&nbsp;  `<space>c` — clear outputs  &nbsp;·&nbsp;  `<space>K` — kernel hover (inspect)
- `<space>js` — scroll to cell  &nbsp;·&nbsp;  `<space>os` — scroll to output  &nbsp;·&nbsp;  `<space>jo` — toggle output scroll
- `<space>jj` — go to current cell  &nbsp;·&nbsp;  `<space>[j` / `<space>]j` — prev / next cell
- `<PageUp>` / `<PageDown>` — scroll notebook

If your `mapleader` is `<space>` (LazyVim default), `<space>x` and `<leader>x` are equivalent at the keyboard.

The installer offers one optional addition: `<leader>j<CR>` "execute cell and advance" (interactive prompt defaults to Y; `--nvim-advance-keymap yes|no` controls it non-interactively).

## How it works

jupykit is a bash script that runs four phases in sequence:

1. **Sync** — walks the current directory for `.ipynb`/`.ju.py` pairs, regenerates the older sibling from the newer one (mtime-based). Files are kept timestamp-synchronized so consecutive runs are no-ops.
2. **Jupyter server** — launches `jupyter notebook --no-browser` on `localhost:8888` with token disabled. Polls `/api` until ready.
3. **Jupynium server** — launches `jupynium` via `setsid` (own process group), which opens a Selenium-controlled Firefox. Polls the log for the "waiting for nvim to attach" marker.
4. **Nvim** — opens nvim in the current directory. When you load a `.ju.py`, the generated lazy.nvim spec (triggered by `BufReadPre *.ju.*`) loads the plugin, an `init` autocmd mutates `default_notebook_URL` to `localhost:8888/tree/<buffer-relative-dir>` so jupyter's listing contains the sibling `.ipynb`, then jupynium auto-attaches and starts syncing.

When you exit nvim (or hit Ctrl+C), an `EXIT` trap kills the jupynium process group (taking down geckodriver + Firefox in one shot) and the jupyter process. The `.jupykit-run/` directory holds PID files and logs for debugging.

The script discovers its dependencies by checking, in order: `$JUPY_VENV`, `./.jupykit-venv/`, walk-up to `$HOME`, then system `PATH`. The installer creates `./.jupykit-venv/` by default with Python 3.11 (notebook<7 imports `distutils`, which Python 3.12+ removed); the venv contains `jupynium`, `jupyter` (pinned to `notebook<7` because jupynium doesn't support Notebook 7), `pynvim`, `ipykernel`, and `jupytext`.

### Environment overrides

| Var | Default | Purpose |
|-----|---------|---------|
| `JUPY_VENV`           | (unset)              | Absolute path to a venv to use; short-circuits the discovery chain. |
| `JUPYKIT_PROJECT_VENV`| `.jupykit-venv`      | Basename of the per-project venv directory (where `--install` writes it). |
| `JUPYKIT_RUN_DIR_NAME`| `.jupykit-run`       | Basename of the per-project PID/log directory. |
| `JUPYKIT_PYTHON`      | `3.11`               | Python version `uv venv` pins. Don't bump above 3.11 unless `notebook<7` gets unpinned. |

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `jupynium` fails to open a browser | Firefox missing or broken. Run `--doctor` to confirm. Chrome is not a supported alternative (upstream limitation). |
| Firefox shows token login | `jupyter` flags didn't take effect. Check `cat .jupykit-run/jupyter.log`. Usually means a Notebook 7 install slipped in; reinstall with `--install`. |
| `ModuleNotFoundError: No module named 'distutils'` on jupyter startup | Venv was built with Python ≥3.12 where `distutils` is gone, but `notebook<7` still imports it. Rebuild with `rm -rf .jupykit-venv && ./jupykit.sh --install --yes` (jupykit now pins Python 3.11 by default; override via `JUPYKIT_PYTHON`). |
| 404 in Selenium Firefox | `default_notebook_URL` got mutated to a path that doesn't exist (the buffer is outside the project's cwd, or the subdirectory was renamed). Reinstall nvim config with `--install-nvim` and reopen the buffer. |
| Plugin not loading on `.ju.py` | The load mode chosen at install was "manual" or "cmd". Re-run `--install-nvim` and pick "ft" (which emits `event = BufReadPre *.ju.*`, NOT `ft = "python"` — the FileType trigger fires too late for jupynium's autocmds). |
| Orphan Firefox windows after exit | Cleanup didn't fire (script killed with SIGKILL, or `--no-nvim` mode used). Kill with `pkill -f '/bin/jupynium'; pkill -f 'firefox.*rust_mozprofile'; pkill -f geckodriver`, or use `--uninstall` step 1. |
| Second `.ju.py` hangs nvim | Usually orphan jupynium/Firefox/geckodriver from a previous session that didn't clean up — the new attach connects to a stale Selenium driver and hangs. Kill them as in the previous row, then retry. |
| `nvim` complains about pynvim | jupykit's plugin spec computes `python_host` independently of `vim.g.python3_host_prog`, so this only matters for nvim's own `:py3` integration. To fix, either remove the stale `vim.g.python3_host_prog` from your `lua/config/options.lua`, or point it at `<venv>/bin/python` (the install warns when it detects a conflicting value). |

## Status

`v0.1.0` — initial release. Works on Linux with bash 4+, nvim 0.10+, and a recent uv. Requires Firefox; Chrome is not supported because jupynium is hard-coded to Firefox upstream ([source](https://github.com/kiyoon/jupynium.nvim/blob/main/src/jupynium/cmds/jupynium.py)). Not tested on macOS.

## Uninstall

```bash
./jupykit.sh --uninstall          # interactive, six steps, default N
./jupykit.sh --uninstall --yes    # non-interactive; removes every detected component
```

The uninstaller detects what's present and prompts for each step individually — skipping any step leaves it untouched. Steps and the actions they take:

1. **Running processes** — `jupynium`, `jupyter-notebook`, the Selenium-controlled Firefox, `geckodriver`.
2. **Venv** — removes `./.jupykit-venv/` and/or `~/.local/share/jupykit/venv/` if they look jupykit-installed (have `pyvenv.cfg` and a `jupynium` binary). Legacy `./jupynium/` directories from pre-rename installs are detected too.
3. **System-wide script** — `~/.local/bin/jupykit` and its `.bak.*` siblings.
4. **Shellrc export** — strips the `# Added by jupykit ...` marker + the following `export JUPY_VENV=...` line from `~/.bashrc` and `~/.zshrc`.
5. **Nvim configs** — `~/.config/nvim/lua/plugins/jupynium.lua` (plus `.bak.*` siblings). The legacy `~/.config/nvim/lua/config/jupykit.lua` from earlier installs is also detected and removed (current installs don't generate it). Then run `:Lazy clean` inside nvim to drop the `jupynium.nvim` plugin itself.
6. **Per-project `.jupykit-run/`** — only the one in the current `$PWD` (other projects' run dirs are left alone; `rm -rf .jupykit-run` them by hand if you care). Legacy `.run/` is detected too.

Your `.ipynb` and `.ju.py` notebook files are never touched.

## License

MIT. See [LICENSE](LICENSE).
