#!/usr/bin/env bash
# jupykit — orchestrate jupyter + jupynium + nvim with .ipynb<->.ju.py sync,
# plus an interactive --install wizard and --doctor diagnostic.
# See docs/superpowers/specs/2026-05-20-jupykit-design.md
set -euo pipefail

JUPYKIT_VERSION="0.1.0"

# ---------- User-overridable basenames ----------
# Both default to dotfile names so all jupykit-managed artifacts live under a
# consistent .jupykit-* prefix and are hidden from `ls`. Override via env if
# you want different basenames (e.g. JUPYKIT_PROJECT_VENV=jupynium for
# backward compatibility with installs predating the rename).
JUPYKIT_PROJECT_VENV="${JUPYKIT_PROJECT_VENV:-.jupykit-venv}"   # project-local venv directory
JUPYKIT_RUN_DIR_NAME="${JUPYKIT_RUN_DIR_NAME:-.jupykit-run}"     # per-project PIDs/logs
# notebook<7 imports distutils, which was removed from stdlib in Python 3.12.
# Pin to 3.11 so a system Python 3.12+ doesn't silently break the install.
JUPYKIT_PYTHON="${JUPYKIT_PYTHON:-3.11}"

# ---------- Defaults ----------
DO_SYNC=1
SYNC_ONLY=0
SYNC_DIR=""        # "", "to-py", "to-ipynb"
SYNC_FORCE=0
DO_JUPYTER=1
DO_JUPYNIUM=1
DO_NVIM=1
USE_COLOR="auto"   # "auto", "yes", "no"
WIZARD_YES=0

# Mode dispatch — exactly one of: run (default), install, install-nvim, doctor.
MODE="run"

# ---------- Help ----------
usage() {
  cat <<'EOF'
Usage: jupykit [flags]

Modes (mutually exclusive; default is to orchestrate):
  --install              Run the interactive setup wizard
  --install-nvim         Configure nvim only (skip venv + script install)
  --uninstall            Reverse --install: prompts for each component (venv,
                         ~/.local/bin script, shellrc export, nvim configs,
                         per-project run dir). Detected only; safe to re-run.
  --doctor               Print diagnostic info about the current setup

Wizard flags (apply to --install / --install-nvim; --yes also applies to --uninstall):
  --yes, -y              Accept all defaults; no prompts
  --venv project|user-wide   Override venv location
  --bin-only             Install script to ~/.local/bin/jupykit (--install only)
  --no-nvim-install      Skip nvim configuration step (--install only)
  --nvim-load ft|cmd|eager|manual    Lazy loading strategy
  --nvim-advance-keymap yes|no       Add the optional <leader>j<CR> keymap

Sync options:
  --no-sync              Skip the sync phase entirely
  --sync-only            Sync and exit (do not start servers or nvim)
  --to-py                Sync only ipynb -> ju.py (respects mtime)
  --to-ipynb             Sync only ju.py -> ipynb (respects mtime)
  --force-to-py          ipynb -> ju.py for all pairs, ignoring mtime
  --force-to-ipynb       ju.py -> ipynb for all pairs, ignoring mtime

Phase options:
  --no-jupyter           Do not start jupyter (assumes one on localhost:8888)
  --no-jupynium          Do not start jupynium
  --no-nvim              Do not open nvim (leaves servers running, no cleanup)

Output:
  --no-color             Disable colored output

Other:
  -h, --help             Show this help and exit

Environment:
  JUPY_VENV              Path to a venv with jupynium/jupyter installed.
  JUPYKIT_PROJECT_VENV   Basename of the project-local venv dir (default: .jupykit-venv)
  JUPYKIT_RUN_DIR_NAME   Basename of the per-project runtime dir (default: .jupykit-run)
  JUPYKIT_PYTHON         Python version for the venv (default: 3.11; notebook<7 needs <3.12)
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

# ---------- Interactive prompts ----------

# Read a single-letter choice with case-insensitive match. Echoes the
# selected letter (uppercase) to stdout. Re-prompts on invalid input.
#
# Usage: ans=$(prompt_letter "Pick one" "PUE" "P")
#   $1 = prompt string (without trailing colon)
#   $2 = string of valid letters (e.g., "PUE")
#   $3 = default letter (used when user presses Enter)
prompt_letter() {
  local prompt="$1" valid="$2" default="$3"
  local ans
  while true; do
    # Print prompt to stderr so the captured stdout is just the answer.
    printf '%s [%s]: ' "$prompt" "$default" >&2
    read -r ans </dev/tty
    ans="${ans:-$default}"
    ans="${ans^^}"  # uppercase, requires bash 4+
    if [[ "${valid^^}" == *"$ans"* ]]; then
      echo "$ans"
      return 0
    fi
    printf 'Invalid choice. Pick one of: %s\n' "$valid" >&2
  done
}

# Read a free-form string with a default. Echoes to stdout.
prompt_string() {
  local prompt="$1" default="$2"
  local ans
  printf '%s [%s]: ' "$prompt" "$default" >&2
  read -r ans </dev/tty
  echo "${ans:-$default}"
}

# ---------- Wizard: step 1 (venv) ----------

VENV_PROJECT_PATH="./$JUPYKIT_PROJECT_VENV"
VENV_USERWIDE_PATH="$HOME/.local/share/jupykit/venv"
VENV_PACKAGES="jupynium notebook<7 pynvim ipykernel jupytext"

# Returns 0 if the given path exists, contains pyvenv.cfg, AND has all 4
# required binaries (complete). Returns 2 if pyvenv.cfg exists but some
# binaries are missing (broken). Returns 3 if the path doesn't exist or
# isn't a venv. (1 is reserved/unused.)
_venv_state() {
  local path="$1"
  if [[ ! -d "$path" ]]; then return 3; fi
  if [[ ! -f "$path/pyvenv.cfg" ]]; then return 3; fi
  local missing=0
  for bin in jupynium jupyter ipynb2jupytext jupytext; do
    [[ -x "$path/bin/$bin" ]] || { missing=1; break; }
  done
  if (( missing == 1 )); then return 2; fi
  return 0
}

_install_venv_packages() {
  local venv_path="$1"
  # Word-split VENV_PACKAGES intentionally so each package is a separate arg.
  # shellcheck disable=SC2086
  VIRTUAL_ENV="$venv_path" uv pip install $VENV_PACKAGES
}

# Step 1: install or reuse the venv at the chosen path.
# Echoes the absolute venv path to stdout when done.
wizard_step_venv() {
  if (( WIZARD_YES )) && [[ -z "${WIZARD_VENV_CHOICE:-}" ]]; then
    WIZARD_VENV_CHOICE="P"
  fi
  echo >&2
  echo "[1/4] Venv jupynium" >&2
  echo "  Where should the jupynium venv live?" >&2
  echo "    [P] Project-local ($VENV_PROJECT_PATH)" >&2
  echo "    [U] User-wide  ($VENV_USERWIDE_PATH)" >&2

  local choice path
  if [[ -n "${WIZARD_VENV_CHOICE:-}" ]]; then
    choice="$WIZARD_VENV_CHOICE"
  else
    choice=$(prompt_letter "  Choice" "PU" "P")
  fi

  case "$choice" in
    P) path="$(realpath -m "$VENV_PROJECT_PATH")" ;;
    U) path="$VENV_USERWIDE_PATH" ;;
  esac

  # Check existing state
  _venv_state "$path"
  local state=$?
  case $state in
    0)
      echo "  ✓ Reusing existing venv at $path" >&2
      ;;
    2)
      echo "  ⚠ Venv at $path exists but is incomplete." >&2
      local action
      if (( WIZARD_YES )); then
        action="R"
      else
        action=$(prompt_letter "  [R] Reinstall  [K] Keep as-is  [A] Abort" "RKA" "R")
      fi
      case "$action" in
        R)  _install_venv_packages "$path" >&2 ;;
        K)  echo "  Skipped reinstall (caller's responsibility)" >&2 ;;
        A)  die "aborted at venv install" ;;
      esac
      ;;
    3)
      if [[ -e "$path" ]]; then
        die "Path '$path' exists and is not a venv; remove it or choose a different location"
      fi
      echo "  Creating venv at $path (Python $JUPYKIT_PYTHON) ..." >&2
      uv venv --python "$JUPYKIT_PYTHON" "$path" >&2
      echo "  Installing $VENV_PACKAGES ..." >&2
      _install_venv_packages "$path" >&2
      ;;
  esac

  # Shellrc update for user-wide
  if [[ "$choice" == "U" ]]; then
    _update_shellrc_jupy_venv "$path"
  fi

  echo "$path"
}

# Adds (or replaces) the JUPY_VENV export line in ~/.bashrc and ~/.zshrc.
# Uses a marker comment for idempotency.
_update_shellrc_jupy_venv() {
  local venv_path="$1"
  local marker="# Added by jupykit (do not edit this line)"
  local export_line='export JUPY_VENV="'"$venv_path"'"'
  local rc touched=()
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] || continue
    if grep -qF "$marker" "$rc"; then
      # Replace the line AFTER the marker
      local tmpfile
      tmpfile=$(mktemp)
      awk -v marker="$marker" -v new="$export_line" '
        $0 == marker { print; getline; print new; next }
        { print }
      ' "$rc" > "$tmpfile"
      mv "$tmpfile" "$rc"
      echo "  Updated JUPY_VENV in $rc" >&2
    else
      printf '\n%s\n%s\n' "$marker" "$export_line" >> "$rc"
      echo "  Appended JUPY_VENV to $rc" >&2
    fi
    touched+=("$rc")
  done
  if (( ${#touched[@]} == 0 )); then
    echo "  ⚠ No ~/.bashrc or ~/.zshrc found; you must set JUPY_VENV=$venv_path yourself." >&2
  else
    echo "  Open a new shell (or source ${touched[0]}) to pick up JUPY_VENV." >&2
  fi
}

# Inverse of _update_shellrc_jupy_venv: removes the marker comment + the
# following export line. Returns 0 if the file was touched, 1 if the marker
# wasn't found (so the caller can report "nothing to do").
_remove_shellrc_jupy_venv() {
  local rc="$1"
  local marker="# Added by jupykit (do not edit this line)"
  [[ -f "$rc" ]] || return 1
  grep -qF "$marker" "$rc" || return 1
  local tmpfile
  tmpfile=$(mktemp)
  awk -v marker="$marker" '
    $0 == marker { getline; next }
    { print }
  ' "$rc" > "$tmpfile"
  mv "$tmpfile" "$rc"
  return 0
}

# ---------- Wizard: step 2 (script location) ----------

# Step 2: optionally copy jupykit.sh to ~/.local/bin/jupykit.
# Returns the canonical path of the installed script via stdout.
wizard_step_script() {
  if (( WIZARD_YES )) && [[ -z "${WIZARD_BIN_CHOICE:-}" ]]; then
    WIZARD_BIN_CHOICE="C"
  fi
  # Resolve once: handles relative-path / symlink / PATH-resolved invocation.
  local self
  self=$(realpath "$0")

  echo >&2
  echo "[2/4] Script location" >&2
  echo "  Where should jupykit.sh live?" >&2
  echo "    [C] Keep here ($self)" >&2
  echo "    [B] Install to ~/.local/bin/jupykit (system-wide command)" >&2

  local choice
  if [[ -n "${WIZARD_BIN_CHOICE:-}" ]]; then
    choice="$WIZARD_BIN_CHOICE"
  else
    choice=$(prompt_letter "  Choice" "CB" "C")
  fi

  case "$choice" in
    C)
      echo "  Script stays at $self" >&2
      echo "$self"
      ;;
    B)
      local target="$HOME/.local/bin/jupykit"
      mkdir -p "$(dirname "$target")"
      if [[ -f "$target" ]]; then
        local backup="$target.bak.$(date +%Y%m%d-%H%M%S)"
        mv "$target" "$backup"
        echo "  Backed up old $target → $backup" >&2
      fi
      cp "$self" "$target"
      chmod +x "$target"
      echo "  Installed: $target" >&2
      if ! echo ":$PATH:" | grep -q ":$HOME/.local/bin:"; then
        echo "  ⚠ ~/.local/bin is not on PATH. Add it to your shell rc:" >&2
        echo "      export PATH=\"\$HOME/.local/bin:\$PATH\"" >&2
      fi
      echo "$target"
      ;;
  esac
}

# ---------- Wizard: step 3 (nvim) ----------

NVIM_PLUGINS_DIR="$HOME/.config/nvim/lua/plugins"
NVIM_CONFIG_DIR="$HOME/.config/nvim/lua/config"
NVIM_PLUGIN_FILE="$NVIM_PLUGINS_DIR/jupynium.lua"
NVIM_HOST_FILE="$NVIM_CONFIG_DIR/jupykit.lua"

# Generate the jupynium.lua content for a given load mode + keymap choice.
# $1 = mode (ft|cmd|eager|manual)
# $2 = advance_keymap (yes|no) — add <leader>j<CR> "execute and advance"
# $3 = project_venv_basename (e.g. ".jupykit-venv") — embedded in the lua resolver
# stdout = the generated lua content
#
# Two non-obvious design points:
#
# 1. `ft` mode emits a BufReadPre/BufNewFile *.ju.* event spec, NOT
#    `ft = "python"`. Reason: lazy.nvim's FileType trigger fires AFTER
#    BufRead, so jupynium's pattern-based autocmds (auto_attach_to_server
#    and auto_start_sync, both keyed on "*.ju.*") would miss the buffer
#    that loaded them and no Firefox tab would open.
#
# 2. python_host is computed by an in-spec lua resolver at plugin-load time,
#    not read from vim.g.python3_host_prog. Reason: LazyVim auto-loads only
#    options.lua/keymaps.lua/autocmds.lua — a separate lua/config/jupykit.lua
#    is dead code unless explicitly required. The resolver also walks up
#    from cwd looking for a project-local venv, so this single spec file
#    works across multiple projects.
_generate_plugin_lua() {
  local mode="$1" advance_keymap="${2:-no}" project_venv="${3:-.jupykit-venv}"
  local triggers
  case "$mode" in
    ft)     triggers='event = { { event = { "BufReadPre", "BufNewFile" }, pattern = { "*.ju.*" } } },' ;;
    cmd)    triggers='cmd = { "Jupynium*" },' ;;
    eager)  triggers='lazy = false,' ;;
    manual) triggers='lazy = true, cmd = {}, ft = {},' ;;
    *)      die "internal error: unknown nvim load mode '$mode'" ;;
  esac

  local keys_block=""
  if [[ "$advance_keymap" == "yes" ]]; then
    keys_block='    keys = {
      {
        "<leader>j<CR>",
        function()
          vim.cmd("JupyniumExecuteSelectedCells")
          vim.fn.search("^# %%", "W")
        end,
        mode = { "n", "x" },
        desc = "Execute cell and advance",
      },
    },'
  fi

  cat <<EOF
-- Generated by jupykit $JUPYKIT_VERSION on $(date -Iseconds)
-- Edit freely; jupykit backs up before overwriting on the next --install.
-- Default jupynium keymaps are kept intact; see :help jupynium or
-- https://github.com/kiyoon/jupynium.nvim#default-keybindings
return {
  {
    "kiyoon/jupynium.nvim",
    dependencies = { "stevearc/dressing.nvim" },
    $triggers
    init = function()
      vim.api.nvim_create_autocmd("BufWinEnter", {
        pattern = { "*.ju.*", "*.md" },
        callback = function()
          local bufdir = vim.fn.expand("%:p:h")
          local cwd = vim.fn.getcwd()
          local url = "localhost:8888"
          if vim.startswith(bufdir, cwd .. "/") then
            local rel = bufdir:sub(#cwd + 2)
            if rel ~= "" then
              url = "localhost:8888/tree/" .. rel
            end
          end
          local ok, jopts = pcall(require, "jupynium.options")
          if ok and jopts and jopts.opts then
            jopts.opts.default_notebook_URL = url
          end

          local bufpath = vim.fn.expand("%:p")
          if not bufpath:match("%.ju%.") then return end

          local ipynb = bufpath:gsub("%.ju%.py$", ".ipynb")
          if vim.fn.filereadable(ipynb) == 0 then
            vim.fn.system({ "jupytext", "--to", "ipynb", "-o", ipynb, bufpath })
          end

          -- Jupynium's built-in auto_start_sync passes %:r:r (includes
          -- the directory path) but the Jupyter file browser shows only
          -- the basename. Use %:t:r:r so the names actually match.
          local filename = vim.fn.expand("%:t:r:r")
          local bufnr = vim.api.nvim_get_current_buf()
          vim.defer_fn(function()
            if type(Jupynium_syncing_bufs) == "table" and Jupynium_syncing_bufs[bufnr] then
              return
            end
            local found = vim.wait(5000, function()
              return vim.fn.exists(":JupyniumStartSync") > 0
            end, 100)
            if found and type(Jupynium_start_sync) == "function" then
              Jupynium_start_sync(bufnr, filename, false)
            end
          end, 100)
        end,
        group = vim.api.nvim_create_augroup("jupykit_notebook_url", { clear = true }),
      })
    end,
    opts = function()
      -- Resolve the jupykit venv python at plugin-load time. Matches the
      -- chain in jupykit.sh's resolve_venv() so this one spec works for
      -- both project-local and user-wide installs.
      local function find_venv_python()
        local home = vim.fn.expand("~")
        local jupy_venv = vim.env.JUPY_VENV
        if jupy_venv and jupy_venv ~= "" then
          local p = jupy_venv .. "/bin/python"
          if vim.fn.executable(p) == 1 then return p end
        end
        local dir = vim.fn.getcwd()
        while dir and dir ~= "/" do
          local p = dir .. "/$project_venv/bin/python"
          if vim.fn.executable(p) == 1 then return p end
          if dir == home then break end
          local parent = vim.fn.fnamemodify(dir, ":h")
          if parent == dir then break end
          dir = parent
        end
        local userwide = home .. "/.local/share/jupykit/venv/bin/python"
        if vim.fn.executable(userwide) == 1 then return userwide end
        return nil  -- jupynium will surface its own error
      end
      return {
        python_host = find_venv_python(),
        default_notebook_URL = "localhost:8888",
        auto_start_sync = { enable = false },
      }
    end,
$keys_block
  },
}
EOF
}

# Step 3: optionally write the nvim plugin spec.
# $1 = venv_path (from step 1, needed for python3_host_prog).
wizard_step_nvim() {
  local venv_path="$1"
  if (( WIZARD_YES )); then
    [[ -z "${WIZARD_NVIM_CHOICE:-}" ]] && WIZARD_NVIM_CHOICE="Y"
    [[ -z "${WIZARD_NVIM_LOAD:-}" ]]   && WIZARD_NVIM_LOAD="ft"
    [[ -z "${WIZARD_NVIM_KEYMAP:-}" ]] && WIZARD_NVIM_KEYMAP="no"
  fi
  echo >&2
  echo "[3/4] Neovim plugin (jupynium.nvim)" >&2

  if ! command -v nvim >/dev/null 2>&1; then
    echo "  ⚠ nvim not found; skipping nvim configuration." >&2
    echo "no-nvim"
    return 0
  fi

  local configure_choice
  if [[ -n "${WIZARD_NVIM_CHOICE:-}" ]]; then
    configure_choice="$WIZARD_NVIM_CHOICE"
  else
    echo "  Configure neovim? (LazyVim/lazy.nvim required)" >&2
    echo "    [Y] Yes" >&2
    echo "    [N] No, skip nvim setup" >&2
    configure_choice=$(prompt_letter "  Choice" "YN" "Y")
  fi

  if [[ "$configure_choice" == "N" ]]; then
    echo "skipped"
    return 0
  fi

  local load_mode
  if [[ -n "${WIZARD_NVIM_LOAD:-}" ]]; then
    load_mode="$WIZARD_NVIM_LOAD"
  else
    echo "  When should the plugin load?" >&2
    echo "    [F] When opening a *.ju.* file (BufReadPre pattern; recommended)" >&2
    echo "    [K] On using a Jupynium* command (cmd-triggered)" >&2
    echo "    [E] Eagerly at nvim startup" >&2
    echo "    [M] Manual (\`:Lazy load jupynium.nvim\`)" >&2
    local letter
    letter=$(prompt_letter "  Choice" "FKEM" "F")
    case "$letter" in
      F) load_mode="ft" ;;
      K) load_mode="cmd" ;;
      E) load_mode="eager" ;;
      M) load_mode="manual" ;;
    esac
  fi

  # Sub-prompt: keep jupynium's default keymaps, optionally add <leader>j<CR>.
  local advance_keymap
  if [[ -n "${WIZARD_NVIM_KEYMAP:-}" ]]; then
    advance_keymap="$WIZARD_NVIM_KEYMAP"
  else
    echo "  Add optional <leader>j<CR> 'execute cell and advance' keymap?" >&2
    echo "  (Jupynium's default keymaps are kept regardless.)" >&2
    local letter
    letter=$(prompt_letter "  Choice" "YN" "Y")
    [[ "$letter" == "Y" ]] && advance_keymap="yes" || advance_keymap="no"
  fi

  # Generate content. python_host is resolved inside the lua spec itself
  # (no separate lua/config/jupykit.lua needed), so the spec stays portable
  # across projects and survives even when LazyVim doesn't auto-require it.
  local new_plugin_content
  new_plugin_content=$(_generate_plugin_lua "$load_mode" "$advance_keymap" "$JUPYKIT_PROJECT_VENV")

  # Plugin file: backup/skip/diff prompt if it exists
  mkdir -p "$NVIM_PLUGINS_DIR"

  if [[ -f "$NVIM_PLUGIN_FILE" ]]; then
    local action
    if (( WIZARD_YES )); then
      action="W"
    else
      while true; do
        echo "  Existing $NVIM_PLUGIN_FILE detected." >&2
        echo "    [W] Backup and write" >&2
        echo "    [S] Skip nvim config" >&2
        echo "    [D] Show diff first" >&2
        action=$(prompt_letter "  Choice" "WSD" "W")
        if [[ "$action" == "D" ]]; then
          diff -u "$NVIM_PLUGIN_FILE" <(echo "$new_plugin_content") || true
          continue
        fi
        break
      done
    fi

    if [[ "$action" == "S" ]]; then
      echo "skipped"
      return 0
    fi

    local backup="$NVIM_PLUGIN_FILE.bak.$(date +%Y%m%d-%H%M%S)"
    mv "$NVIM_PLUGIN_FILE" "$backup"
    echo "  Backed up old plugin file → $backup" >&2
  fi

  echo "$new_plugin_content" > "$NVIM_PLUGIN_FILE"
  echo "  Wrote $NVIM_PLUGIN_FILE (load: $load_mode)" >&2

  # Conflict check: a lingering vim.g.python3_host_prog in lua/config/options.lua
  # can point at a stale venv path. Our plugin spec ignores vim.g for python_host,
  # but the global still affects nvim's own pynvim integration (:py3 etc.), so
  # we surface a hint rather than rewrite the user's file.
  local user_options="$HOME/.config/nvim/lua/config/options.lua"
  if [[ -f "$user_options" ]] && grep -q "python3_host_prog" "$user_options"; then
    if ! grep -qF "$venv_path/bin/python" "$user_options"; then
      echo "  ⚠ Detected python3_host_prog in $user_options pointing somewhere else." >&2
      echo "    Jupykit's plugin spec resolves python_host independently, so jupynium" >&2
      echo "    will work, but consider updating that line to point at:" >&2
      echo "        $venv_path/bin/python" >&2
      echo "    or removing it if you don't need nvim's :py3 integration." >&2
    fi
  fi

  # Legacy cleanup: pre-v0.1.1 installs wrote a lua/config/jupykit.lua that
  # LazyVim doesn't auto-load (so it was dead code that misled users into
  # thinking python3_host_prog was being set). If one exists, back it up and
  # remove it; the new plugin spec is self-contained.
  if [[ -f "$NVIM_HOST_FILE" ]]; then
    local backup="$NVIM_HOST_FILE.bak.$(date +%Y%m%d-%H%M%S)"
    mv "$NVIM_HOST_FILE" "$backup"
    echo "  Removed legacy $NVIM_HOST_FILE (now unused; backed up to $backup)" >&2
  fi

  echo "$load_mode"
}

while (( $# > 0 )); do
  case "$1" in
    --no-sync)         DO_SYNC=0 ;;
    --sync-only)       SYNC_ONLY=1 ;;
    --to-py)
      [[ -n "$SYNC_DIR" ]] && die "only one of --to-py/--to-ipynb/--force-to-py/--force-to-ipynb"
      SYNC_DIR="to-py" ;;
    --to-ipynb)
      [[ -n "$SYNC_DIR" ]] && die "only one of --to-py/--to-ipynb/--force-to-py/--force-to-ipynb"
      SYNC_DIR="to-ipynb" ;;
    --force-to-py)
      [[ -n "$SYNC_DIR" ]] && die "only one of --to-py/--to-ipynb/--force-to-py/--force-to-ipynb"
      SYNC_DIR="to-py";    SYNC_FORCE=1 ;;
    --force-to-ipynb)
      [[ -n "$SYNC_DIR" ]] && die "only one of --to-py/--to-ipynb/--force-to-py/--force-to-ipynb"
      SYNC_DIR="to-ipynb"; SYNC_FORCE=1 ;;
    --no-jupyter)      DO_JUPYTER=0 ;;
    --no-jupynium)     DO_JUPYNIUM=0 ;;
    --no-nvim)         DO_NVIM=0 ;;
    --no-color)        USE_COLOR="no" ;;
    --yes|-y)          WIZARD_YES=1 ;;
    --venv)
      shift
      case "${1:-}" in
        project) WIZARD_VENV_CHOICE="P" ;;
        user-wide) WIZARD_VENV_CHOICE="U" ;;
        *) die "--venv must be 'project' or 'user-wide'" ;;
      esac ;;
    --bin-only)        WIZARD_BIN_CHOICE="B" ;;
    --no-nvim-install) WIZARD_NVIM_CHOICE="N" ;;
    --nvim-load)
      shift
      case "${1:-}" in
        ft|cmd|eager|manual) WIZARD_NVIM_LOAD="$1" ;;
        *) die "--nvim-load must be one of: ft cmd eager manual" ;;
      esac ;;
    --nvim-advance-keymap)
      shift
      case "${1:-}" in
        yes|no) WIZARD_NVIM_KEYMAP="$1" ;;
        *) die "--nvim-advance-keymap must be 'yes' or 'no'" ;;
      esac ;;
    --install)
      [[ "$MODE" == "run" ]] || die "only one mode flag allowed (--install/--install-nvim/--uninstall/--doctor)"
      MODE="install" ;;
    --install-nvim)
      [[ "$MODE" == "run" ]] || die "only one mode flag allowed (--install/--install-nvim/--uninstall/--doctor)"
      MODE="install-nvim" ;;
    --uninstall)
      [[ "$MODE" == "run" ]] || die "only one mode flag allowed (--install/--install-nvim/--uninstall/--doctor)"
      MODE="uninstall" ;;
    --doctor)
      [[ "$MODE" == "run" ]] || die "only one mode flag allowed (--install/--install-nvim/--uninstall/--doctor)"
      MODE="doctor" ;;
    -h|--help)         usage; exit 0 ;;
    *)                 echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

if (( DO_SYNC == 0 )) && [[ -n "$SYNC_DIR" ]]; then
  die "--no-sync conflicts with --to-py/--to-ipynb/--force-to-*"
fi
if (( DO_SYNC == 0 )) && (( SYNC_ONLY == 1 )); then
  die "--no-sync conflicts with --sync-only"
fi
if (( SYNC_ONLY == 1 )) && { (( DO_JUPYTER == 0 )) || (( DO_JUPYNIUM == 0 )) || (( DO_NVIM == 0 )); }; then
  die "--sync-only already implies skipping jupyter/jupynium/nvim; do not combine with --no-*"
fi

# Wizard flags require --install, --install-nvim, or --uninstall (--yes only).
if [[ "$MODE" != "install" && "$MODE" != "install-nvim" && "$MODE" != "uninstall" ]]; then
  if (( WIZARD_YES )) || [[ -n "${WIZARD_VENV_CHOICE:-}" ]] \
     || [[ -n "${WIZARD_BIN_CHOICE:-}" ]] || [[ -n "${WIZARD_NVIM_CHOICE:-}" ]] \
     || [[ -n "${WIZARD_NVIM_LOAD:-}" ]]  || [[ -n "${WIZARD_NVIM_KEYMAP:-}" ]]; then
    die "wizard flags (--yes/--venv/--bin-only/--no-nvim-install/--nvim-load/--nvim-advance-keymap) require --install, --install-nvim, or --uninstall"
  fi
fi

# --uninstall only accepts --yes; the install-specific wizard flags are nonsensical for it.
if [[ "$MODE" == "uninstall" ]]; then
  if [[ -n "${WIZARD_VENV_CHOICE:-}" ]] || [[ -n "${WIZARD_BIN_CHOICE:-}" ]] \
     || [[ -n "${WIZARD_NVIM_CHOICE:-}" ]] || [[ -n "${WIZARD_NVIM_LOAD:-}" ]] \
     || [[ -n "${WIZARD_NVIM_KEYMAP:-}" ]]; then
    die "--uninstall only accepts --yes; --venv/--bin-only/--no-nvim-install/--nvim-load/--nvim-advance-keymap are install-only"
  fi
fi

# --bin-only only valid with --install (not --install-nvim).
if [[ "$MODE" == "install-nvim" ]] && [[ -n "${WIZARD_BIN_CHOICE:-}" ]]; then
  die "--bin-only is only valid with --install"
fi

# ---------- Colors ----------
setup_colors() {
  local enable=0
  case "$USE_COLOR" in
    yes) enable=1 ;;
    no)  enable=0 ;;
    auto)
      if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]] && [[ -z "${NO_COLOR:-}" ]]; then
        enable=1
      fi
      ;;
  esac
  if (( enable )); then
    C_SYNC=$'\e[36m'       # cyan
    C_JUPYTER=$'\e[33m'    # yellow
    C_JUPYNIUM=$'\e[35m'   # magenta
    C_NVIM=$'\e[32m'       # green
    C_CLEANUP=$'\e[2;37m'  # dim white
    C_ERROR=$'\e[31m'      # red
    C_RESET=$'\e[0m'
  else
    C_SYNC=""; C_JUPYTER=""; C_JUPYNIUM=""; C_NVIM=""; C_CLEANUP=""; C_ERROR=""; C_RESET=""
  fi
}

log_sync()    { printf '%s[sync]%s     %s\n' "$C_SYNC"     "$C_RESET" "$*"; }
log_jupyter() { printf '%s[jupyter]%s  %s\n' "$C_JUPYTER"  "$C_RESET" "$*"; }
log_jupynium(){ printf '%s[jupynium]%s %s\n' "$C_JUPYNIUM" "$C_RESET" "$*"; }
log_nvim()    { printf '%s[nvim]%s     %s\n' "$C_NVIM"     "$C_RESET" "$*"; }
log_cleanup() { printf '%s[cleanup]%s  %s\n' "$C_CLEANUP"  "$C_RESET" "$*"; }
log_error() {
  # $1 = section name (e.g. "sync"), $2 = message
  printf '[%s] %sERROR:%s %s\n' "$1" "$C_ERROR" "$C_RESET" "$2" >&2
}

# ---------- Venv resolution ----------
REQUIRED_BINS=(jupynium jupyter ipynb2jupytext jupytext)

# Echoes the bin dir on stdout, or empty if using system PATH. Aborts on failure.
resolve_venv() {
  local candidate=""
  local source=""

  # 1) $JUPY_VENV
  if [[ -n "${JUPY_VENV:-}" ]]; then
    candidate="${JUPY_VENV}/bin"
    source='$JUPY_VENV'
    _check_venv_bins "$candidate" "$source"
    echo "$candidate"
    return 0
  fi

  # 2) $PWD/$JUPYKIT_PROJECT_VENV/
  if [[ -x "$PWD/$JUPYKIT_PROJECT_VENV/bin/jupynium" ]]; then
    candidate="$PWD/$JUPYKIT_PROJECT_VENV/bin"
    source="./$JUPYKIT_PROJECT_VENV/"
    _check_venv_bins "$candidate" "$source"
    echo "$candidate"
    return 0
  fi

  # 3) Walk-up
  local dir="$PWD"
  while [[ "$dir" != "/" ]] && [[ "$dir" != "$HOME" ]]; do
    dir="$(dirname "$dir")"
    if [[ -x "$dir/$JUPYKIT_PROJECT_VENV/bin/jupynium" ]]; then
      candidate="$dir/$JUPYKIT_PROJECT_VENV/bin"
      source="$dir/$JUPYKIT_PROJECT_VENV/ (walk-up)"
      _check_venv_bins "$candidate" "$source"
      echo "$candidate"
      return 0
    fi
    [[ "$dir" == "/" ]] && break
  done
  # Also check $HOME itself
  if [[ -x "$HOME/$JUPYKIT_PROJECT_VENV/bin/jupynium" ]]; then
    candidate="$HOME/$JUPYKIT_PROJECT_VENV/bin"
    source="$HOME/$JUPYKIT_PROJECT_VENV/ (walk-up)"
    _check_venv_bins "$candidate" "$source"
    echo "$candidate"
    return 0
  fi

  # 4) System PATH
  local missing=0
  for bin in "${REQUIRED_BINS[@]}"; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      missing=1
      break
    fi
  done
  if (( missing == 0 )); then
    echo ""  # no bin dir; rely on PATH
    return 0
  fi

  # 5) Fail
  cat >&2 <<EOF
[jupykit] ERROR: could not locate a jupynium installation.

Looked for, in order:
  1. \$JUPY_VENV  (not set)
  2. ./$JUPYKIT_PROJECT_VENV/bin/jupynium  (not found)
  3. $JUPYKIT_PROJECT_VENV/bin/jupynium in any parent of \$PWD up to \$HOME  (not found)
  4. jupynium / jupyter / ipynb2jupytext / jupytext on PATH  (incomplete)

Fix: run --install (recommended), or create a venv yourself with
    uv venv $JUPYKIT_PROJECT_VENV && \\
      VIRTUAL_ENV=./$JUPYKIT_PROJECT_VENV uv pip install jupynium notebook pynvim ipykernel
or install system-wide with
    uv tool install jupynium && uv tool install notebook && uv tool install jupytext
or set JUPY_VENV=/path/to/venv
EOF
  exit 1
}

# Aborts if any required bin missing from the given bin dir.
_check_venv_bins() {
  local bindir="$1" source="$2"
  for bin in "${REQUIRED_BINS[@]}"; do
    if [[ ! -x "$bindir/$bin" ]]; then
      echo "[jupykit] ERROR: venv at $source ($bindir) is missing: $bin" >&2
      echo "  install with: VIRTUAL_ENV=\"$(dirname "$bindir")\" uv pip install jupynium notebook pynvim ipykernel jupytext" >&2
      exit 1
    fi
  done
}

# ---------- Sync ----------
SYNC_ERRORS=0

# Echoes the file's mtime as epoch seconds (or 0 if the file is missing).
_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }

_sync_ipynb_to_py() {
  local ipynb="$1"
  if ipynb2jupytext -y "$ipynb" >/dev/null 2>&1; then
    touch -r "$ipynb" "${ipynb%.ipynb}.ju.py"
    log_sync "-> $ipynb (regenerated .ju.py)"
  else
    log_error "sync" "$ipynb (ipynb2jupytext failed)"
    SYNC_ERRORS=$(( SYNC_ERRORS + 1 ))
  fi
}

_sync_py_to_ipynb() {
  local jupy="$1"
  local out="${jupy%.ju.py}.ipynb"
  if jupytext --to ipynb -o "$out" "$jupy" >/dev/null 2>&1; then
    touch -r "$jupy" "$out"
    log_sync "-> $jupy (regenerated .ipynb)"
  else
    log_error "sync" "$jupy (jupytext --to ipynb failed)"
    SYNC_ERRORS=$(( SYNC_ERRORS + 1 ))
  fi
}

run_sync() {
  log_sync "scanning $PWD"
  # First pass: walk .ipynb files
  while IFS= read -r ipynb; do
    local jupy="${ipynb%.ipynb}.ju.py"
    if [[ ! -f "$jupy" ]]; then
      # Orphan ipynb: always create .ju.py (unless --to-ipynb)
      [[ "$SYNC_DIR" == "to-ipynb" ]] && continue
      _sync_ipynb_to_py "$ipynb"
      continue
    fi
    local mi mj
    mi=$(_mtime "$ipynb"); mj=$(_mtime "$jupy")
    if (( SYNC_FORCE )); then
      case "$SYNC_DIR" in
        to-py)    _sync_ipynb_to_py "$ipynb" ;;
        to-ipynb) _sync_py_to_ipynb "$jupy" ;;
      esac
      continue
    fi
    if (( mi > mj )); then
      [[ "$SYNC_DIR" == "to-ipynb" ]] && continue
      _sync_ipynb_to_py "$ipynb"
    elif (( mj > mi )); then
      [[ "$SYNC_DIR" == "to-py" ]] && continue
      _sync_py_to_ipynb "$jupy"
    fi
  done < <(find . -name "*.ipynb" \
             -not -path "*/.ipynb_checkpoints/*" \
             -not -path "*/$JUPYKIT_PROJECT_VENV/*" \
             -not -path "*/$JUPYKIT_RUN_DIR_NAME/*" \
             -not -path "*/jupynium/*" \
             -not -path "*/.run/*")

  # Second pass: orphan .ju.py files (no matching .ipynb)
  while IFS= read -r jupy; do
    local ipynb="${jupy%.ju.py}.ipynb"
    if [[ ! -f "$ipynb" ]]; then
      [[ "$SYNC_DIR" == "to-py" ]] && continue
      _sync_py_to_ipynb "$jupy"
    fi
  done < <(find . -name "*.ju.py" \
             -not -path "*/$JUPYKIT_PROJECT_VENV/*" \
             -not -path "*/$JUPYKIT_RUN_DIR_NAME/*" \
             -not -path "*/jupynium/*" \
             -not -path "*/.run/*")
}

# ---------- Runtime dir setup ----------
RUN_DIR="$PWD/$JUPYKIT_RUN_DIR_NAME"

setup_run_dir() {
  mkdir -p "$RUN_DIR"
  # Append the run dir to .gitignore if a .gitignore exists and doesn't already mention it.
  local gi="$PWD/.gitignore"
  local pattern="$JUPYKIT_RUN_DIR_NAME/"
  if [[ -f "$gi" ]] && ! grep -qxF "$pattern" "$gi" && ! grep -qxF "$JUPYKIT_RUN_DIR_NAME" "$gi"; then
    echo "$pattern" >> "$gi"
    log_sync "added $pattern to $gi"
  fi
}

# ---------- Cleanup ----------
cleanup() {
  if [[ -f "$JUPYNIUM_PID_FILE" ]]; then
    local pid
    pid=$(cat "$JUPYNIUM_PID_FILE")
    log_cleanup "stopping jupynium ($pid)"
    # Negative PID targets the whole process group (set up via setsid in start_jupynium).
    # This takes down jupynium + geckodriver + Firefox in one shot.
    kill -- -"$pid" 2>/dev/null || true
    rm -f "$JUPYNIUM_PID_FILE"
  fi
  if [[ -f "$JUPYTER_PID_FILE" ]]; then
    local pid
    pid=$(cat "$JUPYTER_PID_FILE")
    log_cleanup "stopping jupyter ($pid)"
    kill "$pid" 2>/dev/null || true
    rm -f "$JUPYTER_PID_FILE"
  fi
}

# ---------- Jupyter phase ----------
JUPYTER_PID_FILE="$RUN_DIR/jupyter.pid"
JUPYTER_LOG="$RUN_DIR/jupyter.log"

start_jupyter() {
  # Stale PID check
  if [[ -f "$JUPYTER_PID_FILE" ]]; then
    local old_pid
    old_pid=$(cat "$JUPYTER_PID_FILE")
    if kill -0 "$old_pid" 2>/dev/null; then
      log_error "jupyter" "already running (pid $old_pid); kill it or use --no-jupyter"
      exit 1
    fi
    rm -f "$JUPYTER_PID_FILE"
  fi

  # Port check
  if (exec 3<>/dev/tcp/127.0.0.1/8888) 2>/dev/null; then
    exec 3<&-; exec 3>&-
    log_error "jupyter" "port 8888 already in use; use --no-jupyter if you have one running"
    exit 1
  fi

  # Pass both NotebookApp.* (NB6 / classic) and ServerApp.* (NB7 / jupyter_server)
  # config aliases so the script is version-agnostic. Each version warns about
  # the unknown alias and uses its own.
  jupyter notebook --no-browser \
    --NotebookApp.token='' --NotebookApp.password='' \
    --NotebookApp.notebook_dir="$PWD" \
    --ServerApp.token='' --ServerApp.password='' \
    --ServerApp.root_dir="$PWD" \
    > "$JUPYTER_LOG" 2>&1 &
  echo $! > "$JUPYTER_PID_FILE"
  local pid
  pid=$(cat "$JUPYTER_PID_FILE")
  log_jupyter "starting (pid $pid), waiting for ready..."

  # Poll http://localhost:8888/api for up to 10s
  local i
  for i in {1..20}; do
    if curl -fsS http://localhost:8888/api >/dev/null 2>&1; then
      log_jupyter "ready on :8888 (pid $pid)"
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      log_error "jupyter" "died during startup; last 20 lines of log:"
      tail -n 20 "$JUPYTER_LOG" >&2
      exit 1
    fi
    sleep 0.5
  done
  log_error "jupyter" "did not respond within 10s; last 20 lines of log:"
  tail -n 20 "$JUPYTER_LOG" >&2
  exit 1
}

# ---------- Jupynium phase ----------
JUPYNIUM_PID_FILE="$RUN_DIR/jupynium.pid"
JUPYNIUM_LOG="$RUN_DIR/jupynium.log"

start_jupynium() {
  if [[ -f "$JUPYNIUM_PID_FILE" ]]; then
    local old_pid
    old_pid=$(cat "$JUPYNIUM_PID_FILE")
    if kill -0 "$old_pid" 2>/dev/null; then
      log_error "jupynium" "already running (pid $old_pid); kill it or use --no-jupynium"
      exit 1
    fi
    rm -f "$JUPYNIUM_PID_FILE"
  fi

  # setsid puts jupynium in its own process group so cleanup can kill the
  # whole tree (jupynium + geckodriver + Firefox) with kill -- -PID.
  # The URL must match jupynium.nvim's default_notebook_URL exactly: when nvim
  # attaches, jupynium reuses the existing tab for that URL instead of opening
  # a duplicate "home window". The plain `localhost:8888` redirects to /tree.
  setsid jupynium --notebook_URL localhost:8888 \
    > "$JUPYNIUM_LOG" 2>&1 &
  echo $! > "$JUPYNIUM_PID_FILE"
  local pid
  pid=$(cat "$JUPYNIUM_PID_FILE")
  log_jupynium "starting (pid $pid), waiting for browser..."

  # Poll the log for a startup marker. We give it 15s because Firefox driver
  # can be slow on first run.
  # Jupynium has no HTTP surface pre-attach, so we watch its log file for
  # the readiness marker instead of polling an endpoint (cf. jupyter above).
  local i
  for i in {1..30}; do
    if grep -qiE 'waiting for nvim to attach|nvim attached' "$JUPYNIUM_LOG" 2>/dev/null; then
      log_jupynium "ready (pid $pid)"
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      log_error "jupynium" "died during startup; last 20 lines of log:"
      tail -n 20 "$JUPYNIUM_LOG" >&2
      exit 1
    fi
    sleep 0.5
  done
  log_error "jupynium" "did not signal readiness within 15s; last 20 lines of log:"
  tail -n 20 "$JUPYNIUM_LOG" >&2
  exit 1
}

# ---------- Mode: run (default orchestrator) ----------
cmd_run() {
  # Pre-flight: nvim must exist if we plan to launch it.
  if (( DO_NVIM )) && ! command -v nvim >/dev/null 2>&1; then
    die "nvim not found in PATH (use --no-nvim to skip the nvim phase)"
  fi

  setup_colors

  VENV_BIN="$(resolve_venv)"
  if [[ -n "$VENV_BIN" ]]; then
    export PATH="$VENV_BIN:$PATH"
    log_sync "using venv at $VENV_BIN"
  else
    log_sync "using system PATH for jupynium binaries"
  fi

  if (( DO_SYNC )); then run_sync; fi

  if (( SYNC_ONLY )); then
    if (( SYNC_ERRORS > 0 )); then exit 2; fi
    exit 0
  fi

  setup_run_dir
  trap cleanup EXIT

  if (( DO_JUPYTER )); then start_jupyter; fi
  if (( DO_JUPYNIUM )); then start_jupynium; fi

  if (( DO_NVIM )); then
    log_nvim "opening in $PWD"
    nvim "$PWD"
  else
    trap - EXIT
    log_nvim "skipped (--no-nvim); servers remain running"
    log_nvim "  jupyter pid: $(cat "$JUPYTER_PID_FILE" 2>/dev/null || echo n/a)"
    log_nvim "  jupynium pid: $(cat "$JUPYNIUM_PID_FILE" 2>/dev/null || echo n/a)"
    log_nvim "  stop them with: kill \$(cat $RUN_DIR/*.pid)"
  fi

  if (( SYNC_ERRORS > 0 )); then exit 2; fi
  exit 0
}

# ---------- Mode: install ----------
cmd_install() {
  setup_colors
  echo
  echo "═══════════════════════════════════════════════════════════"
  echo "  jupykit $JUPYKIT_VERSION installer"
  echo "═══════════════════════════════════════════════════════════"

  if ! command -v uv >/dev/null 2>&1; then
    die "uv not found. Install with: curl -LsSf https://astral.sh/uv/install.sh | sh"
  fi

  local venv_path script_path nvim_result
  venv_path=$(wizard_step_venv)
  script_path=$(wizard_step_script)
  nvim_result=$(wizard_step_nvim "$venv_path")

  echo
  echo "[4/4] Summary"
  echo "  Venv:    $venv_path"
  echo "  Script:  $script_path"
  echo "  Nvim:    $nvim_result"
  echo
  echo "  Run with:  $script_path"
  echo "  Verify:    $script_path --doctor"
  echo
}

# ---------- Mode: install-nvim ----------
cmd_install_nvim() {
  setup_colors
  echo "jupykit $JUPYKIT_VERSION — nvim configuration"

  # Need to know the venv path so the host file points at the right python.
  # Use the standard venv resolution chain (the same one cmd_run uses).
  local venv_bin venv_path
  venv_bin=$(resolve_venv) || die "Run --install first to set up the venv, then --install-nvim."
  if [[ -z "$venv_bin" ]]; then
    die "jupynium found on system PATH, not in a venv. --install-nvim needs an explicit venv to point python_host at. Run --install."
  fi
  venv_path=$(dirname "$venv_bin")  # strip the trailing /bin

  wizard_step_nvim "$venv_path"
}

# ---------- Mode: uninstall ----------

# Confirm a destructive uninstall action. Returns 0 (proceed) or 1 (skip).
# Default is N (refuse) to keep accidents cheap. With WIZARD_YES set, always
# proceeds and logs that fact instead of prompting.
_uninstall_confirm() {
  local prompt="$1"
  if (( WIZARD_YES )); then
    echo "  → $prompt yes (--yes)"
    return 0
  fi
  local ans
  ans=$(prompt_letter "  $prompt" "YN" "N")
  [[ "$ans" == "Y" ]]
}

# Kill processes matching a pgrep -f pattern, but never kill our own shell
# or its parent (a heredoc-style invocation can put the pattern in the parent's
# argv and lead to self-immolation). Patterns should be argv signatures
# specific enough that arbitrary shell command lines won't match.
_uninstall_pkill() {
  local pattern="$1"
  local pids pid out=""
  pids=$(pgrep -f -- "$pattern" 2>/dev/null || true)
  for pid in $pids; do
    [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
    out+=" $pid"
  done
  [[ -n "$out" ]] || return 0
  # shellcheck disable=SC2086
  kill $out 2>/dev/null || true
}

cmd_uninstall() {
  setup_colors
  echo
  echo "═══════════════════════════════════════════════════════════"
  echo "  jupykit $JUPYKIT_VERSION uninstaller"
  echo "═══════════════════════════════════════════════════════════"
  echo
  echo "Reverses what --install did. Each step is detected and prompted"
  echo "separately; the default answer is N, so pressing Enter skips."
  if (( WIZARD_YES )); then
    echo "  --yes given: every detected component will be removed without prompting."
  fi

  local steps_applied=0

  # ---- [1/6] Running processes ----
  # Match on jupykit's own argv signatures (not just bare names) so a parent
  # shell whose command line incidentally contains "jupynium" / "geckodriver"
  # doesn't get matched. The patterns are anchored to flags jupykit always
  # passes when it starts these processes.
  echo
  echo "[1/6] Running processes"
  local jn_pat='jupynium --notebook_URL'
  local jupy_pat='jupyter-notebook --no-browser'
  local ff_pat='firefox.*rust_mozprofile'
  local gd_pat='geckodriver'
  local jupy_running=0 jn_running=0 ff_running=0 gd_running=0
  pgrep -f -- "$jn_pat"   >/dev/null 2>&1 && jn_running=1
  pgrep -f -- "$jupy_pat" >/dev/null 2>&1 && jupy_running=1
  pgrep -f -- "$ff_pat"   >/dev/null 2>&1 && ff_running=1
  pgrep -f -- "$gd_pat"   >/dev/null 2>&1 && gd_running=1
  if (( jupy_running || jn_running || ff_running || gd_running )); then
    (( jn_running ))   && echo "  • jupynium is running"
    (( jupy_running )) && echo "  • jupyter-notebook is running"
    (( ff_running ))   && echo "  • Selenium-controlled firefox is running"
    (( gd_running ))   && echo "  • geckodriver is running"
    if _uninstall_confirm "Kill these processes?"; then
      (( jn_running ))   && _uninstall_pkill "$jn_pat"
      (( jupy_running )) && _uninstall_pkill "$jupy_pat"
      (( ff_running ))   && _uninstall_pkill "$ff_pat"
      (( gd_running ))   && _uninstall_pkill "$gd_pat"
      echo "  Killed."
      steps_applied=$(( steps_applied + 1 ))
    else
      echo "  Skipped."
    fi
  else
    echo "  ✓ none running"
  fi

  # ---- [2/6] Jupynium venvs ----
  # Only touch a venv that looks jupykit-installed (has pyvenv.cfg AND a
  # jupynium binary) so we don't blow away an unrelated directory that
  # happens to share the name. Also detect the legacy ./jupynium/ path
  # so users migrating from pre-rename installs can clean up in one shot.
  echo
  echo "[2/6] Jupynium venvs"
  local found_venv=0 venv
  local project_venv legacy_project_venv
  project_venv=$(realpath -m "$VENV_PROJECT_PATH")
  legacy_project_venv=$(realpath -m "./jupynium")
  # Dedupe so users who set JUPYKIT_PROJECT_VENV=jupynium don't see two prompts.
  local venv_candidates=("$VENV_USERWIDE_PATH" "$project_venv")
  [[ "$legacy_project_venv" != "$project_venv" ]] && venv_candidates+=("$legacy_project_venv")
  for venv in "${venv_candidates[@]}"; do
    if [[ -f "$venv/pyvenv.cfg" && -x "$venv/bin/jupynium" ]]; then
      found_venv=1
      local tag=""
      [[ "$venv" == "$legacy_project_venv" && "$legacy_project_venv" != "$project_venv" ]] && tag=" (legacy name)"
      echo "  • Found jupykit-installed venv: $venv$tag"
      if _uninstall_confirm "Delete it?"; then
        rm -rf "$venv"
        echo "    Removed $venv"
        steps_applied=$(( steps_applied + 1 ))
      else
        echo "    Skipped."
      fi
    fi
  done
  (( found_venv == 0 )) && echo "  ✓ no jupykit venv at default locations ($VENV_USERWIDE_PATH, $project_venv)"

  # ---- [3/6] System-wide script (~/.local/bin/jupykit) ----
  echo
  echo "[3/6] System-wide script (~/.local/bin/jupykit)"
  local bin_target="$HOME/.local/bin/jupykit"
  local bin_backups=() b
  for b in "$bin_target".bak.*; do [[ -f "$b" ]] && bin_backups+=("$b"); done
  if [[ -f "$bin_target" ]] || (( ${#bin_backups[@]} > 0 )); then
    [[ -f "$bin_target" ]] && echo "  • $bin_target"
    for b in "${bin_backups[@]}"; do echo "  • $b"; done
    if _uninstall_confirm "Delete script and backups?"; then
      [[ -f "$bin_target" ]] && rm -f "$bin_target"
      (( ${#bin_backups[@]} > 0 )) && rm -f "${bin_backups[@]}"
      echo "  Removed."
      steps_applied=$(( steps_applied + 1 ))
    else
      echo "  Skipped."
    fi
  else
    echo "  ✓ not installed at $bin_target"
  fi

  # ---- [4/6] Shellrc JUPY_VENV export ----
  echo
  echo "[4/6] Shellrc JUPY_VENV export (~/.bashrc, ~/.zshrc)"
  local rc_found=() rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] && grep -qF "# Added by jupykit (do not edit this line)" "$rc" && rc_found+=("$rc")
  done
  if (( ${#rc_found[@]} > 0 )); then
    for rc in "${rc_found[@]}"; do echo "  • Marker present in $rc"; done
    if _uninstall_confirm "Remove the JUPY_VENV export line from these files?"; then
      for rc in "${rc_found[@]}"; do
        if _remove_shellrc_jupy_venv "$rc"; then
          echo "    Cleaned $rc"
        fi
      done
      steps_applied=$(( steps_applied + 1 ))
    else
      echo "  Skipped."
    fi
  else
    echo "  ✓ no jupykit marker in ~/.bashrc or ~/.zshrc"
  fi

  # ---- [5/6] Nvim configs ----
  echo
  echo "[5/6] Nvim configs"
  local nvim_files=() nvim_baks=() f
  [[ -f "$NVIM_PLUGIN_FILE" ]] && nvim_files+=("$NVIM_PLUGIN_FILE")
  [[ -f "$NVIM_HOST_FILE" ]]   && nvim_files+=("$NVIM_HOST_FILE")
  for f in "$NVIM_PLUGIN_FILE".bak.* "$NVIM_HOST_FILE".bak.*; do
    [[ -f "$f" ]] && nvim_baks+=("$f")
  done
  if (( ${#nvim_files[@]} > 0 || ${#nvim_baks[@]} > 0 )); then
    for f in "${nvim_files[@]}" "${nvim_baks[@]}"; do echo "  • $f"; done
    if _uninstall_confirm "Delete these nvim config files?"; then
      (( ${#nvim_files[@]} > 0 )) && rm -f "${nvim_files[@]}"
      (( ${#nvim_baks[@]} > 0 ))  && rm -f "${nvim_baks[@]}"
      echo "  Removed. Inside nvim, run :Lazy clean to drop the jupynium.nvim plugin itself."
      steps_applied=$(( steps_applied + 1 ))
    else
      echo "  Skipped."
    fi
  else
    echo "  ✓ no jupykit-managed nvim files found"
  fi

  # ---- [6/6] Per-project run dir in current directory ----
  echo
  echo "[6/6] Per-project artifacts ($JUPYKIT_RUN_DIR_NAME/ in $PWD)"
  local run_candidates=("$PWD/$JUPYKIT_RUN_DIR_NAME")
  [[ "$JUPYKIT_RUN_DIR_NAME" != ".run" ]] && run_candidates+=("$PWD/.run")
  local rd found_run=0
  for rd in "${run_candidates[@]}"; do
    if [[ -d "$rd" ]]; then
      found_run=1
      local tag=""
      [[ "$rd" == "$PWD/.run" && "$JUPYKIT_RUN_DIR_NAME" != ".run" ]] && tag=" (legacy name)"
      echo "  • $rd/ exists$tag"
      if _uninstall_confirm "Delete it?"; then
        rm -rf "$rd"
        echo "    Removed."
        steps_applied=$(( steps_applied + 1 ))
      else
        echo "    Skipped."
      fi
    fi
  done
  (( found_run == 0 )) && echo "  ✓ no run dir in $PWD"
  echo "  (Other projects' run dirs are untouched — delete those by hand if needed.)"

  echo
  if (( steps_applied > 0 )); then
    echo "Uninstall complete: $steps_applied step(s) applied."
  else
    echo "Nothing to do — no jupykit components detected (or all skipped)."
  fi
}

# ---------- Mode: doctor ----------
cmd_doctor() {
  setup_colors
  local advisories=0 failures=0

  echo "jupykit $JUPYKIT_VERSION — diagnostic"
  echo

  # Venv
  local venv_bin
  if venv_bin=$(resolve_venv 2>/dev/null); then
    if [[ -n "$venv_bin" ]]; then
      echo "[venv]    Discovered at $venv_bin"
      local bin
      for bin in jupynium jupyter ipynb2jupytext jupytext; do
        if [[ -x "$venv_bin/$bin" ]]; then
          echo "[venv]    ✓ $bin"
        else
          echo "[venv]    ✗ $bin missing"
          failures=$(( failures + 1 ))
        fi
      done
      if [[ -x "$venv_bin/python" ]] && "$venv_bin/python" -c 'import pynvim' 2>/dev/null; then
        echo "[venv]    ✓ pynvim importable"
      else
        echo "[venv]    ✗ pynvim not importable from venv python"
        failures=$(( failures + 1 ))
      fi
      # Python version: notebook<7 imports distutils, removed from stdlib in 3.12.
      if [[ -x "$venv_bin/python" ]]; then
        local py_ver py_major py_minor
        py_ver=$("$venv_bin/python" -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")' 2>/dev/null || true)
        if [[ -n "$py_ver" ]]; then
          IFS='.' read -r py_major py_minor <<< "$py_ver"
          if (( py_major == 3 )) && (( py_minor >= 12 )); then
            echo "[venv]    ✗ Python $py_ver — notebook<7 needs <3.12 (distutils removed in 3.12)"
            echo "[venv]      Rebuild: --uninstall (or rm -rf the venv) then --install"
            failures=$(( failures + 1 ))
          else
            echo "[venv]    ✓ Python $py_ver (compatible with notebook<7)"
          fi
        fi
      fi
    else
      echo "[venv]    Using system PATH for jupynium binaries"
      echo "[venv]    (no JUPY_VENV / no ./jupynium / no walk-up match)"
    fi
  else
    echo "[venv]    ✗ no jupynium installation found"
    failures=$(( failures + 1 ))
  fi

  # Nvim
  if command -v nvim >/dev/null 2>&1; then
    echo "[nvim]    ✓ Found at $(command -v nvim)"
    if [[ -f "$NVIM_PLUGIN_FILE" ]]; then
      echo "[nvim]    ✓ $NVIM_PLUGIN_FILE exists"
    else
      echo "[nvim]    ⚠ $NVIM_PLUGIN_FILE missing (run --install or --install-nvim)"
      advisories=$(( advisories + 1 ))
    fi
    if [[ -f "$NVIM_HOST_FILE" ]]; then
      echo "[nvim]    ⚠ legacy $NVIM_HOST_FILE exists (no longer used; rerun --install-nvim to clean up)"
      advisories=$(( advisories + 1 ))
    fi
  else
    echo "[nvim]    ✗ nvim not in PATH"
    failures=$(( failures + 1 ))
  fi

  # Script
  echo "[script]  jupykit at $(realpath -m "$0") (version $JUPYKIT_VERSION)"
  if echo ":$PATH:" | grep -q ":$HOME/.local/bin:"; then
    echo "[script]  ✓ ~/.local/bin on PATH"
  else
    echo "[script]  ⚠ ~/.local/bin not on PATH (system-wide install won't be callable)"
    advisories=$(( advisories + 1 ))
  fi

  # Browser — jupynium is hard-coded to Firefox upstream (Chrome support is
  # commented out in jupynium's source). Check Firefox is available.
  if command -v firefox >/dev/null 2>&1; then
    echo "[browser] ✓ firefox at $(command -v firefox)"
  else
    echo "[browser] ✗ firefox not found (jupynium requires Firefox; Chrome is not supported upstream)"
    failures=$(( failures + 1 ))
  fi

  # Port
  if (exec 3<>/dev/tcp/127.0.0.1/8888) 2>/dev/null; then
    exec 3<&-; exec 3>&-
    echo "[ports]   ⚠ port 8888 in use"
    advisories=$(( advisories + 1 ))
  else
    echo "[ports]   ✓ port 8888 free"
  fi

  # Stale PIDs
  local run_dir="$PWD/$JUPYKIT_RUN_DIR_NAME"
  if [[ -d "$run_dir" ]] && ls "$run_dir"/*.pid 2>/dev/null | grep -q .; then
    echo "[run]     ⚠ stale PID files in $run_dir/ (run jupykit to clean up)"
    advisories=$(( advisories + 1 ))
  else
    echo "[run]     ✓ no stale PID files in $run_dir/"
  fi

  echo
  if (( failures > 0 )); then
    echo "Result: $failures failure(s), $advisories advisory/ies"
    exit 1
  else
    echo "Result: OK ($advisories advisory/ies)"
    exit 0
  fi
}

# ---------- Mode dispatch ----------
case "$MODE" in
  run)          cmd_run ;;
  install)      cmd_install ;;
  install-nvim) cmd_install_nvim ;;
  uninstall)    cmd_uninstall ;;
  doctor)       cmd_doctor ;;
  *)            die "internal error: unknown MODE=$MODE" ;;
esac
