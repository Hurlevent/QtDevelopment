#!/usr/bin/env bash
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
    echo "Error: bash 4.2 or later is required (found ${BASH_VERSION})" >&2
    echo "On macOS: brew install bash, then invoke as: bash please.sh <command>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QT6_DIR="$SCRIPT_DIR/qt6"
DEFAULT_BRANCH="dev"
DEFAULT_MODULES=(qtbase qtshadertools qtdeclarative)
# Qt Creator keeps its settings in INI format, which QSettings puts under
# $XDG_CONFIG_HOME (default ~/.config) on macOS as well as Linux.
QTCREATOR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/QtProject/qtcreator"
QTCREATOR_XML="$QTCREATOR_DIR/qtversion.xml"

usage() {
    cat << EOF
Usage: $0 <command> [args]

Commands:
  help                        Show full help and dependency information
  create  [--lts] [branch] [modules]  Add a git worktree for [branch], initialize submodules, and update .clangd
  build   [branch] [reserve] [--reconfigure] [--creator] [-- configure-args...]  Configure and build; [reserve] idle CPU cores (default: 0)
  destroy [branch]            Remove the worktree, build dir, and .code-workspace for [branch]
  update  [--sync] [--lts] [branch]  Fetch and rebase all initialized submodules onto [branch]; with --sync also runs QtSynchronizeRepo.cmake
  app-add    [branch] <path>  Build an external app against the Qt build for [branch] and register it in the workspace
  app-remove [branch] <name|--all>  Remove a registered app (or all apps) from the build directory and workspace
  app-list   [branch]         List all apps registered for [branch]
  app-run    [branch] <name>  Build and run a registered app

Linux only commands:
  wayland-list                List active Wayland sessions in /run/user/<uid>/
  kde-hijack [branch]         Point kde-builder's qt-install-dir at the given worktree's Qt build
                              and symlink kde-project-browser into ~/kde
  kde-startkwin               Start kwin_wayland from the kde-builder kwin build
  kde-startplasma             Start a Plasma Wayland session from the kde-builder plasma-workspace build

[branch] defaults to '$DEFAULT_BRANCH' when omitted

--lts selects the commercial LTS branch (tqtc/lts-[branch]) from the tqtc- mirrors
instead of the frozen public one, e.g. $0 create --lts 6.2

[modules] is a comma-separated list of submodules (default: qtbase,qtshadertools,qtdeclarative)
EOF
    exit 1
}

cmd_help() {
    cat << 'EOF'
please.sh — Qt6 workspace manager

PURPOSE
  Manages parallel Qt6 development environments rooted in a single directory.
  Each branch gets its own git worktree (source), build directory, and VS Code
  workspace file, all wired up so that clangd finds the right compile_commands.json
  without touching any files inside the Qt source trees.

WORKFLOW
  1. ./please.sh create [--lts] <branch> [modules]
       Adds a git worktree for <branch> inside the current directory, then
       initializes the requested submodules and checks them out at origin/<branch>.
       Submodule dependencies marked required: true in dependencies.yaml are
       pulled in automatically with a warning if they were not explicitly listed.
       Re-running create on an existing worktree is safe — already-initialized
       modules are skipped so only new modules are set up.
       [modules] is a comma-separated list (default: qtbase,qtshadertools,qtdeclarative).

       --lts adds the lts remote (the authenticated tqtc-<module> mirrors on
       Gerrit) to the supermodule and every submodule, and checks out the LTS
       branch tqtc/lts-<branch> where one exists. 

  2. ./please.sh build <branch> [reserve] [--reconfigure] [--creator] [-- configure-args...]
       Configures and builds each initialized module in dependency order
       (configure → ninja, one module at a time). Also regenerates the
       .code-workspace and .clangd files. The optional [reserve] argument keeps
       that many CPU cores idle: ninja is invoked with -j (nproc - reserve),
       with a minimum of 1. -developer-build is always passed to configure;
       any arguments after -- are forwarded alongside it. configure itself
       treats -DNAME=VALUE as a C++ define, so CMake variables go after a
       second --, which configure passes on to CMake, e.g.:
         ./please.sh build dev 2 -- -nomake tests -- -DQT_BUILD_EXAMPLES=ON
       --reconfigure deletes each module's CMakeCache.txt before configuring,
       forcing CMake to re-detect all features (e.g. after adding a new module).
       Existing compiled objects are preserved so only affected targets rebuild.
       --creator also sets the branch up for Qt Creator: a session named
       <branch>, a Qt version and kit "please.sh (<branch>)", and for each
       module a .qtcreator/CMakeLists.txt.user and CMakeUserPresets.json.
       Opening the session then gives fully configured projects (with clangd)
       that use the existing build directories, so Qt Creator never configures
       a build directory of its own. Close Qt Creator first: it overwrites the
       kit and Qt version settings when it exits. Once a branch has a session,
       app-add and app-remove keep it up to date.
       After building, all tst_* binaries under tests/auto/ and all executables
       under examples/ are registered as runnable and debuggable tasks in the
       generated .code-workspace file.

  3. ./please.sh update [--sync] [--lts] <branch>
       Fetches each initialized submodule's remotes and rebases it onto <branch>.
       Aborts immediately if any module has uncommitted changes.
       Whether the public or the LTS branch is used follows the branch the
       worktree is already on, so --lts never needs repeating here.
       With --sync, also runs cmake/QtSynchronizeRepo.cmake after updating to
       synchronize all submodules to a consistent state (the same operation used
       by Qt's CI system). Useful when a build fails due to submodule version
       mismatches.

  4. ./please.sh destroy <branch>
       Removes the worktree (via git worktree remove --force), the build
       directory, and the .code-workspace file, then regenerates .clangd.

  5. ./please.sh app-add <branch> <path>
       Builds an external application (any directory containing CMakeLists.txt)
       against the Qt installation for <branch>. The executable name is inferred
       from the first qt_add_executable, add_executable, or project() call in
       CMakeLists.txt. The source is copied to <branch>-apps/<name>/ and the
       build output lands in <branch>-build/apps/<name>/. The app is immediately
       added to the .code-workspace as a build+run task and a debuggable launch
       configuration, both of which rebuild the app first. Re-running app-add reconfigures and rebuilds it.

  6. ./please.sh app-remove <branch> <name|--all>
       Removes a previously registered app: deletes <branch>-build/apps/<name>/,
       removes the entry from .<branch>-apps, and regenerates the .code-workspace.
       Use --all to remove every registered app for <branch> at once.

  7. ./please.sh app-list <branch>
       Lists all apps registered for <branch> with their project type and source path.

  8. ./please.sh app-run [branch] <name>
       Configures, builds, and runs a registered app using the Qt build for [branch].
       Equivalent to the "app: <name>" VS Code task. The binary is looked up in the
       build dir and its bin/; if <name> doesn't match it (e.g. project(QtCreator)
       producing bin/qtcreator), the real target is resolved via the CMake File API.

  9. ./please.sh wayland-list  [Linux only]
       Lists all active Wayland sessions found in /run/user/<uid>/ by scanning for
       socket files whose names start with "wayland".

 10. ./please.sh kde-hijack [branch]  [Linux only]
       Redirects kde-builder to use the Qt build produced by please.sh for [branch].
       Requires ~/.local/share/kde-builder (kde-builder installed) and
       ~/.config/kde-builder.yaml. The worktree must already have been built with
       ./please.sh build. If confirmed, sets global.qt-install-dir to
       <branch>-build/qtbase and ensures qt6-set is in global.ignore-projects so
       kde-builder does not try to build Qt itself. Also symlinks
       ~/kde/kde-project-browser to the copy in this directory, so the browser can
       be run from the kde source tree. An existing symlink is repointed; an
       existing regular file is left untouched with a warning.

 11. ./please.sh kde-startkwin [-- kwin-args...]  [Linux only]
       Starts kwin_wayland using the kde-builder build of kwin at ~/kde/build/kwin.
       Checks that bin/kwin_wayland exists and is executable; if not, prints a warning
       and exits. Otherwise sources prefix.sh, cds into the bin directory, and launches:
         dbus-run-session ./kwin_wayland [kwin-args...]
       with QT_PLUGIN_PATH set to include the bin directory. Any arguments after
       -- are forwarded directly to kwin_wayland.

 12. ./please.sh kde-startplasma  [Linux only]
       Starts a Plasma Wayland session using the kde-builder build of plasma-workspace
       at ~/kde/build/plasma-workspace. Not supported on macOS. Checks that the build
       exists (prefix.sh and the startplasma-wayland binary); if not, prints a warning
       and exits. Otherwise sources prefix.sh, cds into the bin directory, and launches:
         dbus-run-session ./startplasma-wayland
       with QT_PLUGIN_PATH set to include the current bin directory.

<branch> becomes dev if omitted.

DIRECTORY LAYOUT
  qt/
  ├── qt6/                  qt5.git supermodule (the canonical clone)
  ├── <branch>/             Worktree created by: create
  ├── <branch>-build/       Build tree created by: build
  ├── <branch>-apps/        App source copies created by: app-add
  ├── Qt<branch>.code-workspace
  ├── .clangd               Auto-managed; do not edit by hand
  └── please.sh

DEPENDENCIES
  Required tools: git cmake ninja make python3 clangd pkg-config and a C++ compiler.

  Arch Linux:
    sudo pacman -S base-devel cmake ninja python git \
      xcb-util xcb-util-image xcb-util-keysyms xcb-util-renderutil xcb-util-wm \
      libxkbcommon libxkbcommon-x11 fontconfig freetype2 gtk3

  Debian/Ubuntu:
    sudo apt install build-essential cmake ninja-build python3 git \
      libfontconfig1-dev libfreetype-dev libx11-dev libx11-xcb-dev \
      libxext-dev libxfixes-dev libxi-dev libxrender-dev libxcb1-dev \
      libxcb-cursor-dev libxcb-glx0-dev libxcb-icccm4-dev libxcb-image0-dev \
      libxcb-keysyms1-dev libxcb-randr0-dev libxcb-render-util0-dev \
      libxcb-shape0-dev libxcb-shm0-dev libxcb-sync-dev libxcb-util-dev \
      libxcb-xfixes0-dev libxcb-xkb-dev libxkbcommon-dev libxkbcommon-x11-dev \
      libgtk-3-dev

  Fedora/RHEL:
    sudo dnf install gcc-c++ cmake ninja-build python3 git \
      fontconfig-devel freetype-devel libX11-devel libxcb-devel \
      xcb-util-devel xcb-util-image-devel xcb-util-keysyms-devel \
      xcb-util-renderutil-devel xcb-util-wm-devel \
      libxkbcommon-devel libxkbcommon-x11-devel gtk3-devel

  macOS:
    Install Xcode Command Line Tools: xcode-select --install
    This script requires bash 4.2+; macOS ships with bash 3.2. Install via
    Homebrew and ensure it takes precedence on PATH:
      brew install bash
      echo 'export PATH="/opt/homebrew/bin:$PATH"' >> ~/.zprofile

VSCODE EXTENSIONS
  C/C++ Extension Pack:    ext install ms-vscode.cpptools-extension-pack
  clangd:                  ext install llvm-vs-code-extensions.vscode-clangd

More info: https://wiki.qt.io/Building_Qt_6_from_Git
EOF
}

branch_to_build_dir() { echo "$1-build"; }
require_branch()       {
    local branch="$1"
    if [ -z "$branch" ] || [ ! -d "$SCRIPT_DIR/$branch" ]; then
        echo "Error: '$branch' is not an initialized branch — run: $0 create $branch" >&2
        exit 1
    fi
}
regex_escape()         { echo "$1" | sed 's/\./\\./g'; }
get_nproc()            { command -v nproc &>/dev/null && nproc || sysctl -n hw.logicalcpu; }

branch_to_workspace_file() {
    local name="$1"
    name="${name//./}"
    name="${name//\//}"
    name="${name//-/}"
    echo "Qt${name}.code-workspace"
}

# Split a comma-separated module list into one module per line
parse_modules() { tr ',' '\n' <<< "$1" | grep -v '^$'; }

# Print required Qt module dependencies from a dependencies.yaml file
parse_required_deps() {
    local yaml_file="$1"
    [ -f "$yaml_file" ] || return 0
    awk '
        /^  \.\.\/[^:]+:/ {
            if (module != "" && required) print module
            module = $0; gsub(/^  \.\.\/|:.*/, "", module)
            sub(/^tqtc-/, "", module)
            required = 0
        }
        /required: true/ { required = 1 }
        END { if (module != "" && required) print module }
    ' "$yaml_file"
}

# Parse the primary executable target name from a CMakeLists.txt.
# Checks qt_add_executable, then add_executable, then qt_internal_add_manual_test, then project(), then falls back to the directory name.
parse_cmake_exe_name() {
    local cmake_file="$1"
    local name
    name=$(sed -n 's/^[[:space:]]*qt_add_executable[[:space:]]*([[:space:]]*\([^[:space:],)]*\).*/\1/p' "$cmake_file" | head -1)
    [ -z "$name" ] && \
    name=$(sed -n 's/^[[:space:]]*add_executable[[:space:]]*([[:space:]]*\([^[:space:],)]*\).*/\1/p' "$cmake_file" | head -1)
    [ -z "$name" ] && \
    name=$(sed -n 's/^[[:space:]]*qt_internal_add_manual_test[[:space:]]*([[:space:]]*\([^[:space:],)]*\).*/\1/p' "$cmake_file" | head -1)
    [ -z "$name" ] && \
    name=$(sed -n 's/^[[:space:]]*project[[:space:]]*([[:space:]]*\([^[:space:])]*\).*/\1/p' "$cmake_file" | head -1)
    [ -z "$name" ] && name=$(basename "$(dirname "$cmake_file")")
    echo "$name"
}

# Locate the built executable for a registered app. Prints the path, or nothing if not found.
# Tries, in order: the conventional locations ($dir/$name, $dir/bin/$name, macOS bundles),
# the CMake File API reply (executable targets: exact name, then case-insensitive, then the
# only one), and finally a case-insensitive filename match in $dir and $dir/bin.
find_app_exe() {
    local build_dir="$1" name="$2"
    local candidate
    for candidate in "$build_dir/$name" "$build_dir/bin/$name" \
                     "$build_dir/$name.app/Contents/MacOS/$name" \
                     "$build_dir/bin/$name.app/Contents/MacOS/$name"; do
        [ -f "$candidate" ] && [ -x "$candidate" ] && { echo "$candidate"; return 0; }
    done

    local reply_dir="$build_dir/.cmake/api/v1/reply"
    if [ -d "$reply_dir" ]; then
        candidate=$(python3 - "$reply_dir" "$build_dir" "$name" <<'EOF' 2>/dev/null
import glob, json, os, sys
reply_dir, build_dir, name = sys.argv[1:4]
indexes = sorted(glob.glob(os.path.join(reply_dir, "index-*.json")))
if not indexes:
    sys.exit(0)
index = json.load(open(indexes[-1]))
cm_ref = index.get("reply", {}).get("codemodel-v2")
if not cm_ref:
    sys.exit(0)
codemodel = json.load(open(os.path.join(reply_dir, cm_ref["jsonFile"])))
exes = {}
for config in codemodel.get("configurations", []):
    for t in config.get("targets", []):
        target = json.load(open(os.path.join(reply_dir, t["jsonFile"])))
        if target.get("type") != "EXECUTABLE" or not target.get("artifacts"):
            continue
        path = target["artifacts"][0]["path"]
        exes.setdefault(target["name"], os.path.join(build_dir, path))
pick = exes.get(name)
if pick is None:
    matches = [p for n, p in exes.items() if n.lower() == name.lower()]
    if len(matches) == 1:
        pick = matches[0]
if pick is None and len(exes) == 1:
    pick = next(iter(exes.values()))
if pick:
    print(pick)
EOF
)
        [ -n "$candidate" ] && [ -f "$candidate" ] && [ -x "$candidate" ] && { echo "$candidate"; return 0; }
    fi

    candidate=$(find "$build_dir" "$build_dir/bin" -maxdepth 1 -type f -perm -u+x -iname "$name" 2>/dev/null | head -1)
    [ -n "$candidate" ] && { echo "$candidate"; return 0; }
    return 1
}

# Read the Gerrit username from ~/.ssh/config (Host codereview.qt-project.org, User field).
# Prints the username (may be empty), and prints a warning to stderr if the config is
# missing or incomplete.
get_gerrit_username() {
    local ssh_config="$HOME/.ssh/config"
    if [ ! -f "$ssh_config" ]; then
        echo "Warning: ~/.ssh/config not found — gerrit remote added without a username." >&2
        echo "  Follow the setup guide: https://wiki.qt.io/Setting_up_Gerrit#Local_Setup" >&2
        return 0
    fi

    local in_host=0 username=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^[Hh]ost[[:space:]]+codereview\.qt-project\.org([[:space:]]|$) ]]; then
            in_host=1
        elif [[ "$line" =~ ^[Hh]ost[[:space:]] ]] && (( in_host )); then
            break
        elif (( in_host )) && [[ "$line" =~ ^[[:space:]]*[Uu]ser[[:space:]]+(.+) ]]; then
            username="${BASH_REMATCH[1]}"
            break
        fi
    done < "$ssh_config"

    if [ -z "$username" ]; then
        echo "Warning: No User entry for codereview.qt-project.org in ~/.ssh/config." >&2
        echo "  Follow the setup guide: https://wiki.qt.io/Setting_up_Gerrit#Local_Setup" >&2
    fi
    printf '%s' "$username"
}

# Configure the lts (tqtc-) remote for a module. The tqtc- mirrors are only
# reachable over authenticated ssh, so a Gerrit username is mandatory here.
ensure_lts_remote() {
    local repo_dir="$1" module_name="$2" gerrit_user="$3" push_branch="${4:-}"

    [ -n "$gerrit_user" ] || return 1
    git -C "$repo_dir" config remote.lts.url \
        "ssh://${gerrit_user}@codereview.qt-project.org:29418/qt/tqtc-${module_name}"
    git -C "$repo_dir" config remote.lts.fetch '+refs/heads/*:refs/remotes/lts/*'
    # LTS changes are reviewed on the tqtc- project under the LTS branch name,
    # so 'git push lts' must not reuse the public remote.gerrit.push refspec.
    [ -n "$push_branch" ] \
        && git -C "$repo_dir" config remote.lts.push "HEAD:refs/for/${push_branch}"
    return 0
}

# Resolve <branch> to an explicit remote-tracking ref in <repo_dir>, printing
# e.g. 'origin/6.2' or 'lts/tqtc/lts-6.2'. Naming the remote matters: once the
# lts remote exists, a bare '6.2' matches two remote-tracking branches and git
# refuses to guess ("fatal: invalid reference: 6.2").
#
# In lts mode the tqtc/lts-<branch> topic branch wins where it exists, because
# that is where LTS patch releases land — the public '6.2' is frozen at the
# last open-source release (6.2.4). Branches with no tqtc/lts- counterpart
# (dev, 6.11, ...) resolve as usual, so for those --lts keeps its old meaning
# of simply making the lts remote available.
resolve_branch_ref() {
    local repo_dir="$1" branch="$2" lts_mode="$3"

    local -a candidates=()
    [ "$lts_mode" = true ] && candidates+=("lts/tqtc/lts-$branch")
    candidates+=("origin/$branch" "lts/$branch")

    local ref
    for ref in "${candidates[@]}"; do
        if git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/$ref"; then
            printf '%s' "$ref"
            return 0
        fi
    done
    return 1
}

# Fetch every remote the branch might live on, then resolve it. In lts mode the
# lts remote is created on demand so tqtc/lts-* branches become visible. Only
# the resolved ref goes to stdout; git's fetch chatter already goes to stderr.
fetch_and_resolve_branch_ref() {
    local repo_dir="$1" module_name="$2" branch="$3" lts_mode="$4" gerrit_user="$5"

    git -C "$repo_dir" fetch origin
    if [ "$lts_mode" = true ]; then
        ensure_lts_remote "$repo_dir" "$module_name" "$gerrit_user" || true
        if [ -n "$(git -C "$repo_dir" config --get remote.lts.url || true)" ]; then
            git -C "$repo_dir" fetch lts
        fi
    fi

    resolve_branch_ref "$repo_dir" "$branch" "$lts_mode"
}

# True when a worktree tracks a tqtc/* branch, i.e. was created with --lts.
# Derived from the checked-out branch rather than stored, because git config is
# shared between all worktrees of a repo and a stored flag would leak across
# them. Falls back to the directory name for a detached supermodule.
worktree_upstream_branch() {
    local worktree_dir="$1" fallback="$2"
    git -C "$worktree_dir" symbolic-ref --short HEAD 2>/dev/null || printf '%s' "$fallback"
}

is_lts_branch() {
    case "$1" in
        tqtc/*) return 0 ;;
        *)      return 1 ;;
    esac
}

# Initialize a submodule, falling back to the lts (tqtc-) mirror when the
# recorded gitlink cannot be found on origin. LTS commits made after a version's
# final open-source release exist only in the tqtc- repos, so the supermodule's
# tqtc/lts-<version> branch points at commits code.qt.io has never seen.
init_submodule() {
    local worktree_dir="$1" module="$2" gerrit_user="$3" lts_mode="$4"

    if (cd "$worktree_dir" && git submodule update --init "$module"); then
        return 0
    fi

    if [ "$lts_mode" != true ]; then
        echo "Error: could not initialize '$module'." >&2
        echo "  If '$module' is on an LTS branch, re-run create with --lts to use the tqtc- mirrors." >&2
        return 1
    fi

    # A checkout failure still leaves the clone behind; anything else is not a
    # missing-gitlink problem and retrying against lts will not help.
    if ! git -C "$worktree_dir/$module" rev-parse --git-dir >/dev/null 2>&1; then
        echo "Error: '$module' could not be cloned." >&2
        return 1
    fi

    echo "  gitlink for '$module' is not on origin — retrying via the lts remote..."
    if ! ensure_lts_remote "$worktree_dir/$module" "$module" "$gerrit_user"; then
        echo "Error: a Gerrit username is required to fetch from the lts remote." >&2
        return 1
    fi
    git -C "$worktree_dir/$module" fetch lts
    (cd "$worktree_dir" && git submodule update "$module")
}

# Configure the gerrit remote and review username in a module's local git config.
setup_gerrit_for_module() {
    local module_dir="$1" module_name="$2" gerrit_user="$3" branch="$4" setup_lts="${5:-false}"
    # Upstream name of the LTS branch, which is not the same as $branch: a '6.2'
    # worktree created with --lts actually sits on tqtc/lts-6.2.
    local lts_branch="${6:-$branch}"

    local gerrit_url
    if [ -n "$gerrit_user" ]; then
        gerrit_url="ssh://${gerrit_user}@codereview.qt-project.org:29418/qt/${module_name}"
    else
        gerrit_url="ssh://codereview.qt-project.org:29418/qt/${module_name}"
    fi

    git -C "$module_dir" config remote.gerrit.url "$gerrit_url"
    git -C "$module_dir" config remote.gerrit.fetch '+refs/heads/*:refs/remotes/gerrit/*'
    git -C "$module_dir" config remote.gerrit.push "HEAD:refs/for/${branch}"

    if [ -n "$gerrit_user" ]; then
        local existing
        existing=$(git -C "$module_dir" config review.codereview.qt-project.org.username 2>/dev/null || true)
        [ -z "$existing" ] && git -C "$module_dir" config \
            review.codereview.qt-project.org.username "$gerrit_user"

        if [ "$setup_lts" = true ]; then
            ensure_lts_remote "$module_dir" "$module_name" "$gerrit_user" "$lts_branch"
        fi
    fi
}

# Install Qt git hooks (commit-msg, post-commit, pre-commit) into a module's hooks dir.
install_git_hooks() {
    local module_dir="$1"
    local hooks_src="$QT6_DIR/qtrepotools/git-hooks"

    if [ ! -d "$hooks_src" ]; then
        echo "Warning: qtrepotools/git-hooks not found — skipping hook installation for $(basename "$module_dir")"
        return 0
    fi

    local git_dir
    git_dir=$(git -C "$module_dir" rev-parse --git-dir 2>/dev/null) || return 0
    [[ "$git_dir" = /* ]] || git_dir="$module_dir/$git_dir"

    mkdir -p "$git_dir/hooks"
    ln -sf "$hooks_src/gerrit_commit_msg_hook" "$git_dir/hooks/commit-msg"
    ln -sf "$hooks_src/git_post_commit_hook"   "$git_dir/hooks/post-commit"
    ln -sf "$hooks_src/clang-format-pre-commit" "$git_dir/hooks/pre-commit"
}

# Get initialized top-level submodules from a worktree in build order:
# DEFAULT_MODULES first (preserving their declared order), then any extras.
get_initialized_modules() {
    local worktree_dir="$1"
    local initialized
    initialized=$(git -C "$worktree_dir" submodule status 2>/dev/null \
        | grep -v '^-' \
        | awk '{print $2}') || true
    [ -z "$initialized" ] && return

    # Emit known modules in DEFAULT_MODULES order (correct dependency order)
    for module in "${DEFAULT_MODULES[@]}"; do
        echo "$initialized" | grep -qx "$module" && echo "$module"
    done
    # Append any initialized modules not covered by DEFAULT_MODULES
    while IFS= read -r module; do
        local known=false
        for d in "${DEFAULT_MODULES[@]}"; do [ "$module" = "$d" ] && known=true && break; done
        $known || echo "$module"
    done <<< "$initialized"
}

regen_clangd() {
    local out="$SCRIPT_DIR/.clangd"
    : > "$out"

    while IFS= read -r abs_path; do
        [ "$abs_path" = "$QT6_DIR" ] && continue
        [ ! -d "$abs_path" ] && continue

        local dir_name build_dir escaped
        dir_name="$(basename "$abs_path")"
        build_dir="$(branch_to_build_dir "$dir_name")"
        escaped="$(regex_escape "$dir_name")"

        while IFS= read -r module; do
            printf -- '---\nIf:\n  PathMatch: %s/%s/.*\nCompileFlags:\n  CompilationDatabase: %s/%s\n\n' \
                "$escaped" "$module" "$build_dir" "$module" >> "$out"
        done < <(get_initialized_modules "$abs_path")

        local apps_dir_path="$SCRIPT_DIR/$dir_name-apps"
        if [ -d "$apps_dir_path" ]; then
            local apps_dir_escaped
            apps_dir_escaped="$(regex_escape "${dir_name}-apps")"
            for _app_src in "$apps_dir_path"/*/; do
                [ -d "$_app_src" ] || continue
                local _app_name
                _app_name=$(basename "$_app_src")
                printf -- '---\nIf:\n  PathMatch: %s/%s/.*\nCompileFlags:\n  CompilationDatabase: %s/apps/%s\n\n' \
                    "$apps_dir_escaped" "$_app_name" "$build_dir" "$_app_name" >> "$out"
            done
        fi
    done < <(git -C "$QT6_DIR" worktree list --porcelain | awk '/^worktree /{print $2}')
}

check_build_deps() {
    local -a missing=()
    local os
    os="$(uname -s)"

    local tools=(git cmake ninja python3 pkg-config)
    for tool in "${tools[@]}"; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done

    # Check for a C++ compiler
    command -v c++ &>/dev/null || command -v g++ &>/dev/null || command -v clang++ &>/dev/null \
        || missing+=("c++ compiler (g++ or clang++)")

    if [ "$os" = "Darwin" ]; then
        # macOS: Cocoa/Metal frameworks are system-provided; just verify Xcode CLT
        xcode-select -p &>/dev/null || missing+=("Xcode Command Line Tools (run: xcode-select --install)")
    else
        # Linux: check for X11/XCB/GTK libraries via pkg-config
        if command -v pkg-config &>/dev/null; then
            local libs=(
                fontconfig freetype2 gtk+-3.0
                x11 x11-xcb xcb
                xcb-cursor xcb-glx xcb-icccm xcb-image xcb-keysyms
                xcb-randr xcb-renderutil xcb-shape xcb-shm xcb-sync
                xcb-util xcb-xfixes xcb-xkb
                xext xfixes xi xrender
                xkbcommon xkbcommon-x11
            )
            for lib in "${libs[@]}"; do
                pkg-config --exists "$lib" 2>/dev/null || missing+=("$lib (pkg-config)")
            done
        fi
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Warning: the following build dependencies appear to be missing:"
        for item in "${missing[@]}"; do
            echo "  - $item"
        done
        echo "Go to https://wiki.qt.io/Building_Qt_6_from_Git for more help."
        echo ""
    fi
}

configure_module() {
    local module="$1" worktree_dir="$2" build_base="$3"
    shift 3
    # Request every reply Qt Creator asks for, so it can load the build without
    # re-running CMake (see FileApiParser::cmakeQueryFilePaths in Qt Creator).
    mkdir -p "$build_base/$module/.cmake/api/v1/query"
    touch "$build_base/$module/.cmake/api/v1/query/codemodel-v2" \
          "$build_base/$module/.cmake/api/v1/query/cache-v2" \
          "$build_base/$module/.cmake/api/v1/query/cmakeFiles-v1" \
          "$build_base/$module/.cmake/api/v1/query/toolchains-v1" \
          "$build_base/$module/.cmake/api/v1/query/configureLog-v1"
    if [ "$module" = "qtbase" ]; then
        (cd "$build_base/$module" && "$worktree_dir/$module/configure" -developer-build "$@")
    else
        (cd "$build_base/$module" && "$build_base/qtbase/bin/qt-configure-module" "$worktree_dir/$module")
    fi
}

build_module() {
    local module="$1" build_base="$2" jobs="$3"
    (cd "$build_base/$module" && ninja -j "$jobs")
}

make_workspace_file() {
    local dir_name="$1" dest="$2" build_base="$3"
    shift 3
    local modules=("$@")

    local mi_mode="gdb"
    [ "$(uname -s)" = "Darwin" ] && mi_mode="lldb"

    # Collect label|/abs/path pairs for tst_* executables under tests/auto/
    local -a tasks=()
    for module in "${modules[@]}"; do
        local tests_dir="$build_base/$module/tests/auto"
        [ -d "$tests_dir" ] || continue
        while IFS= read -r exe; do
            tasks+=("$module: $(basename "$exe")|$exe")
        done < <(find "$tests_dir" -type f -name 'tst_*' -perm /111 | sort)
    done

    # Collect executables under examples/ directories
    for module in "${modules[@]}"; do
        local examples_dir="$build_base/$module/examples"
        [ -d "$examples_dir" ] || continue
        while IFS= read -r exe; do
            local rel="${exe#$examples_dir/}"
            tasks+=("$module examples: $rel|$exe")
        done < <(find "$examples_dir" -type f -perm /111 ! -name '*.so' ! -name '*.so.*' ! -name '*.dylib' ! -name '*.dylib.*' ! -path '*/CMakeFiles/*' ! -path '*/*.framework/*' | sort)
    done

    # Collect registered app entries from the <branch>-apps/ directory
    local apps_dir="$SCRIPT_DIR/$dir_name-apps"
    local -a app_entries=()
    if [ -d "$apps_dir" ]; then
        for _app_src in "$apps_dir"/*/; do
            [ -d "$_app_src" ] || continue
            local _app_name _app_type
            _app_name=$(basename "$_app_src")
            # KDE projects are registered as symlinks to kde-builder source dirs
            if [ -L "${_app_src%/}" ]; then
                _app_type="kde"
            elif [ ! -f "$_app_src/CMakeLists.txt" ]; then
                _app_type="qmake"
            else
                _app_type="cmake"
            fi
            app_entries+=("$_app_name|$_app_type")
        done
    fi

    {
        printf '{\n    "folders": [\n'
        local sep=""
        for module in "${modules[@]}"; do
            printf '%s        { "name": "%s", "path": "%s/%s" }' \
                "$sep" "$module" "$dir_name" "$module"
            sep=$',\n'
        done
        for entry in "${app_entries[@]}"; do
            local app_folder_name="${entry%%|*}"
            local app_folder_type="${entry##*|}"
            local app_folder_label
            [ "$app_folder_type" = "kde" ] && app_folder_label="KDE: $app_folder_name" \
                                           || app_folder_label="app: $app_folder_name"
            printf '%s        { "name": "%s", "path": "%s" }' \
                "$sep" "$app_folder_label" "$dir_name-apps/$app_folder_name"
            sep=$',\n'
        done
        printf '\n    ],\n'

        printf '    "settings": {\n'
        printf '        "clangd.arguments": [\n'
        printf '            "--background-index",\n'
        printf '            "--clang-tidy",\n'
        printf '            "--completion-style=detailed",\n'
        printf '            "--header-insertion=iwyu",\n'
        printf '            "--log=error"\n'
        printf '        ],\n'
        printf '        "files.associations": {\n'
        printf '            "*.qml": "qml",\n'
        printf '            "*.pri": "cmake",\n'
        printf '            "*.pro": "cmake",\n'
        printf '            "*.prf": "cmake"\n'
        printf '        },\n'
        printf '        "files.exclude": {\n'
        printf '            "**/.git": true,\n'
        printf '            "**/.moc": true,\n'
        printf '            "**/.rcc": true\n'
        printf '        },\n'
        printf '        "editor.tabSize": 4,\n'
        printf '        "editor.insertSpaces": true,\n'
        printf '        "editor.rulers": [100],\n'
        printf '        "C_Cpp.intelliSenseEngine": "disabled",\n'
        printf '        "cmake.configureOnOpen": false\n'
        printf '    },\n'

        printf '    "tasks": {\n'
        printf '        "version": "2.0.0",\n'
        printf '        "tasks": [\n'
        local task_sep=""
        for task_entry in "${tasks[@]}"; do
            local label="${task_entry%%|*}"
            local exe="${task_entry##*|}"
            printf '%s            {\n' "$task_sep"
            printf '                "label": "%s",\n' "$label"
            printf '                "type": "shell",\n'
            printf '                "command": "%s",\n' "$exe"
            printf '                "group": "test",\n'
            printf '                "presentation": { "reveal": "always", "panel": "dedicated" }\n'
            printf '            }'
            task_sep=$',\n'
        done
        local qt_cmake_bin="$build_base/qtbase/bin/qt-cmake"
        local qmake_bin="$build_base/qtbase/bin/qmake"
        for entry in "${app_entries[@]}"; do
            local app_task_name app_task_type
            IFS='|' read -r app_task_name app_task_type <<< "$entry"
            local app_build_dir="$build_base/apps/$app_task_name"
            local app_src="$SCRIPT_DIR/$dir_name-apps/$app_task_name"
            local app_exe app_label app_build_cmd app_run_cmd
            if [ "$app_task_type" = "kde" ]; then
                app_label="KDE: $app_task_name"
                local real_build
                real_build=$(realpath "$app_build_dir" 2>/dev/null || echo "$app_build_dir")
                app_exe="$real_build/bin/$app_task_name"
                [ ! -f "$app_exe" ] && [ -f "$real_build/$app_task_name" ] && app_exe="$real_build/$app_task_name"
                app_build_cmd="kde-builder $app_task_name"
                app_run_cmd="$app_exe"
            elif [ "$app_task_type" = "qmake" ]; then
                app_label="app: $app_task_name"
                if [ "$(uname -s)" = "Darwin" ]; then
                    app_exe="$app_build_dir/$app_task_name.app/Contents/MacOS/$app_task_name"
                else
                    app_exe="$app_build_dir/$app_task_name"
                fi
                app_build_cmd="mkdir -p $app_build_dir && cd $app_build_dir && $qmake_bin $app_src/$app_task_name.pro && make -j\$(nproc 2>/dev/null || sysctl -n hw.logicalcpu)"
                app_run_cmd="cd $app_build_dir && $app_exe"
            else
                app_label="app: $app_task_name"
                if [ "$(uname -s)" = "Darwin" ]; then
                    app_exe="$app_build_dir/$app_task_name.app/Contents/MacOS/$app_task_name"
                else
                    app_exe="$app_build_dir/$app_task_name"
                fi
                app_exe=$(find_app_exe "$app_build_dir" "$app_task_name") || app_exe="$app_build_dir/$app_task_name"
                app_build_cmd="mkdir -p $app_build_dir && cd $app_build_dir && $qt_cmake_bin -GNinja -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DCMAKE_CXX_FLAGS=-fdebug-prefix-map=$app_src=/qt-app/$app_task_name $app_src && ninja"
                app_run_cmd="cd $app_build_dir && $app_exe"
            fi
            # Build-only task, shared by the run task (dependsOn) and the
            # debug launch configuration (preLaunchTask).
            printf '%s            {\n' "$task_sep"
            printf '                "label": "build %s",\n' "$app_label"
            printf '                "type": "shell",\n'
            printf '                "command": "%s",\n' "$app_build_cmd"
            printf '                "group": "build",\n'
            printf '                "hide": true,\n'
            printf '                "problemMatcher": ["$gcc"],\n'
            printf '                "presentation": { "reveal": "always", "panel": "shared" }\n'
            printf '            }'
            task_sep=$',\n'
            printf '%s            {\n' "$task_sep"
            printf '                "label": "%s",\n' "$app_label"
            printf '                "type": "shell",\n'
            printf '                "command": "%s",\n' "$app_run_cmd"
            printf '                "dependsOn": "build %s",\n' "$app_label"
            printf '                "group": "build",\n'
            printf '                "problemMatcher": [],\n'
            printf '                "presentation": { "reveal": "always", "panel": "dedicated" }\n'
            printf '            }'
        done
        printf '\n        ]\n    },\n'

        printf '    "launch": {\n'
        printf '        "version": "0.2.0",\n'
        printf '        "configurations": [\n'
        local launch_sep=""
        for task_entry in "${tasks[@]}"; do
            local label="${task_entry%%|*}"
            local exe="${task_entry##*|}"
            printf '%s            {\n' "$launch_sep"
            printf '                "name": "%s",\n' "$label"
            printf '                "type": "cppdbg",\n'
            printf '                "request": "launch",\n'
            printf '                "program": "%s",\n' "$exe"
            printf '                "args": [],\n'
            printf '                "cwd": "%s",\n' "$(dirname "$exe")"
            printf '                "MIMode": "%s",\n' "$mi_mode"
            printf '                "setupCommands": [\n'
            printf '                    { "text": "-enable-pretty-printing", "ignoreFailures": true }\n'
            printf '                ]\n'
            printf '            }'
            launch_sep=$',\n'
        done
        for entry in "${app_entries[@]}"; do
            local app_launch_name app_launch_type
            IFS='|' read -r app_launch_name app_launch_type <<< "$entry"
            local app_launch_build_dir="$build_base/apps/$app_launch_name"
            local app_launch_src="$SCRIPT_DIR/$dir_name-apps/$app_launch_name"
            local app_launch_exe app_launch_label app_launch_cwd app_launch_sfmap
            if [ "$app_launch_type" = "kde" ]; then
                app_launch_label="KDE: $app_launch_name"
                local real_build
                real_build=$(realpath "$app_launch_build_dir" 2>/dev/null || echo "$app_launch_build_dir")
                app_launch_exe="$real_build/bin/$app_launch_name"
                [ ! -f "$app_launch_exe" ] && [ -f "$real_build/$app_launch_name" ] && app_launch_exe="$real_build/$app_launch_name"
                app_launch_cwd="$real_build"
                local real_src
                real_src=$(realpath "$app_launch_src" 2>/dev/null || echo "$app_launch_src")
                app_launch_sfmap="\"$real_src\": \"$app_launch_src\""
            else
                app_launch_label="app: $app_launch_name"
                if [ "$(uname -s)" = "Darwin" ]; then
                    app_launch_exe="$app_launch_build_dir/$app_launch_name.app/Contents/MacOS/$app_launch_name"
                else
                    app_launch_exe="$app_launch_build_dir/$app_launch_name"
                fi
                app_launch_exe=$(find_app_exe "$app_launch_build_dir" "$app_launch_name") || app_launch_exe="$app_launch_build_dir/$app_launch_name"
                app_launch_cwd="$app_launch_build_dir"
                app_launch_sfmap="\"/qt-app/$app_launch_name\": \"$app_launch_src\""
            fi
            printf '%s            {\n' "$launch_sep"
            printf '                "name": "%s",\n' "$app_launch_label"
            printf '                "type": "cppdbg",\n'
            printf '                "request": "launch",\n'
            printf '                "program": "%s",\n' "$app_launch_exe"
            printf '                "args": [],\n'
            printf '                "cwd": "%s",\n' "$app_launch_cwd"
            printf '                "MIMode": "%s",\n' "$mi_mode"
            printf '                "sourceFileMap": { %s },\n' "$app_launch_sfmap"
            printf '                "preLaunchTask": "build %s",\n' "$app_launch_label"
            printf '                "setupCommands": [\n'
            printf '                    { "text": "-enable-pretty-printing", "ignoreFailures": true }\n'
            printf '                ]\n'
            printf '            }'
            launch_sep=$',\n'
        done
        printf '\n        ]\n    }\n}\n'
    } > "$dest"
}

make_qtcreator_session() {
    local branch="$1" worktree_dir="$2"
    shift 2
    local modules=("$@")

    [ -d "$QTCREATOR_DIR" ] || return 0

    local session_file="$QTCREATOR_DIR/$branch.qws"
    local build_base="$SCRIPT_DIR/$(branch_to_build_dir "$branch")"
    local -a projects=()
    local startup_project=""

    for module in "${modules[@]}"; do
        local cmake_file="$worktree_dir/$module/CMakeLists.txt"
        [ -f "$cmake_file" ] || continue
        [ -n "$startup_project" ] || startup_project="$cmake_file"
        # Open the project through its existing CMakeCache.txt so Qt Creator offers only
        # that build directory for import. Opening the source CMakeLists.txt invites
        # Qt Creator to configure a second build dir (<src>/build/...), which overwrites
        # the generated header aliases that all modules share in qtbase's build dir.
        local cache_file="$build_base/$module/CMakeCache.txt"
        if [ -f "$cache_file" ]; then
            projects+=("$cache_file")
        else
            projects+=("$cmake_file")
        fi
    done

    local apps_dir="$SCRIPT_DIR/$branch-apps"
    if [ -d "$apps_dir" ]; then
        for _app_src in "$apps_dir"/*/; do
            [ -d "$_app_src" ] || continue
            local _app_name
            _app_name=$(basename "$_app_src")
            local _app_proj
            if [ -f "$_app_src/CMakeLists.txt" ]; then
                _app_proj="$_app_src/CMakeLists.txt"
            else
                _app_proj="$_app_src/$_app_name.pro"
            fi
            [ -f "$_app_proj" ] && projects+=("$_app_proj")
        done
    fi

    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<!DOCTYPE QtCreatorSession>\n'
        printf '<qtcreator>\n'
        printf ' <data>\n  <variable>CascadeSetActive</variable>\n  <value type="bool">false</value>\n </data>\n'
        printf ' <data>\n  <variable>ProjectDependencies</variable>\n  <valuemap type="QVariantMap"/>\n </data>\n'
        printf ' <data>\n  <variable>ProjectList</variable>\n  <valuelist type="QVariantList">\n'
        for proj in "${projects[@]}"; do
            printf '   <value type="QString">%s</value>\n' "$proj"
        done
        printf '  </valuelist>\n </data>\n'
        # Qt Creator matches StartupProject against the source CMakeLists.txt,
        # even for projects opened through CMakeCache.txt.
        [ -n "$startup_project" ] || startup_project="${projects[0]:-}"
        if [ -n "$startup_project" ]; then
            printf ' <data>\n  <variable>StartupProject</variable>\n  <value type="QString">%s</value>\n </data>\n' \
                "$startup_project"
        fi
        printf ' <data>\n  <variable>valueKeys</variable>\n  <valuelist type="QVariantList"/>\n </data>\n'
        printf '</qtcreator>\n'
    } > "$session_file"

    echo "Qt Creator session: $session_file"
}

qtcreator_register() {
    local branch="$1" qmake_path="$2"
    [ -f "$QTCREATOR_XML" ] || return 0
    PLEASE_BRANCH="$branch" PLEASE_QMAKE="$qmake_path" PLEASE_XML="$QTCREATOR_XML" \
    python3 << 'PYEOF'
import xml.etree.ElementTree as ET, os, sys

xml_file   = os.environ['PLEASE_XML']
qmake_path = os.environ['PLEASE_QMAKE']
branch     = os.environ['PLEASE_BRANCH']
source_key = f'please.sh.{branch}'

try:
    tree = ET.parse(xml_file)
    root = tree.getroot()
except Exception as e:
    print(f'Warning: could not parse {xml_file}: {e}', file=sys.stderr)
    sys.exit(0)

qt_blocks = [d for d in root.findall('data')
             if d.find('variable') is not None
             and d.find('variable').text.startswith('QtVersion.')]

# Update if already registered
for block in qt_blocks:
    vm = block.find('valuemap')
    if vm is None:
        continue
    for val in vm.findall('value'):
        if val.get('key') == 'autodetectionSource' and val.text == source_key:
            for v2 in vm.findall('value'):
                if v2.get('key') == 'QMakePath':
                    v2.text = qmake_path
            print(f"Qt Creator: updated qmake path for '{branch}'")
            break
    else:
        continue
    break
else:
    # Not found — insert a new entry before the Version block
    max_id = max(
        (int(v.text) for d in qt_blocks
         for vm in [d.find('valuemap')] if vm is not None
         for v in vm.findall('value')
         if v.get('key') == 'Id' and v.text and v.text.isdigit()),
        default=0)

    new_data = ET.Element('data')
    ET.SubElement(new_data, 'variable').text = 'QtVersion.PLACEHOLDER'
    vm = ET.SubElement(new_data, 'valuemap')
    vm.set('type', 'QVariantMap')

    def add_val(parent, t, key, text):
        v = ET.SubElement(parent, 'value')
        v.set('type', t); v.set('key', key); v.text = text

    new_id = max_id + 1
    add_val(vm, 'int',     'Id',                    str(new_id))
    add_val(vm, 'QString', 'Name',                  f'Qt %{{Qt:Version}} (dev - {branch})')
    add_val(vm, 'QString', 'QMakePath',             qmake_path)
    add_val(vm, 'QString', 'QtVersion.Type',        'Qt4ProjectManager.QtVersion.Desktop')
    add_val(vm, 'QString', 'autodetectionSource',   source_key)
    add_val(vm, 'bool',    'isAutodetected',        'false')

    version_block = next(
        (d for d in root.findall('data')
         if d.find('variable') is not None and d.find('variable').text == 'Version'),
        None)
    if version_block is not None:
        root.insert(list(root).index(version_block), new_data)
    else:
        root.append(new_data)

    # Renumber all QtVersion.N keys sequentially
    for i, block in enumerate(d for d in root.findall('data')
                               if d.find('variable') is not None
                               and d.find('variable').text.startswith('QtVersion.')):
        block.find('variable').text = f'QtVersion.{i}'

    print(f"Qt Creator: registered '{branch}' (Id={new_id}, qmake={qmake_path})")

try:
    ET.indent(root, space=' ')
except AttributeError:
    pass

with open(xml_file, 'w', encoding='utf-8') as f:
    f.write('<?xml version="1.0" encoding="UTF-8"?>\n')
    f.write('<!DOCTYPE QtCreatorQtVersions>\n')
    f.write(ET.tostring(root, encoding='unicode'))
    f.write('\n')
PYEOF
}

qtcreator_unregister() {
    local branch="$1"
    [ -f "$QTCREATOR_XML" ] || return 0
    PLEASE_BRANCH="$branch" PLEASE_XML="$QTCREATOR_XML" \
    python3 << 'PYEOF'
import xml.etree.ElementTree as ET, os, sys

xml_file   = os.environ['PLEASE_XML']
branch     = os.environ['PLEASE_BRANCH']
source_key = f'please.sh.{branch}'

try:
    tree = ET.parse(xml_file)
    root = tree.getroot()
except Exception as e:
    print(f'Warning: could not parse {xml_file}: {e}', file=sys.stderr)
    sys.exit(0)

removed = False
for block in list(root.findall('data')):
    var = block.find('variable')
    if var is None or not var.text.startswith('QtVersion.'):
        continue
    vm = block.find('valuemap')
    if vm is None:
        continue
    for val in vm.findall('value'):
        if val.get('key') == 'autodetectionSource' and val.text == source_key:
            root.remove(block)
            removed = True
            break

if not removed:
    print(f"Qt Creator: no entry found for '{branch}', skipping")
    sys.exit(0)

# Renumber remaining QtVersion.N keys
for i, block in enumerate(d for d in root.findall('data')
                           if d.find('variable') is not None
                           and d.find('variable').text.startswith('QtVersion.')):
    block.find('variable').text = f'QtVersion.{i}'

try:
    ET.indent(root, space=' ')
except AttributeError:
    pass

with open(xml_file, 'w', encoding='utf-8') as f:
    f.write('<?xml version="1.0" encoding="UTF-8"?>\n')
    f.write('<!DOCTYPE QtCreatorQtVersions>\n')
    f.write(ET.tostring(root, encoding='unicode'))
    f.write('\n')

print(f"Qt Creator: removed entry for '{branch}'")
PYEOF
}

# The kit id is fixed, so the generated .user files can refer to it.
qtcreator_kit_id() { echo "please.sh.$1"; }

# Registers a kit for the branch's Qt build in profiles.xml, cloned from the
# default Desktop kit. Returns non-zero if no kit could be registered.
qtcreator_register_kit() {
    local branch="$1"
    [ -f "$QTCREATOR_DIR/profiles.xml" ] && [ -f "$QTCREATOR_XML" ] || return 1
    PLEASE_BRANCH="$branch" PLEASE_KIT_ID="$(qtcreator_kit_id "$branch")" \
    PLEASE_PROFILES="$QTCREATOR_DIR/profiles.xml" PLEASE_XML="$QTCREATOR_XML" \
    python3 << 'PYEOF'
import xml.etree.ElementTree as ET, copy, os, sys

profiles_file = os.environ['PLEASE_PROFILES']
branch        = os.environ['PLEASE_BRANCH']
kit_id        = os.environ['PLEASE_KIT_ID']
source_key    = f'please.sh.{branch}'

def values(vm):
    return {v.get('key'): v for v in vm.findall('value')}

def numbered_blocks(root, prefix):
    return [d for d in root.findall('data')
            if d.find('variable') is not None
            and d.find('variable').text.startswith(prefix)
            and d.find('variable').text[len(prefix):].isdigit()]

try:
    qt_root = ET.parse(os.environ['PLEASE_XML']).getroot()
    root = ET.parse(profiles_file).getroot()
except Exception as e:
    print(f'Warning: could not parse Qt Creator settings: {e}', file=sys.stderr)
    sys.exit(1)

qt_id = None
for block in numbered_blocks(qt_root, 'QtVersion.'):
    vals = values(block.find('valuemap'))
    if 'autodetectionSource' in vals and vals['autodetectionSource'].text == source_key:
        qt_id = vals['Id'].text
if qt_id is None:
    print(f"Warning: no Qt version registered for '{branch}', not creating a kit", file=sys.stderr)
    sys.exit(1)

def kit_id_of(block):
    v = values(block.find('valuemap')).get('PE.Profile.Id')
    return v.text if v is not None else None

def is_desktop(block):
    data = block.find('valuemap').find("valuemap[@key='PE.Profile.Data']")
    if data is None:
        return False
    v = values(data).get('PE.Profile.DeviceType')
    return v is not None and v.text == 'Desktop'

def set_qt(block):
    data = block.find('valuemap').find("valuemap[@key='PE.Profile.Data']")
    v = values(data).get('QtSupport.QtInformation')
    if v is None:
        v = ET.SubElement(data, 'value', {'type': 'int', 'key': 'QtSupport.QtInformation'})
    v.text = qt_id

kits = numbered_blocks(root, 'Profile.')
existing = next((k for k in kits if kit_id_of(k) == kit_id), None)
if existing is not None:
    set_qt(existing)
    print(f"Qt Creator: updated kit '{kit_id}'")
else:
    default_block = next((d for d in root.findall('data')
                          if d.find('variable').text == 'Profile.Default'), None)
    default_id = default_block.find('value').text if default_block is not None else None
    desktop_kits = [k for k in kits if is_desktop(k)]
    template = next((k for k in desktop_kits if kit_id_of(k) == default_id),
                    desktop_kits[0] if desktop_kits else None)
    if template is None:
        print('Warning: no Desktop kit in Qt Creator to base a kit on', file=sys.stderr)
        sys.exit(1)

    new_kit = copy.deepcopy(template)
    vals = values(new_kit.find('valuemap'))
    vals['PE.Profile.Id'].text = kit_id
    vals['PE.Profile.Name'].text = f'please.sh ({branch})'
    vals['PE.Profile.AutoDetected'].text = 'false'
    if 'PE.Profile.AutoDetectionSource' in vals:
        vals['PE.Profile.AutoDetectionSource'].text = source_key
    if 'PE.Profile.SDK' in vals:
        vals['PE.Profile.SDK'].text = 'false'
    set_qt(new_kit)
    root.insert(list(root).index(kits[-1]) + 1, new_kit)
    print(f"Qt Creator: registered kit '{kit_id}'")

kits = numbered_blocks(root, 'Profile.')
for i, block in enumerate(kits):
    block.find('variable').text = f'Profile.{i}'
for d in root.findall('data'):
    if d.find('variable').text == 'Profile.Count':
        d.find('value').text = str(len(kits))

try:
    ET.indent(root, space=' ')
except AttributeError:
    pass

with open(profiles_file, 'w', encoding='utf-8') as f:
    f.write('<?xml version="1.0" encoding="UTF-8"?>\n')
    f.write('<!DOCTYPE QtCreatorProfiles>\n')
    f.write(ET.tostring(root, encoding='unicode'))
    f.write('\n')
PYEOF
}

qtcreator_unregister_kit() {
    local branch="$1"
    [ -f "$QTCREATOR_DIR/profiles.xml" ] || return 0
    PLEASE_KIT_ID="$(qtcreator_kit_id "$branch")" PLEASE_PROFILES="$QTCREATOR_DIR/profiles.xml" \
    python3 << 'PYEOF'
import xml.etree.ElementTree as ET, os, sys

profiles_file = os.environ['PLEASE_PROFILES']
kit_id        = os.environ['PLEASE_KIT_ID']

try:
    root = ET.parse(profiles_file).getroot()
except Exception as e:
    print(f'Warning: could not parse {profiles_file}: {e}', file=sys.stderr)
    sys.exit(0)

def is_kit(d):
    var = d.find('variable').text
    return var.startswith('Profile.') and var[len('Profile.'):].isdigit()

def kit_id_of(d):
    v = d.find("valuemap/value[@key='PE.Profile.Id']")
    return v.text if v is not None else None

kits = [d for d in root.findall('data') if is_kit(d)]
doomed = [d for d in kits if kit_id_of(d) == kit_id]
if not doomed:
    sys.exit(0)
for d in doomed:
    root.remove(d)

kits = [d for d in root.findall('data') if is_kit(d)]
for i, block in enumerate(kits):
    block.find('variable').text = f'Profile.{i}'
for d in root.findall('data'):
    var = d.find('variable').text
    if var == 'Profile.Count':
        d.find('value').text = str(len(kits))
    elif var == 'Profile.Default' and d.find('value').text == kit_id:
        d.find('value').text = kit_id_of(kits[0]) if kits else ''

try:
    ET.indent(root, space=' ')
except AttributeError:
    pass

with open(profiles_file, 'w', encoding='utf-8') as f:
    f.write('<?xml version="1.0" encoding="UTF-8"?>\n')
    f.write('<!DOCTYPE QtCreatorProfiles>\n')
    f.write(ET.tostring(root, encoding='unicode'))
    f.write('\n')

print(f"Qt Creator: removed kit '{kit_id}'")
PYEOF
}

# Writes .qtcreator/CMakeLists.txt.user for each module that has none yet, with a
# single build configuration pointing at the module's existing build directory.
# Qt Creator then opens the project already configured: it reads the CMake
# file-api reply that is already there (so clangd works right away) and never
# configures a build directory of its own.
make_qtcreator_user_files() {
    local branch="$1" worktree_dir="$2" build_base="$3"
    shift 3
    local modules=("$@")
    local kit_id
    kit_id=$(qtcreator_kit_id "$branch")

    for module in "${modules[@]}"; do
        local source_dir="$worktree_dir/$module"
        local build_dir="$build_base/$module"
        local user_file="$source_dir/.qtcreator/CMakeLists.txt.user"
        [ -f "$source_dir/CMakeLists.txt" ] && [ -f "$build_dir/CMakeCache.txt" ] || continue
        [ -f "$user_file" ] && continue

        local build_type
        build_type=$(sed -n 's/^CMAKE_BUILD_TYPE:[A-Z]*=//p' "$build_dir/CMakeCache.txt")
        mkdir -p "$source_dir/.qtcreator"
        cat > "$user_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE QtCreatorProject>
<qtcreator>
 <data>
  <variable>ProjectExplorer.Project.ActiveTarget</variable>
  <value type="qlonglong">0</value>
 </data>
 <data>
  <variable>ProjectExplorer.Project.Target.0</variable>
  <valuemap type="QVariantMap">
   <value type="QString" key="DeviceType">Desktop</value>
   <value type="bool" key="HasPerBcDcs">true</value>
   <value type="QString" key="ProjectExplorer.ProjectConfiguration.DisplayName">please.sh (${branch})</value>
   <value type="QString" key="ProjectExplorer.ProjectConfiguration.Id">${kit_id}</value>
   <value type="qlonglong" key="ProjectExplorer.Target.ActiveBuildConfiguration">0</value>
   <valuemap type="QVariantMap" key="ProjectExplorer.Target.BuildConfiguration.0">
    <value type="QString" key="CMake.Build.Type">${build_type:-Debug}</value>
    <value type="QString" key="CMake.Source.Directory">${source_dir}</value>
    <value type="QString" key="ProjectExplorer.BuildConfiguration.BuildDirectory">${build_dir}</value>
    <valuemap type="QVariantMap" key="ProjectExplorer.BuildConfiguration.BuildStepList.0">
     <valuemap type="QVariantMap" key="ProjectExplorer.BuildStepList.Step.0">
      <valuelist type="QVariantList" key="CMakeProjectManager.MakeStep.BuildTargets">
       <value type="QString">all</value>
      </valuelist>
      <value type="bool" key="ProjectExplorer.BuildStep.Enabled">true</value>
      <value type="QString" key="ProjectExplorer.ProjectConfiguration.Id">CMakeProjectManager.MakeStep</value>
     </valuemap>
     <value type="qlonglong" key="ProjectExplorer.BuildStepList.StepsCount">1</value>
     <value type="QString" key="ProjectExplorer.ProjectConfiguration.Id">ProjectExplorer.BuildSteps.Build</value>
    </valuemap>
    <valuemap type="QVariantMap" key="ProjectExplorer.BuildConfiguration.BuildStepList.1">
     <valuemap type="QVariantMap" key="ProjectExplorer.BuildStepList.Step.0">
      <valuelist type="QVariantList" key="CMakeProjectManager.MakeStep.BuildTargets">
       <value type="QString">clean</value>
      </valuelist>
      <value type="bool" key="ProjectExplorer.BuildStep.Enabled">true</value>
      <value type="QString" key="ProjectExplorer.ProjectConfiguration.Id">CMakeProjectManager.MakeStep</value>
     </valuemap>
     <value type="qlonglong" key="ProjectExplorer.BuildStepList.StepsCount">1</value>
     <value type="QString" key="ProjectExplorer.ProjectConfiguration.Id">ProjectExplorer.BuildSteps.Clean</value>
    </valuemap>
    <value type="int" key="ProjectExplorer.BuildConfiguration.BuildStepListCount">2</value>
    <value type="QString" key="ProjectExplorer.ProjectConfiguration.DisplayName">please.sh (${branch})</value>
    <value type="QString" key="ProjectExplorer.ProjectConfiguration.Id">CMakeProjectManager.CMakeBuildConfiguration</value>
    <value type="qlonglong" key="ProjectExplorer.Target.ActiveDeployConfiguration">0</value>
    <valuemap type="QVariantMap" key="ProjectExplorer.Target.DeployConfiguration.0">
     <valuemap type="QVariantMap" key="ProjectExplorer.BuildConfiguration.BuildStepList.0">
      <value type="qlonglong" key="ProjectExplorer.BuildStepList.StepsCount">0</value>
      <value type="QString" key="ProjectExplorer.ProjectConfiguration.Id">ProjectExplorer.BuildSteps.Deploy</value>
     </valuemap>
     <value type="int" key="ProjectExplorer.BuildConfiguration.BuildStepListCount">1</value>
     <value type="QString" key="ProjectExplorer.ProjectConfiguration.Id">ProjectExplorer.DefaultDeployConfiguration</value>
    </valuemap>
    <value type="qlonglong" key="ProjectExplorer.Target.DeployConfigurationCount">1</value>
   </valuemap>
   <value type="qlonglong" key="ProjectExplorer.Target.BuildConfigurationCount">1</value>
  </valuemap>
 </data>
 <data>
  <variable>ProjectExplorer.Project.TargetCount</variable>
  <value type="qlonglong">1</value>
 </data>
 <data>
  <variable>Version</variable>
  <value type="int">22</value>
 </data>
</qtcreator>
EOF
        echo "Qt Creator: generated $user_file"
    done
}

make_cmake_user_presets() {
    local branch="$1" worktree_dir="$2" build_base="$3"
    shift 3
    local modules=("$@")

    for module in "${modules[@]}"; do
        local source_dir="$worktree_dir/$module"
        local build_dir="$build_base/$module"
        local preset_file="$source_dir/CMakeUserPresets.json"
        [ -d "$source_dir" ] || continue
        # Don't remove .qtcreator/CMakeLists.txt.user here: losing it leaves the project
        # unconfigured, and re-enabling a kit makes Qt Creator configure a second build
        # dir inside the source tree, which breaks the shared build (QTCREATORBUG-34462).
        cat > "$preset_file" << EOF
{
  "version": 3,
  "cmakeMinimumRequired": { "major": 3, "minor": 19, "patch": 0 },
  "configurePresets": [
    {
      "name": "please-${branch}",
      "displayName": "please.sh (${branch})",
      "binaryDir": "${build_dir}",
      "generator": "Ninja"
    }
  ]
}
EOF
        echo "Qt Creator: generated CMakeUserPresets.json for $module"
    done
}

# A branch uses Qt Creator once 'build --creator' has created its session.
qtcreator_enabled() { [ -f "$QTCREATOR_DIR/$1.qws" ]; }

# Generates everything Qt Creator needs to open the branch's modules already
# configured against their existing build directories: the session, the Qt
# version and kit, per-module .user files, and CMakeUserPresets.json.
setup_qtcreator() {
    local branch="$1" worktree_dir="$2" build_base="$3"
    shift 3
    local modules=("$@")

    if [ ! -d "$QTCREATOR_DIR" ]; then
        echo "Warning: Qt Creator settings not found in '$QTCREATOR_DIR'; start Qt Creator once, then re-run with --creator" >&2
        return 0
    fi

    echo "Creating Qt Creator session..."
    make_qtcreator_session "$branch" "$worktree_dir" "${modules[@]}"

    local qmake_bin="$build_base/qtbase/bin/qmake"
    if [ -f "$qmake_bin" ]; then
        echo "Registering Qt build in Qt Creator..."
        qtcreator_register "$branch" "$qmake_bin"
        if qtcreator_register_kit "$branch"; then
            make_qtcreator_user_files "$branch" "$worktree_dir" "$build_base" "${modules[@]}"
        fi
    fi

    echo "Generating CMakeUserPresets.json..."
    make_cmake_user_presets "$branch" "$worktree_dir" "$build_base" "${modules[@]}"
}

cmd_create() {
    local setup_lts=false
    local -a pos_args=()
    for arg in "$@"; do
        if [ "$arg" = "--lts" ]; then
            setup_lts=true
        else
            pos_args+=("$arg")
        fi
    done

    local branch="${pos_args[0]:-$DEFAULT_BRANCH}"
    local worktree_dir="$SCRIPT_DIR/$branch"
    local -a initial_modules

    if [ -n "${pos_args[1]:-}" ]; then
        mapfile -t initial_modules < <(parse_modules "${pos_args[1]}")
    else
        initial_modules=("${DEFAULT_MODULES[@]}")
    fi

    # Ensure the qt6 supermodule exists
    if [ ! -d "$QT6_DIR" ]; then
        read -r -p "qt6 not found. Clone from code.qt.io? [y/N] " answer
        [ "$answer" = "y" ] || { echo "Aborting."; exit 1; }
        git clone git://code.qt.io/qt/qt5.git "$QT6_DIR"
    fi

    # Resolve the Gerrit username once up front (may emit a warning if not found)
    local gerrit_user
    gerrit_user=$(get_gerrit_username)
    if [ -z "$gerrit_user" ]; then
        read -r -p "Continue without a Gerrit username? [y/N] " answer
        [ "$answer" = "y" ] || { echo "Aborting."; exit 1; }
    fi

    # Always initialize qtrepotools so git hooks are available
    echo "Initializing qtrepotools..."
    (cd "$QT6_DIR" && git submodule update --init qtrepotools)

    # Create worktree only if it doesn't already exist
    if [ ! -d "$worktree_dir" ]; then
        # Resolve the branch to an explicit remote-tracking ref first, so the
        # worktree starts from a known remote instead of relying on git's DWIM
        # (which gives up as soon as both origin and lts carry the branch).
        local branch_ref
        if ! branch_ref=$(resolve_branch_ref "$QT6_DIR" "$branch" "$setup_lts"); then
            echo "Branch '$branch' not found locally, fetching qt6..."
            branch_ref=$(fetch_and_resolve_branch_ref \
                "$QT6_DIR" "qt5" "$branch" "$setup_lts" "$gerrit_user") || {
                echo "Error: branch '$branch' not found on any remote of qt6." >&2
                [ "$setup_lts" = true ] \
                    || echo "  For a commercial LTS version, try: $0 create --lts $branch" >&2
                exit 1
            }
        fi

        # Point out the LTS branch when the public one is the frozen leftover of
        # a version that kept getting patch releases behind the tqtc- wall.
        if [ "$setup_lts" != true ] \
            && git -C "$QT6_DIR" show-ref --verify --quiet "refs/remotes/lts/tqtc/lts-$branch"; then
            echo "Note: '$branch' also has an LTS branch (tqtc/lts-$branch) with later patch"
            echo "      releases. Use '$0 create --lts $branch' to track that instead."
        fi

        # The local branch keeps the remote's own name (e.g. 'tqtc/lts-6.2'),
        # while the worktree directory stays '$branch' so that build, update,
        # destroy and the app-* commands can go on addressing it as '$branch'.
        local local_branch="${branch_ref#*/}"
        echo "Creating worktree for '$branch' from '$branch_ref'..."

        # git won't create a worktree for a branch already checked out elsewhere,
        # including the main worktree. Detach qt6's HEAD to free the branch.
        local qt6_branch
        qt6_branch=$(git -C "$QT6_DIR" symbolic-ref --short HEAD 2>/dev/null || true)
        if [ "$qt6_branch" = "$local_branch" ]; then
            echo "Detaching qt6 HEAD from '$local_branch' to allow worktree creation..."
            git -C "$QT6_DIR" checkout --detach
        fi
        if git -C "$QT6_DIR" show-ref --verify --quiet "refs/heads/$local_branch"; then
            git -C "$QT6_DIR" worktree add "$worktree_dir" "$local_branch"
        else
            git -C "$QT6_DIR" worktree add -b "$local_branch" "$worktree_dir" "$branch_ref"
        fi
    else
        echo "Worktree '$worktree_dir' already exists, resuming..."
    fi

    # The branch the worktree actually sits on. For an LTS worktree this is the
    # upstream name ('tqtc/lts-6.2') rather than the directory name ('6.2'), and
    # it is what Gerrit expects as a review target.
    local upstream_branch
    upstream_branch=$(worktree_upstream_branch "$worktree_dir" "$branch")

    # Refuse to flip an existing worktree between the public and the LTS branch.
    # The supermodule would stay on one while the submodules were checked out
    # from the other, so switching means destroying and recreating.
    local want_branch
    want_branch=$(resolve_branch_ref "$QT6_DIR" "$branch" "$setup_lts" || true)
    want_branch="${want_branch#*/}"
    if [ -n "$want_branch" ] && [ "$upstream_branch" != "$want_branch" ]; then
        echo "Error: worktree '$worktree_dir' is on '$upstream_branch', but this asks for '$want_branch'." >&2
        echo "  To switch between the public and the LTS branch, recreate it:" >&2
        echo "    $0 destroy $branch && $0 create${setup_lts:+ --lts} $branch" >&2
        exit 1
    fi

    # Set up gerrit remote (and lts if requested) for the supermodule
    if [ -n "$gerrit_user" ]; then
        echo "Configuring gerrit remote for supermodule..."
        setup_gerrit_for_module "$worktree_dir" "qt5" "$gerrit_user" "$branch" \
            "$setup_lts" "$upstream_branch"
    fi

    # Use a queue so required deps discovered mid-loop can be appended
    local -a queue=("${initial_modules[@]}")
    local -A planned=()

    # Pre-populate planned with already-initialized modules so they are silently
    # skipped and don't trigger false dependency warnings on re-runs
    while IFS= read -r m; do planned[$m]=1; done < <(get_initialized_modules "$worktree_dir")
    for m in "${initial_modules[@]}"; do planned[$m]=1; done

    while [ ${#queue[@]} -gt 0 ]; do
        local module="${queue[0]}"
        queue=("${queue[@]:1}")

        # Check if already initialized in the worktree
        local status_line
        status_line=$(git -C "$worktree_dir" submodule status "$module" 2>/dev/null | head -1)
        if [ -n "$status_line" ] && [[ "$status_line" != -* ]]; then
            echo "Skipping $module (already initialized)"
            setup_gerrit_for_module "$worktree_dir/$module" "$module" "$gerrit_user" "$branch" \
                "$setup_lts" "$upstream_branch"
            install_git_hooks "$worktree_dir/$module"
            continue
        fi

        echo "Initializing $module..."
        init_submodule "$worktree_dir" "$module" "$gerrit_user" "$setup_lts"

        local module_ref
        module_ref=$(fetch_and_resolve_branch_ref \
            "$worktree_dir/$module" "$module" "$branch" "$setup_lts" "$gerrit_user") || {
            echo "Error: branch '$branch' not found on any remote of '$module'." >&2
            exit 1
        }
        echo "Checking out $module_ref in $module..."
        git -C "$worktree_dir/$module" checkout "$module_ref"

        echo "Initializing $module submodules..."
        (cd "$worktree_dir/$module" && git submodule update --init --recursive)

        echo "Configuring gerrit remote for $module..."
        setup_gerrit_for_module "$worktree_dir/$module" "$module" "$gerrit_user" "$branch" \
            "$setup_lts" "$upstream_branch"
        install_git_hooks "$worktree_dir/$module"

        # Check required deps from dependencies.yaml (skip qtbase — it has none)
        if [ "$module" != "qtbase" ]; then
            while IFS= read -r dep; do
                if [[ ! -v "planned[$dep]" ]]; then
                    echo "Warning: '$dep' is a required dependency of '$module' but was not in the module list — adding implicitly"
                    queue+=("$dep")
                    planned[$dep]=1
                fi
            done < <(parse_required_deps "$worktree_dir/$module/dependencies.yaml")
        fi
    done

    echo "Updating .clangd..."
    regen_clangd

    setup_completion

    echo "Done: $worktree_dir"
}

setup_completion() {
    local completion_file="$SCRIPT_DIR/.please-completion.bash"

    # Write preamble with the zsh bashcompinit bootstrap and the embedded script
    # dir (avoids BASH_SOURCE[0] which doesn't work in zsh).
    {
        cat << 'PREAMBLE'
# please.sh tab completion — works in bash 4.2+ and zsh (via bashcompinit)
if [ -n "${ZSH_VERSION:-}" ]; then
    autoload -U +X bashcompinit 2>/dev/null && bashcompinit 2>/dev/null
fi
PREAMBLE
        printf '_please_script_dir=%q\n\n' "$SCRIPT_DIR"
        cat << 'COMPLETION_EOF'
_please_completion() {
    local cur cmd
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"

    local commands="help create build destroy update app-add app-remove app-list app-run kde-hijack kde-startkwin kde-startplasma wayland-list"

    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
        return
    fi

    cmd="${COMP_WORDS[1]}"

    if [ "$COMP_CWORD" -eq 2 ]; then
        case "$cmd" in
            create|build|destroy|update|app-add|app-remove|app-list|app-run|kde-hijack)
                local branches
                branches=$(git -C "$_please_script_dir/qt6" worktree list --porcelain 2>/dev/null \
                    | awk '/^worktree /{print $2}' \
                    | while IFS= read -r p; do
                        [ "$p" != "$_please_script_dir/qt6" ] && basename "$p"
                      done)
                COMPREPLY=( $(compgen -W "$branches" -- "$cur") )
                ;;
        esac
        return
    fi

    if [ "$COMP_CWORD" -eq 3 ]; then
        local branch="${COMP_WORDS[2]}"
        case "$cmd" in
            app-add)
                COMPREPLY=( $(compgen -d -- "$cur") )
                compopt -o nospace 2>/dev/null
                ;;
            app-run|app-remove)
                local apps
                apps=$(ls "$_please_script_dir/$branch-apps" 2>/dev/null | tr '\n' ' ')
                [ "$cmd" = "app-remove" ] && apps="--all $apps"
                COMPREPLY=( $(compgen -W "$apps" -- "$cur") )
                ;;
        esac
    fi
}
complete -F _please_completion please.sh
COMPLETION_EOF
    } > "$completion_file"

    local source_line="[ -f \"$completion_file\" ] && source \"$completion_file\""

    # On macOS the primary shell is zsh; on Linux it's bash.
    # Always write to the platform-default rc file; also write to the other if it exists.
    local primary secondary
    if [ "$(uname -s)" = "Darwin" ]; then
        primary="$HOME/.zshrc"
        secondary="$HOME/.bashrc"
    else
        primary="$HOME/.bashrc"
        secondary="$HOME/.zshrc"
    fi

    for rc_file in "$primary" "$secondary"; do
        [ "$rc_file" = "$secondary" ] && [ ! -f "$rc_file" ] && continue
        if ! grep -qF "$completion_file" "$rc_file" 2>/dev/null; then
            printf '\n# please.sh tab completion\n%s\n' "$source_line" >> "$rc_file"
            echo "Completion: added to $rc_file — run: source $rc_file"
        fi
    done
}

cmd_build() {
    local branch="$1"
    shift

    local reserve=""
    local reconfigure=false
    local creator=false
    local -a extra_configure_args=()
    while [ $# -gt 0 ]; do
        if [ "$1" = "--" ]; then shift; extra_configure_args=("$@"); break; fi
        if [ "$1" = "--reconfigure" ]; then reconfigure=true; shift; continue; fi
        if [ "$1" = "--creator" ]; then creator=true; shift; continue; fi
        reserve="$1"; shift
    done

    local worktree_dir="$SCRIPT_DIR/$branch"
    local build_base="$SCRIPT_DIR/$(branch_to_build_dir "$branch")"
    local workspace_file="$SCRIPT_DIR/$(branch_to_workspace_file "$branch")"

    if [ ! -d "$worktree_dir" ]; then
        echo "Error: worktree '$worktree_dir' not found — run: $0 create $branch"
        exit 1
    fi

    check_build_deps

    local nproc_val jobs
    nproc_val=$(get_nproc)
    if [ -n "$reserve" ]; then
        if ! [[ "$reserve" =~ ^[0-9]+$ ]]; then
            echo "Error: reserve argument must be a non-negative integer"
            exit 1
        fi
        jobs=$(( nproc_val - reserve ))
        [ "$jobs" -le 0 ] && jobs=1
    else
        jobs=$nproc_val
    fi

    local -a modules
    mapfile -t modules < <(get_initialized_modules "$worktree_dir")

    if [ ${#modules[@]} -eq 0 ]; then
        echo "Error: no initialized submodules found in '$worktree_dir'"
        exit 1
    fi

    echo "Detected modules: ${modules[*]}"
    echo "Building with -j $jobs (nproc=$nproc_val)"

    for module in "${modules[@]}"; do
        if [ "$reconfigure" = true ]; then
            rm -f "$build_base/$module/CMakeCache.txt"
        fi
        echo "Configuring $module..."
        configure_module "$module" "$worktree_dir" "$build_base" "${extra_configure_args[@]}"
        echo "Building $module..."
        build_module "$module" "$build_base" "$jobs"
    done

    echo "Creating workspace file..."
    make_workspace_file "$branch" "$workspace_file" "$build_base" "${modules[@]}"

    echo "Updating .clangd..."
    regen_clangd

    if [ "$creator" = true ]; then
        setup_qtcreator "$branch" "$worktree_dir" "$build_base" "${modules[@]}"
    fi

    echo "Done: $build_base"
    echo "Workspace: $workspace_file"
}

cmd_destroy() {
    local branch="$1"
    local worktree_dir="$SCRIPT_DIR/$branch"
    local build_base="$SCRIPT_DIR/$(branch_to_build_dir "$branch")"
    local workspace_file="$SCRIPT_DIR/$(branch_to_workspace_file "$branch")"

    if [ ! -d "$worktree_dir" ] && [ ! -d "$build_base" ] && [ ! -f "$workspace_file" ]; then
        echo "Error: nothing found for branch '$branch'"
        exit 1
    fi

    if [ -d "$worktree_dir" ]; then
        echo "Removing worktree..."
        git -C "$QT6_DIR" worktree remove --force "$worktree_dir"
    fi

    if [ -d "$build_base" ]; then
        echo "Removing build directory..."
        rm -rf "$build_base"
    fi

    if [ -f "$workspace_file" ]; then
        echo "Removing workspace file..."
        rm -f "$workspace_file"
    fi

    local apps_dir="$SCRIPT_DIR/$branch-apps"
    if [ -d "$apps_dir" ]; then
        echo "Removing app source copies..."
        rm -rf "$apps_dir"
    fi

    echo "Updating .clangd..."
    regen_clangd

    echo "Unregistering Qt build from Qt Creator..."
    qtcreator_unregister_kit "$branch"
    qtcreator_unregister "$branch"

    local session_file="$QTCREATOR_DIR/$branch.qws"
    if [ -f "$session_file" ]; then
        echo "Removing Qt Creator session..."
        rm -f "$session_file"
    fi

    echo "Done."
}

cmd_update() {
    local do_sync=false
    local setup_lts=""
    local -a pos_args=()
    for arg in "$@"; do
        if [ "$arg" = "--sync" ]; then
            do_sync=true
        elif [ "$arg" = "--lts" ]; then
            setup_lts=true
        else
            pos_args+=("$arg")
        fi
    done

    local branch="${pos_args[0]:-$DEFAULT_BRANCH}"
    local worktree_dir="$SCRIPT_DIR/$branch"

    if [ ! -d "$worktree_dir" ]; then
        echo "Error: worktree '$worktree_dir' not found — run: $0 create $branch"
        exit 1
    fi

    # Unless --lts was given, take the choice from the branch the worktree is
    # already on, so LTS worktrees keep tracking their tqtc/lts-* branch.
    local upstream_branch
    upstream_branch=$(worktree_upstream_branch "$worktree_dir" "$branch")
    if [ -z "$setup_lts" ]; then
        if is_lts_branch "$upstream_branch"; then setup_lts=true; else setup_lts=false; fi
    fi

    local gerrit_user=""
    if [ "$setup_lts" = true ]; then
        gerrit_user=$(get_gerrit_username)
    fi

    local -a modules
    mapfile -t modules < <(get_initialized_modules "$worktree_dir")

    if [ ${#modules[@]} -eq 0 ]; then
        echo "Error: no initialized submodules found in '$worktree_dir'"
        exit 1
    fi

    # Bail early if any module has uncommitted changes
    for module in "${modules[@]}"; do
        if [ -n "$(git -C "$worktree_dir/$module" status --porcelain --untracked-files=no)" ]; then
            echo "Warning: '$module' has uncommitted changes — aborting update"
            exit 1
        fi
    done

    for module in "${modules[@]}"; do
        echo "Updating $module..."
        local module_ref
        module_ref=$(fetch_and_resolve_branch_ref \
            "$worktree_dir/$module" "$module" "$branch" "$setup_lts" "$gerrit_user") || {
            echo "Error: branch '$branch' not found on any remote of '$module'." >&2
            exit 1
        }
        git -C "$worktree_dir/$module" rebase "$module_ref"
    done

    if [ "$do_sync" = true ]; then
        local cmake_script="$worktree_dir/cmake/QtSynchronizeRepo.cmake"
        if [ ! -f "$cmake_script" ]; then
            echo "Error: QtSynchronizeRepo.cmake not found at '$cmake_script'"
            exit 1
        fi
        # Sync against the real upstream name ('tqtc/lts-6.2' for an LTS
        # worktree), not the directory name.
        echo "Synchronizing submodules for '$upstream_branch'..."
        (cd "$worktree_dir" && cmake -DSYNC_TO_MODULE="." -DSYNC_TO_BRANCH="$upstream_branch" -P cmake/QtSynchronizeRepo.cmake)
    fi

    echo "Done."
}

cmd_app_add() {
    local branch="$1"
    require_branch "$branch"
    local app_path
    app_path="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "${2:?app path required}")"
    local build_base="$SCRIPT_DIR/$(branch_to_build_dir "$branch")"
    local workspace_file="$SCRIPT_DIR/$(branch_to_workspace_file "$branch")"

    # Detect project type
    local project_type="" exe_name=""
    if [ -f "$app_path/CMakeLists.txt" ]; then
        project_type="cmake"
        exe_name=$(parse_cmake_exe_name "$app_path/CMakeLists.txt")
    else
        local dir_name pro_file=""
        dir_name=$(basename "$app_path")
        if [ -f "$app_path/$dir_name.pro" ]; then
            pro_file="$app_path/$dir_name.pro"
        else
            pro_file=$(find "$app_path" -maxdepth 1 -name '*.pro' | head -1)
        fi
        if [ -z "$pro_file" ]; then
            echo "Error: no CMakeLists.txt or .pro file found in '$app_path'"
            exit 1
        fi
        project_type="qmake"
        exe_name=$(basename "$pro_file" .pro)
    fi
    echo "Detected project type: $project_type, executable name: $exe_name"

    if [ ! -f "$build_base/qtbase/bin/qt-cmake" ] && [ ! -f "$build_base/qtbase/bin/qmake" ]; then
        echo "Error: Qt not built for branch '$branch' — run: $0 build $branch"
        exit 1
    fi

    # Copy source into the managed tree so the main .clangd covers it
    mkdir -p "$SCRIPT_DIR/$branch-apps"
    local app_src_dir="$SCRIPT_DIR/$branch-apps/$exe_name"
    echo "Copying source to $app_src_dir..."
    rm -rf "$app_src_dir"
    cp -r "$app_path" "$app_src_dir"

    local app_build_dir="$build_base/apps/$exe_name"
    mkdir -p "$app_build_dir/.cmake/api/v1/query"
    touch "$app_build_dir/.cmake/api/v1/query/codemodel-v2" \
          "$app_build_dir/.cmake/api/v1/query/cache-v2" \
          "$app_build_dir/.cmake/api/v1/query/cmakeFiles-v1"

    if [ "$project_type" = "cmake" ]; then
        echo "Configuring $exe_name with qt-cmake..."
        (cd "$app_build_dir" && "$build_base/qtbase/bin/qt-cmake" -GNinja -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
            "-DCMAKE_CXX_FLAGS=-fdebug-prefix-map=$app_src_dir=/qt-app/$exe_name" \
            "$app_src_dir")
        echo "Building $exe_name..."
        (cd "$app_build_dir" && ninja)
    else
        echo "Configuring $exe_name with qmake..."
        (cd "$app_build_dir" && "$build_base/qtbase/bin/qmake" "$app_src_dir/$exe_name.pro")
        echo "Building $exe_name..."
        (cd "$app_build_dir" && make -j"$(get_nproc)")
    fi

    echo "Updating .clangd..."
    regen_clangd

    local -a modules
    mapfile -t modules < <(get_initialized_modules "$SCRIPT_DIR/$branch")
    if [ -f "$workspace_file" ]; then
        echo "Updating workspace file..."
        make_workspace_file "$branch" "$workspace_file" "$build_base" "${modules[@]}"
    fi

    if qtcreator_enabled "$branch"; then
        echo "Updating Qt Creator session..."
        make_qtcreator_session "$branch" "$SCRIPT_DIR/$branch" "${modules[@]}"
        echo "Generating CMakeUserPresets.json..."
        make_cmake_user_presets "$branch" "$SCRIPT_DIR/$branch" "$build_base" "${modules[@]}"
    fi

    echo "Done: $app_build_dir/$exe_name"
}

cmd_app_remove() {
    local branch="$1" name="$2"
    require_branch "$branch"
    local build_base="$SCRIPT_DIR/$(branch_to_build_dir "$branch")"
    local workspace_file="$SCRIPT_DIR/$(branch_to_workspace_file "$branch")"
    local apps_dir="$SCRIPT_DIR/$branch-apps"

    local -a names=()
    if [ "$name" = "--all" ]; then
        for _app_src in "$apps_dir"/*/; do
            [ -d "$_app_src" ] && names+=("$(basename "$_app_src")")
        done
        # Also catch broken symlinks that the directory glob skips
        for _app_link in "$apps_dir"/*; do
            [ -L "$_app_link" ] && [ ! -e "$_app_link" ] && names+=("$(basename "$_app_link")")
        done
        if [ ${#names[@]} -eq 0 ]; then
            echo "No apps registered for branch '$branch'."
            return 0
        fi
    else
        if [ ! -d "$apps_dir/$name" ] && [ ! -L "$apps_dir/$name" ]; then
            echo "Error: no registered app named '$name' for branch '$branch'"
            exit 1
        fi
        names=("$name")
    fi

    for n in "${names[@]}"; do
        echo "Removing '$n'..."
        local src_entry="$apps_dir/$n"
        if [ -L "$src_entry" ]; then
            rm "$src_entry"              # KDE project symlink — remove link only, not ~/kde source
        elif [ -d "$src_entry" ]; then
            rm -rf "$src_entry"
        fi
        local bld_entry="$build_base/apps/$n"
        if [ -L "$bld_entry" ]; then
            rm "$bld_entry"              # KDE build symlink — remove link only, not ~/kde build
        elif [ -d "$bld_entry" ]; then
            rm -rf "$bld_entry"
        fi
    done

    echo "Updating .clangd..."
    regen_clangd

    if [ -f "$workspace_file" ]; then
        echo "Updating workspace file..."
        # Surgical removal: strip only the entries for removed names, preserving
        # KDE: entries and other customizations (avoids full rebuild via make_workspace_file).
        printf '%s\n' "${names[@]}" | PLEASE_WS="$workspace_file" python3 << 'PYEOF'
import json, os, sys

ws_file  = os.environ['PLEASE_WS']
names    = [l.strip() for l in sys.stdin if l.strip()]
name_set = set(names)

with open(ws_file, encoding='utf-8') as f:
    ws = json.load(f)

ws['folders'] = [
    f for f in ws.get('folders', [])
    if f.get('path', '').rstrip('/').rsplit('/', 1)[-1] not in name_set
]

def label_matches(item):
    v = item.get('label') or item.get('name', '')
    return any(v in (f'app: {n}', f'KDE: {n}', f'build app: {n}', f'build KDE: {n}', n) for n in name_set)

if 'tasks' in ws and 'tasks' in ws['tasks']:
    ws['tasks']['tasks'] = [t for t in ws['tasks']['tasks'] if not label_matches(t)]

if 'launch' in ws and 'configurations' in ws['launch']:
    ws['launch']['configurations'] = [c for c in ws['launch']['configurations'] if not label_matches(c)]

with open(ws_file, 'w', encoding='utf-8') as f:
    json.dump(ws, f, indent=4)
PYEOF
        local -a modules
        mapfile -t modules < <(get_initialized_modules "$SCRIPT_DIR/$branch")
        qtcreator_enabled "$branch" && make_qtcreator_session "$branch" "$SCRIPT_DIR/$branch" "${modules[@]}"
    fi

    echo "Done."
}

cmd_app_list() {
    local branch="$1"
    require_branch "$branch"
    local apps_dir="$SCRIPT_DIR/$branch-apps"

    if [ ! -d "$apps_dir" ] || [ -z "$(ls -A "$apps_dir" 2>/dev/null)" ]; then
        echo "No apps registered for branch '$branch'."
        return 0
    fi

    printf '%-30s %s\n' NAME TYPE
    for _app_src in "$apps_dir"/*/; do
        [ -d "$_app_src" ] || continue
        local _app_name _app_type
        _app_name=$(basename "$_app_src")
        _app_type="cmake"
        [ ! -f "$_app_src/CMakeLists.txt" ] && _app_type="qmake"
        printf '%-30s %s\n' "$_app_name" "$_app_type"
    done
}

cmd_app_run() {
    local branch="$1" name="$2"
    require_branch "$branch"
    local build_base="$SCRIPT_DIR/$(branch_to_build_dir "$branch")"
    local app_src_dir="$SCRIPT_DIR/$branch-apps/$name"

    if [ ! -d "$app_src_dir" ]; then
        echo "Error: no registered app named '$name' for branch '$branch'"
        exit 1
    fi

    local app_build_dir="$build_base/apps/$name"

    # KDE project: source is a symlink to the kde-builder source dir.
    # Delegate the build to kde-builder; find and run the resulting binary.
    if [ -L "$app_src_dir" ]; then
        local real_build
        real_build=$(realpath "$app_build_dir")
        echo "Building KDE project $name with kde-builder..."
        kde-builder "$name"
        local app_exe=""
        for candidate in "$real_build/bin/$name" "$real_build/$name"; do
            [ -f "$candidate" ] && [ -x "$candidate" ] && { app_exe="$candidate"; break; }
        done
        if [ -z "$app_exe" ]; then
            echo "Error: executable not found in '$real_build'. Check kde-builder output above."
            exit 1
        fi
        echo "Running $name..."
        exec "$app_exe"
    fi

    local project_type="cmake"
    [ ! -f "$app_src_dir/CMakeLists.txt" ] && project_type="qmake"

    mkdir -p "$app_build_dir"

    if [ "$project_type" = "cmake" ]; then
        # Ensure the File API query exists so find_app_exe can resolve the real target name.
        mkdir -p "$app_build_dir/.cmake/api/v1/query"
        touch "$app_build_dir/.cmake/api/v1/query/codemodel-v2"
        echo "Configuring $name with qt-cmake..."
        (cd "$app_build_dir" && "$build_base/qtbase/bin/qt-cmake" -GNinja -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
            "-DCMAKE_CXX_FLAGS=-fdebug-prefix-map=$app_src_dir=/qt-app/$name" \
            "$app_src_dir")
        echo "Building $name..."
        (cd "$app_build_dir" && ninja)
    else
        echo "Configuring $name with qmake..."
        (cd "$app_build_dir" && "$build_base/qtbase/bin/qmake" "$app_src_dir/$name.pro")
        echo "Building $name..."
        (cd "$app_build_dir" && make -j"$(get_nproc)")
    fi

    local app_exe
    if ! app_exe=$(find_app_exe "$app_build_dir" "$name"); then
        echo "Error: could not find an executable for '$name' in '$app_build_dir'"
        exit 1
    fi

    echo "Running $name..."
    "$app_exe"
}

cmd_kde_hijack() {
    local worktree="${1:-$DEFAULT_BRANCH}"
    local kde_builder_data="$HOME/.local/share/kde-builder"
    local kde_builder_conf="$HOME/.config/kde-builder.yaml"
    local build_base="$SCRIPT_DIR/$(branch_to_build_dir "$worktree")"
    local qt_install_dir="$build_base/qtbase"
    local kde_builder_setup_url="https://develop.kde.org/docs/getting-started/building/kde-builder-setup/"
    local browser_src="$SCRIPT_DIR/kde-project-browser"
    local browser_link="$HOME/kde/kde-project-browser"

    if [ "$(uname -s)" = "Darwin" ]; then
        echo "Error: kde-hijack is only supported on Linux." >&2
        exit 1
    fi

    if [ ! -d "$kde_builder_data" ] || [ ! -f "$kde_builder_conf" ]; then
        echo "Error: kde-builder does not appear to be set up." >&2
        echo "  See: $kde_builder_setup_url" >&2
        exit 1
    fi

    if [ ! -d "$qt_install_dir" ]; then
        echo "Error: Qt build not found at '$qt_install_dir'" >&2
        echo "  Run first: $0 build $worktree" >&2
        exit 1
    fi

    cat << EOF
This will modify ~/.config/kde-builder.yaml:
  global.qt-install-dir  →  $qt_install_dir
  global.ignore-projects →  add qt6-set (if not already present)

It will also create a symlink:
  $browser_link  →  $browser_src

Note: PyYAML will reformat the file; comments will be lost.
EOF
    read -r -p "Proceed? [y/N] " answer
    [ "$answer" = "y" ] || { echo "Aborted."; exit 0; }

    PLEASE_QT_INSTALL="$qt_install_dir" PLEASE_KDE_CONF="$kde_builder_conf" \
    python3 << 'PYEOF'
import sys, os

conf_path   = os.environ['PLEASE_KDE_CONF']
qt_install  = os.environ['PLEASE_QT_INSTALL']

try:
    import yaml
except ImportError:
    print("Error: python-yaml not installed — run: pip install pyyaml", file=sys.stderr)
    sys.exit(1)

with open(conf_path, encoding='utf-8') as f:
    cfg = yaml.safe_load(f) or {}

g = cfg.setdefault('global', {})

# Use whichever key variant is already present; default to hyphen form
qt_key = 'qt_install_dir' if 'qt_install_dir' in g else 'qt-install-dir'
g[qt_key] = qt_install

# Handle both hyphen and underscore variants for ignore-projects
ign_key = 'ignore_projects' if 'ignore_projects' in g else 'ignore-projects'
ignore = g.get(ign_key) or []
if isinstance(ignore, str):
    ignore = ignore.split()
else:
    ignore = list(ignore)
if 'qt6-set' not in ignore:
    ignore.append('qt6-set')
g[ign_key] = ignore

with open(conf_path, 'w', encoding='utf-8') as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

print(f"  qt-install-dir:  {qt_install}")
print(f"  ignore-projects: {' '.join(str(x) for x in ignore)}")
PYEOF

    link_kde_project_browser "$browser_src" "$browser_link"

    echo "Done. kde-builder will now use the Qt build from the '$worktree' worktree."
}

# Symlink the repo's kde-project-browser into ~/kde so it can be run from there.
# Never clobbers a real file — an older standalone copy is left for the user to remove.
link_kde_project_browser() {
    local src="$1" link="$2"
    local link_dir
    link_dir="$(dirname "$link")"

    if [ ! -f "$src" ]; then
        echo "Warning: kde-project-browser not found at '$src' — skipping symlink." >&2
        return 0
    fi

    if [ ! -d "$link_dir" ]; then
        echo "Warning: '$link_dir' does not exist — skipping kde-project-browser symlink." >&2
        return 0
    fi

    if [ -L "$link" ]; then
        if [ "$(readlink -f "$link")" = "$(readlink -f "$src")" ]; then
            echo "  kde-project-browser: symlink already up to date"
            return 0
        fi
        ln -sfn "$src" "$link"
        echo "  kde-project-browser: symlink repointed → $src"
        return 0
    fi

    if [ -e "$link" ]; then
        echo "Warning: '$link' exists and is not a symlink — leaving it alone." >&2
        echo "  Remove it and re-run kde-hijack to link the version in $SCRIPT_DIR." >&2
        return 0
    fi

    ln -s "$src" "$link"
    echo "  kde-project-browser: symlinked → $src"
}

cmd_kde_startkwin() {
    if [ "$(uname -s)" = "Darwin" ]; then
        echo "Error: kde-startkwin is only supported on Linux." >&2
        exit 1
    fi

    local kwin_build="$HOME/kde/build/kwin"
    local kwin_bin="$kwin_build/bin"
    local kwin_exe="$kwin_bin/kwin_wayland"
    local kwin_prefix="$kwin_build/prefix.sh"

    local -a extra_args=()
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--" ]]; then
            shift
            extra_args=("$@")
            break
        fi
        shift
    done

    if [ ! -f "$kwin_exe" ] || [ ! -x "$kwin_exe" ]; then
        echo "Warning: kwin does not appear to be built." >&2
        echo "  Expected: $kwin_exe" >&2
        echo "  Run: kde-builder kwin" >&2
        exit 1
    fi

    set +u
    # shellcheck disable=SC1090
    source "$kwin_prefix"
    set -u
    cd "$kwin_bin"
    exec env QT_PLUGIN_PATH="$(pwd)":"${QT_PLUGIN_PATH:-}" dbus-run-session ./kwin_wayland "${extra_args[@]}"
}

cmd_kde_startplasma() {
    if [ "$(uname -s)" = "Darwin" ]; then
        echo "Error: kde-startplasma is only supported on Linux." >&2
        exit 1
    fi

    local plasma_build="$HOME/kde/build/plasma-workspace"
    local plasma_bin="$plasma_build/bin"
    local plasma_prefix="$plasma_build/prefix.sh"
    local plasma_exe="$plasma_bin/startplasma-wayland"

    if [ ! -f "$plasma_prefix" ] || [ ! -f "$plasma_exe" ] || [ ! -x "$plasma_exe" ]; then
        echo "Warning: plasma-workspace does not appear to be built." >&2
        echo "  Expected: $plasma_exe" >&2
        echo "  Run: kde-builder plasma-workspace" >&2
        exit 1
    fi

    set +u
    # shellcheck disable=SC1090
    source "$plasma_prefix"
    set -u
    cd "$plasma_bin"
    exec env QT_PLUGIN_PATH="$(pwd)":"$QT_PLUGIN_PATH" dbus-run-session ./startplasma-wayland
}

cmd_wayland_list() {
    if [ "$(uname -s)" = "Darwin" ]; then
        echo "Error: wayland-list is only supported on Linux." >&2
        exit 1
    fi
    local runtime_dir="/run/user/$(id -u)"
    if [ ! -d "$runtime_dir" ]; then
        echo "No runtime directory found at $runtime_dir"
        return 0
    fi
    local found=0
    for sock in "$runtime_dir"/wayland-*; do
        [[ "$sock" == *.lock ]] && continue
        [ -S "$sock" ] || continue
        echo "$(basename "$sock")"
        found=1
    done
    [ "$found" -eq 0 ] && echo "No active Wayland sessions found in $runtime_dir"
}

[ $# -lt 1 ] && usage

case "$1" in
    help)    cmd_help ;;
    create)  cmd_create  "${@:2}" ;;
    build)   cmd_build   "${2:-$DEFAULT_BRANCH}" "${@:3}" ;;
    destroy) cmd_destroy "${2:-$DEFAULT_BRANCH}" ;;
    update)  cmd_update  "${@:2}" ;;
    app-add)
        if [ -n "${3:-}" ]; then
            cmd_app_add    "$2"              "$3"
        else
            cmd_app_add    "$DEFAULT_BRANCH" "${2:-}"
        fi ;;
    app-remove)
        if [ -n "${3:-}" ]; then
            cmd_app_remove "$2"              "$3"
        else
            cmd_app_remove "$DEFAULT_BRANCH" "${2:-}"
        fi ;;
    app-list)   cmd_app_list "${2:-$DEFAULT_BRANCH}" ;;
    app-run)
        if [ -n "${3:-}" ]; then
            cmd_app_run    "$2"              "$3"
        else
            cmd_app_run    "$DEFAULT_BRANCH" "${2:-}"
        fi ;;
    kde-hijack) cmd_kde_hijack "${2:-$DEFAULT_BRANCH}" ;;
    kde-startkwin) cmd_kde_startkwin "${@:2}" ;;
    kde-startplasma) cmd_kde_startplasma ;;
    wayland-list) cmd_wayland_list ;;
    *)       usage ;;
esac
