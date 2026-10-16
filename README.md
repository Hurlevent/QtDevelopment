# QtDevelopment

Tools for setting up a Qt development environment and streamlining a solid development workflow

- **`please.sh`**: a workspace manager. Each Qt branch gets its own git worktree, build directory and VS Code workspace. clangd finds the right `compile_commands.json` without any changes to files inside the Qt source trees.
- **`kde-project-browser`**: a terminal UI for browsing KDE projects and building them with [kde-builder](https://kde-builder.kde.org/) against a Qt build made by `please.sh`.

## Quick start

```sh
git clone <this-repo> QtDevelopment
cd QtDevelopment

./please.sh create dev                 # clone qt5.git into ./qt6 (first run only) and add a 'dev' worktree
./please.sh build dev                  # configure and build each module in dependency order
code Qtdev.code-workspace              # open the generated VS Code workspace
```

If you leave out the branch, it defaults to `dev`. Run `./please.sh help` to see every command, the options, and the system packages each platform needs.

## please.sh

| Command | Description |
|---|---|
| `create [--lts] [branch] [modules]` | Add a worktree for `branch` and initialize submodules (default: `qtbase,qtshadertools,qtdeclarative`). Required dependencies are added automatically. `--lts` uses the commercial `tqtc/lts-<branch>` branches. |
| `build [branch] [reserve] [--reconfigure] [--creator] [-- cmake-args...]` | Configure and build with `-developer-build`. `reserve` leaves that many CPU cores idle. `--creator` also sets up a Qt Creator session, kit and Qt version. |
| `update [--sync] [--lts] [branch]` | Fetch and rebase all initialized submodules. `--sync` also runs `QtSynchronizeRepo.cmake`. |
| `destroy [branch]` | Remove the worktree, the build directory and the workspace file. |
| `app-add [branch] <path>` | Build an external CMake app against the branch's Qt and register it as a VS Code task and launch config. |
| `app-remove [branch] <name\|--all>` | Unregister an app (or all apps) and delete its build output. |
| `app-list [branch]` | List registered apps. |
| `app-run [branch] <name>` | Build and run a registered app. |

These commands only work on Linux:

| Command | Description |
|---|---|
| `wayland-list` | List active Wayland sessions. |
| `kde-hijack [branch]` | Point kde-builder's `qt-install-dir` at this branch's Qt build and symlink `kde-project-browser` into `~/kde`. |
| `kde-startkwin [-- args...]` | Start `kwin_wayland` from the kde-builder build. |
| `kde-startplasma` | Start a nested Plasma Wayland session from the kde-builder build. |

After a build, every `tst_*` auto test and every example executable is added to the generated `.code-workspace` as a task you can run and debug.

Qt Creator users can use the --creator option with the build command in order to generate a session for a specific branch, in addition to other files that are necessary in order to enable clangd support out of the box for all the submodules initialized in the worktree.

### Directory layout

```
QtDevelopment/
├── qt6/                       qt5.git supermodule (canonical clone)
├── <branch>/                  worktree           (create)
├── <branch>-build/            build tree         (build)
├── <branch>-apps/             copied app sources (app-add)
├── Qt<branch>.code-workspace  VS Code workspace
├── .clangd                    auto-managed, do not edit
└── please.sh
```

## kde-project-browser

```sh
./kde-project-browser [metadata-dir]
```

Reads KDE's repo-metadata from `~/.local/state/sysadmin-repo-metadata/projects-invent` by default. It uses only the Python 3 standard library. You can search and browse projects, then for any project you can:

- switch which Qt worktree kde-builder uses
- add missing Qt submodules and rebuild
- build the project with kde-builder
- add it to or remove it from the active Qt worktree's VS Code workspace
- run the built application, either directly or inside a nested Wayland session

Before using it, install and configure kde-builder (`~/.config/kde-builder.yaml`), then run `./please.sh kde-hijack <branch>`. 
Note: kde-hijack removes all comments from the yaml, you've been warned.

## Requirements

- bash 4.2 or newer. macOS ships bash 3.2, so install a newer one with `brew install bash`.
- git, cmake, ninja, python3, clangd, pkg-config and a C++ compiler
- The platform packages that Qt needs. `./please.sh help` lists them for Arch, Debian/Ubuntu, Fedora and macOS.

For more background, see [Building Qt 6 from Git](https://wiki.qt.io/Building_Qt_6_from_Git).

## Troubleshooting

If `./please.sh build` fails, it's usually for one of these reasons:

- **A module changed an API that a dependent module still uses**, and the fix hasn't been merged into the dependent module yet. Either:
  - wait a few days and run `./please.sh update <branch>`,
  - run `./please.sh update --sync <branch>`, which moves every submodule to the dependency versions the CI system has tested together, or
  - revert the offending patch locally.
- **CMake didn't pick up a newly added module or feature.** Run `./please.sh build <branch> --reconfigure`.

## License

[MIT](LICENSE)
