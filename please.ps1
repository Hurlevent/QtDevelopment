#Requires -Version 5.1
# please.ps1 — Qt6 workspace manager for Windows (the Windows counterpart of please.sh)
#
# Run it through please.bat (please <command> [args]) or directly from PowerShell
# (.\please.ps1 <command> [args]). See: please help

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
$Qt6Dir = Join-Path $ScriptDir 'qt6'
$DefaultBranch = 'dev'
$DefaultModules = @('qtbase', 'qtshadertools', 'qtdeclarative')
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$Self = if ($env:PLEASE_BAT -eq '1') { 'please' } else { '.\please.ps1' }

# ---------------------------------------------------------------------------
# General helpers
# ---------------------------------------------------------------------------

function Show-Usage {
    Write-Host @"
Usage: $Self <command> [args]

Commands:
  help                        Show full help and dependency information
  create  [--lts] [branch] [modules]  Add a git worktree for [branch], initialize submodules, and update .clangd
  build   [branch] [reserve] [--reconfigure] [-- configure-args...]  Configure and build; [reserve] idle CPU cores (default: 0)
  destroy [branch]            Remove the worktree, build dir, and .code-workspace for [branch]
  update  [--sync] [--lts] [branch]  Fetch and rebase all initialized submodules onto [branch]; with --sync also runs QtSynchronizeRepo.cmake
  app-add    [branch] <path>  Build an external app against the Qt build for [branch] and register it in the workspace
  app-remove [branch] <name|--all>  Remove a registered app (or all apps) from the build directory and workspace
  app-list   [branch]         List all apps registered for [branch]
  app-run    [branch] <name> [--build-only]  Build and run a registered app

[branch] defaults to '$DefaultBranch' when omitted

--lts selects the commercial LTS branch (tqtc/lts-[branch]) from the tqtc- mirrors
instead of the frozen public one, e.g. $Self create --lts 6.2

[modules] is a comma-separated list of submodules (default: qtbase,qtshadertools,qtdeclarative)
"@
}

function Show-Help {
    Write-Host @'
please.ps1 — Qt6 workspace manager for Windows

PURPOSE
  Manages parallel Qt6 development environments rooted in a single directory.
  Each branch gets its own git worktree (source), build directory, and VS Code
  workspace file, all wired up so that clangd finds the right compile_commands.json
  without touching any files inside the Qt source trees.

  This is the Windows counterpart of please.sh. Run it as "please <command>"
  through please.bat (from cmd or PowerShell), or as ".\please.ps1 <command>".
  please.bat passes arguments through untouched; when calling please.ps1 directly
  from PowerShell, quote CMake arguments that contain a colon ('-DFOO:BOOL=ON').

THE COMPILER
  MSVC only works inside the environment set up by Visual Studio's vcvarsall.bat.
  please.ps1 finds vcvarsall.bat and loads that environment itself, so it can be
  run from any shell. The Visual Studio installation is chosen like this:
    1. PLEASE_VS, if set. Either a version ("17", "2022", "18", "2026") or the
       path to a Visual Studio installation or to its vcvarsall.bat, e.g.
         set PLEASE_VS=2022                (cmd)
         $env:PLEASE_VS = '2022'           (PowerShell)
    2. The compiler an existing build of the branch was configured with (read
       from <branch>-build\qtbase\CMakeCache.txt), including the exact MSVC
       toolset version. This keeps a build tree on one compiler even after a
       newer Visual Studio is installed.
    3. The newest installation with the C++ tools, found with vswhere.exe (or,
       without vswhere, by looking under "Program Files\Microsoft Visual Studio").
  When run from a "Developer Command Prompt" whose compiler matches, that
  environment is used as is. To move a branch to another compiler, set PLEASE_VS
  and run: please build <branch> --reconfigure

WORKFLOW
  1. please create [--lts] <branch> [modules]
       Adds a git worktree for <branch> inside the current directory, then
       initializes the requested submodules and checks them out at origin/<branch>.
       Submodule dependencies marked required: true in dependencies.yaml are
       pulled in automatically with a warning if they were not explicitly listed.
       Re-running create on an existing worktree is safe — already-initialized
       modules are skipped so only new modules are set up.
       [modules] is a comma-separated list (default: qtbase,qtshadertools,qtdeclarative).
       If qt6\ does not exist yet, qt5.git is cloned from code.qt.io first.

       --lts adds the lts remote (the authenticated tqtc-<module> mirrors on
       Gerrit) to the supermodule and every submodule, and checks out the LTS
       branch tqtc/lts-<branch> where one exists.

  2. please build <branch> [reserve] [--reconfigure] [-- configure-args...]
       Loads the MSVC environment, then configures and builds each initialized
       module in dependency order (configure → ninja, one module at a time).
       Also regenerates the .code-workspace and .clangd files. The optional
       [reserve] argument keeps that many CPU cores idle: ninja is invoked with
       -j (cores - reserve), with a minimum of 1. -developer-build is always
       passed to configure; any arguments after -- are forwarded alongside it.
       configure itself treats -DNAME=VALUE as a C++ define, so CMake variables
       go after a second --, which configure passes on to CMake:
         please build dev 2 -- -nomake tests -- -DQT_BUILD_EXAMPLES=ON
       --reconfigure deletes each module's CMakeCache.txt before configuring,
       forcing CMake to re-detect the compiler and all features (e.g. after
       adding a new module). Existing compiled objects are preserved.
       After building, all tst_*.exe binaries under tests\auto\ and all .exe files
       under examples\ are registered as runnable and debuggable tasks in the
       generated .code-workspace file, with the Qt DLLs on PATH.

  3. please update [--sync] [--lts] <branch>
       Fetches each initialized submodule's remotes and rebases it onto <branch>.
       Aborts immediately if any module has uncommitted changes.
       Whether the public or the LTS branch is used follows the branch the
       worktree is already on, so --lts never needs repeating here.
       With --sync, also runs cmake/QtSynchronizeRepo.cmake after updating to
       synchronize all submodules to a consistent state (the same operation used
       by Qt's CI system).

  4. please destroy <branch>
       Removes the worktree (via git worktree remove --force), the build
       directory, the app sources and the .code-workspace file, then
       regenerates .clangd.

  5. please app-add <branch> <path>
       Builds an external application (a directory containing CMakeLists.txt or
       a .pro file) against the Qt build for <branch>. The executable name is
       inferred from the first qt_add_executable, add_executable, or project()
       call in CMakeLists.txt. The source is copied to <branch>-apps\<name>\ and
       the build output lands in <branch>-build\apps\<name>\. The app is added to
       the .code-workspace as a build+run task and a debuggable launch
       configuration. Re-running app-add reconfigures and rebuilds it.
       qmake projects are built with jom if it is on PATH, otherwise nmake.

  6. please app-remove <branch> <name|--all>
       Removes a previously registered app: deletes <branch>-apps\<name>\ and
       <branch>-build\apps\<name>\, and regenerates the .code-workspace.

  7. please app-list <branch>
       Lists all apps registered for <branch> with their project type.

  8. please app-run [branch] <name> [--build-only]
       Configures, builds, and runs a registered app with the Qt DLLs of
       <branch> on PATH. The binary is looked up in the build dir, its bin\,
       debug\ and release\; if <name> doesn't match it, the real target is
       resolved via the CMake File API. --build-only stops after building (the
       generated VS Code build tasks use this).

<branch> becomes dev if omitted.

DIRECTORY LAYOUT
  QtDevelopment\
  ├── qt6\                  qt5.git supermodule (the canonical clone)
  ├── <branch>\             Worktree created by: create
  ├── <branch>-build\       Build tree created by: build
  ├── <branch>-apps\        App source copies created by: app-add
  ├── Qt<branch>.code-workspace
  ├── .clangd               Auto-managed; do not edit by hand
  ├── please.bat
  └── please.ps1

DEPENDENCIES
  Nothing beyond Windows 11 itself is assumed. Required: git, CMake, Ninja and
  Visual Studio 2019 or later (or the Build Tools) with the "Desktop development
  with C++" workload. Each command checks for the tools it needs and lists what
  is missing, with how to get it. Tools are looked for on PATH and in their usual
  install locations (Program Files, winget's folders, and the CMake and Ninja
  that Visual Studio ships with its "C++ CMake tools for Windows" component),
  so a tool installed after the terminal was opened is still found.
  Recommended: clangd (LLVM), used by the generated .clangd and workspace files.

  With winget:
    winget install Git.Git Kitware.CMake Ninja-build.Ninja LLVM.LLVM
    winget install Microsoft.VisualStudio.2022.Community --override "--passive --wait --add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended"
  (or Microsoft.VisualStudio.2022.BuildTools with Microsoft.VisualStudio.Workload.VCTools)

  Qt source and build trees contain long paths. Enable long path support once,
  from an elevated prompt, and in git:
    reg add HKLM\SYSTEM\CurrentControlSet\Control\FileSystem /v LongPathsEnabled /t REG_DWORD /d 1 /f
    git config --global core.longpaths true

  Gerrit: put your username in %USERPROFILE%\.ssh\config:
    Host codereview.qt-project.org
        User <username>
  See https://wiki.qt.io/Setting_up_Gerrit#Local_Setup

VSCODE EXTENSIONS
  C/C++ Extension Pack:    ext install ms-vscode.cpptools-extension-pack
  clangd:                  ext install llvm-vs-code-extensions.vscode-clangd

More info: https://wiki.qt.io/Building_Qt_6_from_Git
'@
}

function Write-Warn([string]$Message) {
    Write-Host "Warning: $Message" -ForegroundColor Yellow
}

function Fail([string]$Message) {
    Write-Host "Error: $Message" -ForegroundColor Red
    exit 1
}

function Assert-LastExit([string]$What) {
    if ($LASTEXITCODE -ne 0) { Fail "$What failed (exit code $LASTEXITCODE)" }
}

# Runs a native command and returns its stdout lines, discarding stderr. The
# exit code is left in $LASTEXITCODE. (Redirecting a native command's stderr
# while $ErrorActionPreference is 'Stop' turns every stderr line into a
# terminating error in Windows PowerShell, hence the local override.)
function Invoke-Quiet {
    $exe = $args[0]
    $rest = @($args | Select-Object -Skip 1)
    $ErrorActionPreference = 'Continue'
    $out = & $exe @rest 2>$null
    return $out
}

function Write-TextFile([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function New-Directory([string]$Path) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

# Deletes a directory tree. rmdir /s does not follow junctions and copes with
# most long paths; robocopy /MIR from an empty directory handles the rest.
function Remove-Tree([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    & cmd.exe /d /c rmdir /s /q $Path 2>&1 | Out-Null
    if (Test-Path -LiteralPath $Path) {
        $empty = Join-Path ([IO.Path]::GetTempPath()) ("please-empty-" + [guid]::NewGuid())
        New-Directory $empty
        & robocopy.exe $empty $Path /MIR /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        & cmd.exe /d /c rmdir /s /q $Path 2>&1 | Out-Null
        & cmd.exe /d /c rmdir /q $empty 2>&1 | Out-Null
    }
    $global:LASTEXITCODE = 0
    if (Test-Path -LiteralPath $Path) { Fail "could not remove '$Path'" }
}

# Splits a command line the way Windows programs do (CommandLineToArgvW rules):
# whitespace separates arguments, "..." groups, backslashes only escape quotes.
function Split-CommandLine([string]$Line) {
    $result = New-Object System.Collections.Generic.List[string]
    if (-not $Line) { return ,$result.ToArray() }
    $sb = New-Object System.Text.StringBuilder
    $inQuotes = $false
    $have = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($c -eq [char]'\') {
            $n = 0
            while ($i -lt $Line.Length -and $Line[$i] -eq [char]'\') { $n++; $i++ }
            if ($i -lt $Line.Length -and $Line[$i] -eq [char]'"') {
                [void]$sb.Append('\' * [int][math]::Floor($n / 2))
                if ($n % 2 -eq 1) { [void]$sb.Append('"') } else { $inQuotes = -not $inQuotes }
            } else {
                [void]$sb.Append('\' * $n)
                $i--
            }
            $have = $true
        } elseif ($c -eq [char]'"') {
            $inQuotes = -not $inQuotes
            $have = $true
        } elseif (-not $inQuotes -and [char]::IsWhiteSpace($c)) {
            if ($have) { $result.Add($sb.ToString()); [void]$sb.Clear(); $have = $false }
        } else {
            [void]$sb.Append($c)
            $have = $true
        }
    }
    if ($have) { $result.Add($sb.ToString()) }
    return ,$result.ToArray()
}

# Re-indents the output of ConvertTo-Json, which is valid but hard to read in
# Windows PowerShell 5.1.
function Format-Json([string]$Json) {
    $sb = New-Object System.Text.StringBuilder
    $indent = 0
    $inString = $false
    $escaped = $false
    foreach ($c in $Json.ToCharArray()) {
        if ($inString) {
            [void]$sb.Append($c)
            if ($escaped) { $escaped = $false }
            elseif ($c -eq [char]'\') { $escaped = $true }
            elseif ($c -eq [char]'"') { $inString = $false }
            continue
        }
        if ($c -eq [char]'"') {
            [void]$sb.Append($c); $inString = $true
        } elseif ($c -eq [char]'{' -or $c -eq [char]'[') {
            $indent++
            [void]$sb.Append($c).Append("`n").Append(' ' * (4 * $indent))
        } elseif ($c -eq [char]'}' -or $c -eq [char]']') {
            $indent--
            [void]$sb.Append("`n").Append(' ' * (4 * $indent)).Append($c)
        } elseif ($c -eq [char]',') {
            [void]$sb.Append(",`n").Append(' ' * (4 * $indent))
        } elseif ($c -eq [char]':') {
            [void]$sb.Append(': ')
        } elseif (-not [char]::IsWhiteSpace($c)) {
            [void]$sb.Append($c)
        }
    }
    $text = $sb.ToString()
    $text = [regex]::Replace($text, '\[\s+\]', '[]')
    $text = [regex]::Replace($text, '\{\s+\}', '{}')
    return $text + "`n"
}

function Get-BuildDir([string]$Branch) { return Join-Path $ScriptDir "$Branch-build" }
function Get-AppsDir([string]$Branch) { return Join-Path $ScriptDir "$Branch-apps" }

function Get-WorkspaceFile([string]$Branch) {
    $name = $Branch -replace '[./-]', ''
    return Join-Path $ScriptDir "Qt$name.code-workspace"
}

function Assert-Branch([string]$Branch) {
    if (-not $Branch -or -not (Test-Path -LiteralPath (Join-Path $ScriptDir $Branch) -PathType Container)) {
        Fail "'$Branch' is not an initialized branch — run: $Self create $Branch"
    }
}

# How to get each tool please.ps1 needs. Nothing beyond a stock Windows 11
# install is assumed (winget ships with it as part of App Installer).
$ToolHints = @{
    'git'   = @('winget install Git.Git', 'or download it from https://git-scm.com/download/win')
    'cmake' = @('winget install Kitware.CMake',
                "or add the 'C++ CMake tools for Windows' component in the Visual Studio Installer")
    'ninja' = @('winget install Ninja-build.Ninja',
                "or add the 'C++ CMake tools for Windows' component in the Visual Studio Installer")
    'cl'    = @('winget install Microsoft.VisualStudio.2022.Community --override "--passive --wait --add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended"',
                "or install Visual Studio / the Build Tools with the 'Desktop development with C++' workload",
                'or point PLEASE_VS at an existing installation or its vcvarsall.bat')
}

# Places a tool may be installed without being on PATH (e.g. installed after
# this shell was started, or bundled with Visual Studio).
function Get-ToolCandidates([string]$Tool) {
    $c = New-Object System.Collections.Generic.List[string]
    $pf = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432) | Where-Object { $_ } | Select-Object -Unique
    $winget = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet' } else { $null }
    switch ($Tool) {
        'git' {
            foreach ($p in $pf) { $c.Add((Join-Path $p 'Git\cmd\git.exe')) }
            if ($env:LOCALAPPDATA) { $c.Add((Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe')) }
        }
        'cmake' {
            foreach ($p in $pf) { $c.Add((Join-Path $p 'CMake\bin\cmake.exe')) }
            foreach ($vs in Get-VsInstallations) {
                $c.Add((Join-Path $vs.Path 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'))
            }
        }
        'ninja' {
            if ($winget) { $c.Add((Join-Path $winget 'Links\ninja.exe')) }
            foreach ($vs in Get-VsInstallations) {
                $c.Add((Join-Path $vs.Path 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe'))
            }
            if ($winget -and (Test-Path -LiteralPath (Join-Path $winget 'Packages'))) {
                foreach ($f in @(Get-ChildItem -Path (Join-Path $winget 'Packages\Ninja-build.Ninja*\ninja.exe') -ErrorAction SilentlyContinue)) {
                    $c.Add($f.FullName)
                }
            }
        }
        'clangd' {
            foreach ($p in $pf) { $c.Add((Join-Path $p 'LLVM\bin\clangd.exe')) }
            foreach ($vs in Get-VsInstallations) { $c.Add((Join-Path $vs.Path 'VC\Tools\Llvm\x64\bin\clangd.exe')) }
        }
    }
    return @($c)
}

# Finds a tool on PATH or in its usual install locations. A tool found off PATH
# is added to PATH for this process (and the programs it starts). Returns the
# path, or $null.
function Find-Tool([string]$Tool) {
    $cmd = Get-Command "$Tool.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    foreach ($candidate in Get-ToolCandidates $Tool) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $env:PATH = (Split-Path $candidate -Parent) + ';' + $env:PATH
            Write-Host "Using $Tool from $candidate (not on PATH)"
            return $candidate
        }
    }
    return $null
}

# Fails with install instructions for every tool in $Tools that cannot be found.
function Assert-Tools([string[]]$Tools) {
    $missing = @($Tools | Where-Object { -not (Find-Tool $_) })
    if ($missing.Count -eq 0) { return }
    Write-Host "Error: the following required tools were not found:" -ForegroundColor Red
    foreach ($t in $missing) {
        $name = if ($t -eq 'cl') { 'MSVC C++ compiler (cl.exe)' } else { $t }
        Write-Host "  - $name"
        foreach ($h in $ToolHints[$t]) { Write-Host "      $h" }
    }
    Write-Host "Open a new terminal after installing, so the updated PATH is picked up."
    Write-Host "See '$Self help' and https://wiki.qt.io/Building_Qt_6_from_Git for more help."
    exit 1
}

function Assert-Tool([string]$Tool) { Assert-Tools @($Tool) }

function Get-JobCount { return [Environment]::ProcessorCount }

# Splits a comma-separated module list
function Split-Modules([string]$List) {
    return @($List -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# ---------------------------------------------------------------------------
# Visual Studio / MSVC environment
# ---------------------------------------------------------------------------

$script:MsvcLoaded = $false

function Get-HostArch {
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { return 'arm64' }
    return 'x64'
}

function Get-VsInstallerDir {
    $pf86 = ${env:ProgramFiles(x86)}
    if (-not $pf86) { return $null }
    return Join-Path $pf86 'Microsoft Visual Studio\Installer'
}

function Get-VsWhere {
    $dir = Get-VsInstallerDir
    if ($dir) {
        $p = Join-Path $dir 'vswhere.exe'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $cmd = Get-Command vswhere.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# Maps a Visual Studio year to its major version ("2022" -> "17"); other input is returned as is.
function ConvertTo-VsMajor([string]$Version) {
    switch ($Version) {
        '2017' { return '15' }
        '2019' { return '16' }
        '2022' { return '17' }
        '2026' { return '18' }
    }
    return ($Version -split '\.')[0]
}

function New-VsInstall([string]$Name, [string]$Version, [string]$Path) {
    return [pscustomobject]@{
        Name    = $Name
        Version = $Version
        Path    = $Path
        VcVars  = Join-Path $Path 'VC\Auxiliary\Build\vcvarsall.bat'
    }
}

$script:VsInstallations = $null

# All Visual Studio installations that have vcvarsall.bat, newest first.
function Get-VsInstallations {
    if ($null -eq $script:VsInstallations) { $script:VsInstallations = @(Find-VsInstallations) }
    return $script:VsInstallations
}

function Find-VsInstallations {
    $list = New-Object System.Collections.Generic.List[object]
    $vswhere = Get-VsWhere
    if ($vswhere) {
        $component = if ((Get-HostArch) -eq 'arm64') { 'Microsoft.VisualStudio.Component.VC.Tools.ARM64' }
                     else { 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' }
        $json = Invoke-Quiet $vswhere -products '*' -prerelease -requires $component -format json -utf8
        if ($LASTEXITCODE -eq 0 -and $json) {
            foreach ($i in (($json -join "`n") | ConvertFrom-Json)) {
                $vs = New-VsInstall $i.displayName $i.installationVersion $i.installationPath
                if (Test-Path -LiteralPath $vs.VcVars) { $list.Add($vs) }
            }
        }
    }
    if ($list.Count -eq 0) {
        # No vswhere (or it found nothing): look in the default install locations
        foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if (-not $root) { continue }
            $pattern = Join-Path $root 'Microsoft Visual Studio\*\*\VC\Auxiliary\Build\vcvarsall.bat'
            foreach ($f in @(Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue)) {
                $install = $f.Directory.Parent.Parent.Parent.FullName
                $year = Split-Path (Split-Path $install -Parent) -Leaf
                $edition = Split-Path $install -Leaf
                $list.Add((New-VsInstall "Visual Studio $year $edition" "$(ConvertTo-VsMajor $year).0" $install))
            }
        }
    }
    return @($list | Sort-Object { [version]$_.Version } -Descending)
}

# Picks a Visual Studio installation: PLEASE_VS if set, otherwise the newest.
# Returns $null if there is none.
function Select-VsInstallation {
    $installs = @(Get-VsInstallations)
    $want = $env:PLEASE_VS
    if ($want) {
        if (Test-Path -LiteralPath $want -PathType Leaf) {
            $vs = [pscustomobject]@{ Name = $want; Version = '0.0'; Path = $null; VcVars = $want }
            return $vs
        }
        if (Test-Path -LiteralPath (Join-Path $want 'VC\Auxiliary\Build\vcvarsall.bat')) {
            return New-VsInstall $want '0.0' $want
        }
        $major = ConvertTo-VsMajor $want
        foreach ($vs in $installs) {
            if (($vs.Version -split '\.')[0] -eq $major) { return $vs }
        }
        Write-Host "Error: PLEASE_VS='$want' does not match any Visual Studio installation with the C++ tools." -ForegroundColor Red
        foreach ($vs in $installs) { Write-Host "  found: $($vs.Name) ($($vs.Version)) in $($vs.Path)" }
        exit 1
    }
    if ($installs.Count -eq 0) { return $null }
    if ($installs.Count -gt 1) {
        Write-Host "Found $($installs.Count) Visual Studio installations, using the newest: $($installs[0].Name)"
        Write-Host "  (set PLEASE_VS to e.g. $((ConvertTo-VsMajor ($installs[1].Version -split '\.')[0])) to choose another)"
    }
    return $installs[0]
}

# Reads the compiler an existing build was configured with, so a build tree keeps
# using the Visual Studio installation and MSVC toolset version it was made with.
function Get-CachedCompiler([string]$BuildBase) {
    if (-not $BuildBase) { return $null }
    $cache = Join-Path $BuildBase 'qtbase\CMakeCache.txt'
    if (-not (Test-Path -LiteralPath $cache)) { return $null }
    $hit = Select-String -LiteralPath $cache -Pattern '^CMAKE_CXX_COMPILER:[A-Z]+=(.+)$' | Select-Object -First 1
    if (-not $hit) { return $null }
    $cl = $hit.Matches[0].Groups[1].Value.Trim()
    $re = '^(?<vs>.+)[\\/]VC[\\/]Tools[\\/]MSVC[\\/](?<ver>[^\\/]+)[\\/]bin[\\/]Host(?<host>[^\\/]+)[\\/](?<target>[^\\/]+)[\\/]cl\.exe$'
    if ($cl -notmatch $re) { return $null }
    $vsRoot = $Matches['vs'] -replace '/', '\'
    $vcvars = Join-Path $vsRoot 'VC\Auxiliary\Build\vcvarsall.bat'
    if (-not (Test-Path -LiteralPath $vcvars)) {
        Write-Warn "the existing build in '$BuildBase' was configured with '$cl', which no longer exists"
        return $null
    }
    $hostArch = $Matches['host'].ToLower()
    $target = $Matches['target'].ToLower()
    $arch = if ($hostArch -eq $target) { $target } else { "${hostArch}_${target}" }
    return [pscustomobject]@{
        Compiler = [IO.Path]::GetFullPath($cl)
        VcVars   = $vcvars
        Arch     = $arch
        Toolset  = $Matches['ver']
    }
}

# Loads the vcvarsall.bat environment into this process, so every compiler,
# CMake and Ninja invocation that follows inherits it, then makes sure the
# compiler, CMake and Ninja can all be found.
function Import-MsvcEnvironment([string]$BuildBase) {
    Import-VcVars $BuildBase
    Assert-Tools @('cl', 'cmake', 'ninja')
}

function Import-VcVars([string]$BuildBase) {
    if ($script:MsvcLoaded) { return }

    $cached = if ($env:PLEASE_VS) { $null } else { Get-CachedCompiler $BuildBase }

    # Already inside a Developer Command Prompt with a matching compiler?
    $cl = Get-Command cl.exe -ErrorAction SilentlyContinue
    if ($cl -and $env:VSCMD_VER -and -not $env:PLEASE_VS) {
        if (-not $cached -or $cached.Compiler -ieq [IO.Path]::GetFullPath($cl.Source)) {
            Write-Host "Using the MSVC environment of this shell ($($cl.Source))"
            $script:MsvcLoaded = $true
            return
        }
    }

    if ($cached) {
        $vcvars = $cached.VcVars
        $vcvarsArgs = "$($cached.Arch) -vcvars_ver=$($cached.Toolset)"
        Write-Host "Using MSVC $($cached.Toolset) ($($cached.Arch)), which the existing build was configured with"
    } else {
        $vs = Select-VsInstallation
        if (-not $vs) { return }   # reported as a missing cl.exe by Import-MsvcEnvironment
        $vcvars = $vs.VcVars
        $vcvarsArgs = Get-HostArch
        Write-Host "Using $($vs.Name)"
    }

    # vcvarsall.bat calls vswhere.exe through PATH, so make sure it is there
    $installer = Get-VsInstallerDir
    $pathPrefix = if ($installer -and (Test-Path -LiteralPath $installer)) { "set `"PATH=$installer;%PATH%`"`r`n" } else { '' }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("please-vcvars-" + [guid]::NewGuid() + ".cmd")
    $script = "@echo off`r`n$pathPrefix" + "call `"$vcvars`" $vcvarsArgs >nul 2>&1`r`nset`r`n"
    [IO.File]::WriteAllText($tmp, $script, [Text.Encoding]::Default)
    try {
        $lines = Invoke-Quiet cmd.exe /d /c $tmp
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    $vars = @{}
    foreach ($l in $lines) {
        if ($l -match '^([^=]+)=(.*)$') { $vars[$Matches[1]] = $Matches[2] }
    }
    if (-not $vars.ContainsKey('VCToolsInstallDir')) {
        Fail "'$vcvars $vcvarsArgs' did not set up a compiler environment. Run it in cmd.exe to see why."
    }
    foreach ($k in $vars.Keys) {
        Set-Item -LiteralPath "Env:$k" -Value $vars[$k]
    }
    $script:MsvcLoaded = $true
}

function Test-LongPaths {
    $fs = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -ErrorAction SilentlyContinue
    $enabled = $fs -and ($fs.PSObject.Properties.Name -contains 'LongPathsEnabled') -and $fs.LongPathsEnabled -eq 1
    if (-not $enabled) {
        Write-Warn "long path support is disabled in Windows; deep Qt build paths may fail."
        Write-Host "  From an elevated prompt: reg add HKLM\SYSTEM\CurrentControlSet\Control\FileSystem /v LongPathsEnabled /t REG_DWORD /d 1 /f"
    }
    $gitLong = Invoke-Quiet git config --get core.longpaths
    if ($gitLong -ne 'true') {
        Write-Warn "git core.longpaths is not enabled; checkouts with long paths may fail."
        Write-Host "  Run: git config --global core.longpaths true"
    }
}

function Test-Clangd {
    if (-not (Find-Tool 'clangd')) {
        Write-Host "Note: clangd was not found; install it for code navigation in VS Code (winget install LLVM.LLVM)."
    }
}

# ---------------------------------------------------------------------------
# git helpers
# ---------------------------------------------------------------------------

# Paths of all worktrees of qt6, except qt6 itself
function Get-Worktrees {
    if (-not (Test-Path -LiteralPath $Qt6Dir)) { return @() }
    $qt6 = [IO.Path]::GetFullPath($Qt6Dir).TrimEnd('\')
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($l in @(Invoke-Quiet git -C $Qt6Dir worktree list --porcelain)) {
        if ($l -match '^worktree (.+)$') {
            $p = [IO.Path]::GetFullPath($Matches[1]).TrimEnd('\')
            if ($p -ine $qt6 -and (Test-Path -LiteralPath $p)) { $result.Add($p) }
        }
    }
    return @($result)
}

# Initialized top-level submodules of a worktree in build order:
# DefaultModules first (preserving their declared order), then any extras.
function Get-InitializedModules([string]$WorktreeDir) {
    $initialized = New-Object System.Collections.Generic.List[string]
    foreach ($l in @(Invoke-Quiet git -C $WorktreeDir submodule status)) {
        if ($l -and $l[0] -ne [char]'-') {
            $fields = $l.Substring(1).Trim() -split '\s+'
            if ($fields.Count -ge 2) { $initialized.Add($fields[1]) }
        }
    }
    $ordered = New-Object System.Collections.Generic.List[string]
    foreach ($m in $DefaultModules) { if ($initialized -contains $m) { $ordered.Add($m) } }
    foreach ($m in $initialized) { if ($DefaultModules -notcontains $m) { $ordered.Add($m) } }
    return @($ordered)
}

# Required Qt module dependencies listed in a dependencies.yaml file
function Get-RequiredDeps([string]$YamlFile) {
    if (-not (Test-Path -LiteralPath $YamlFile)) { return @() }
    $result = New-Object System.Collections.Generic.List[string]
    $module = $null
    $required = $false
    foreach ($line in [IO.File]::ReadAllLines($YamlFile)) {
        if ($line -match '^  \.\./([^:]+):') {
            if ($module -and $required) { $result.Add($module) }
            $module = $Matches[1] -replace '^tqtc-', ''
            $required = $false
        }
        if ($line -match 'required: true') { $required = $true }
    }
    if ($module -and $required) { $result.Add($module) }
    return @($result)
}

# Reads the Gerrit username from ~/.ssh/config (Host codereview.qt-project.org,
# User field). Returns '' and prints a warning if the config is missing or incomplete.
function Get-GerritUsername {
    $sshConfig = Join-Path $HOME '.ssh\config'
    if (-not (Test-Path -LiteralPath $sshConfig)) {
        Write-Warn "$sshConfig not found — gerrit remote added without a username."
        Write-Host "  Follow the setup guide: https://wiki.qt.io/Setting_up_Gerrit#Local_Setup"
        return ''
    }
    $inHost = $false
    $username = ''
    foreach ($line in [IO.File]::ReadAllLines($sshConfig)) {
        if ($line -match '^Host\s+codereview\.qt-project\.org(\s|$)') {
            $inHost = $true
        } elseif ($line -match '^Host\s' -and $inHost) {
            break
        } elseif ($inHost -and $line -match '^\s*User\s+(.+)$') {
            $username = $Matches[1].Trim()
            break
        }
    }
    if (-not $username) {
        Write-Warn "No User entry for codereview.qt-project.org in $sshConfig."
        Write-Host "  Follow the setup guide: https://wiki.qt.io/Setting_up_Gerrit#Local_Setup"
    }
    return $username
}

# Configures the lts (tqtc-) remote for a module. The tqtc- mirrors are only
# reachable over authenticated ssh, so a Gerrit username is mandatory here.
function Set-LtsRemote([string]$RepoDir, [string]$ModuleName, [string]$GerritUser, [string]$PushBranch = '') {
    if (-not $GerritUser) { return $false }
    & git -C $RepoDir config remote.lts.url "ssh://${GerritUser}@codereview.qt-project.org:29418/qt/tqtc-${ModuleName}"
    & git -C $RepoDir config remote.lts.fetch '+refs/heads/*:refs/remotes/lts/*'
    # LTS changes are reviewed on the tqtc- project under the LTS branch name,
    # so 'git push lts' must not reuse the public remote.gerrit.push refspec.
    if ($PushBranch) { & git -C $RepoDir config remote.lts.push "HEAD:refs/for/${PushBranch}" }
    return $true
}

# Resolves <branch> to an explicit remote-tracking ref, e.g. 'origin/6.2' or
# 'lts/tqtc/lts-6.2'. In lts mode the tqtc/lts-<branch> branch wins where it
# exists. Returns $null if no candidate exists.
function Resolve-BranchRef([string]$RepoDir, [string]$Branch, [bool]$Lts) {
    $candidates = @()
    if ($Lts) { $candidates += "lts/tqtc/lts-$Branch" }
    $candidates += "origin/$Branch", "lts/$Branch"
    foreach ($ref in $candidates) {
        & git -C $RepoDir show-ref --verify --quiet "refs/remotes/$ref"
        if ($LASTEXITCODE -eq 0) { return $ref }
    }
    return $null
}

# Fetches every remote the branch might live on, then resolves it. In lts mode
# the lts remote is created on demand so tqtc/lts-* branches become visible.
function Get-FetchedBranchRef([string]$RepoDir, [string]$ModuleName, [string]$Branch, [bool]$Lts, [string]$GerritUser) {
    & git -C $RepoDir fetch origin | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Warn "fetching origin in '$RepoDir' failed" }
    if ($Lts) {
        Set-LtsRemote $RepoDir $ModuleName $GerritUser | Out-Null
        $ltsUrl = Invoke-Quiet git -C $RepoDir config --get remote.lts.url
        if ($ltsUrl) {
            & git -C $RepoDir fetch lts | Out-Host
            if ($LASTEXITCODE -ne 0) { Write-Warn "fetching lts in '$RepoDir' failed" }
        }
    }
    return Resolve-BranchRef $RepoDir $Branch $Lts
}

# The branch a worktree is on ('tqtc/lts-6.2' for an LTS worktree), or the
# fallback for a detached HEAD.
function Get-WorktreeUpstreamBranch([string]$WorktreeDir, [string]$Fallback) {
    $b = Invoke-Quiet git -C $WorktreeDir symbolic-ref --short HEAD
    if ($LASTEXITCODE -eq 0 -and $b) { return "$b".Trim() }
    return $Fallback
}

function Test-LtsBranch([string]$Branch) { return $Branch -like 'tqtc/*' }

# Initializes a submodule, falling back to the lts (tqtc-) mirror when the
# recorded gitlink cannot be found on origin. LTS commits made after a version's
# final open-source release exist only in the tqtc- repos.
function Initialize-Submodule([string]$WorktreeDir, [string]$Module, [string]$GerritUser, [bool]$Lts) {
    & git -C $WorktreeDir submodule update --init $Module
    if ($LASTEXITCODE -eq 0) { return }

    if (-not $Lts) {
        Fail "could not initialize '$Module'.`n  If '$Module' is on an LTS branch, re-run create with --lts to use the tqtc- mirrors."
    }
    # A checkout failure still leaves the clone behind; anything else is not a
    # missing-gitlink problem and retrying against lts will not help.
    if (-not (Test-Path -LiteralPath (Join-Path $WorktreeDir "$Module\.git"))) {
        Fail "'$Module' could not be cloned."
    }
    Write-Host "  gitlink for '$Module' is not on origin — retrying via the lts remote..."
    if (-not (Set-LtsRemote (Join-Path $WorktreeDir $Module) $Module $GerritUser)) {
        Fail "a Gerrit username is required to fetch from the lts remote."
    }
    & git -C (Join-Path $WorktreeDir $Module) fetch lts
    Assert-LastExit "Fetching lts for $Module"
    & git -C $WorktreeDir submodule update $Module
    Assert-LastExit "Initializing $Module"
}

# Configures the gerrit remote and review username in a module's local git config.
function Set-GerritRemote([string]$ModuleDir, [string]$ModuleName, [string]$GerritUser, [string]$Branch,
                          [bool]$SetupLts = $false, [string]$LtsBranch = '') {
    if (-not $LtsBranch) { $LtsBranch = $Branch }
    $url = if ($GerritUser) { "ssh://${GerritUser}@codereview.qt-project.org:29418/qt/${ModuleName}" }
           else { "ssh://codereview.qt-project.org:29418/qt/${ModuleName}" }
    & git -C $ModuleDir config remote.gerrit.url $url
    & git -C $ModuleDir config remote.gerrit.fetch '+refs/heads/*:refs/remotes/gerrit/*'
    & git -C $ModuleDir config remote.gerrit.push "HEAD:refs/for/${Branch}"

    if ($GerritUser) {
        $existing = Invoke-Quiet git -C $ModuleDir config review.codereview.qt-project.org.username
        if (-not $existing) {
            & git -C $ModuleDir config review.codereview.qt-project.org.username $GerritUser
        }
        if ($SetupLts) { Set-LtsRemote $ModuleDir $ModuleName $GerritUser $LtsBranch | Out-Null }
    }
}

# Installs the Qt git hooks (commit-msg, post-commit, pre-commit) into a module's
# hooks dir. Symlinks need extra privileges on Windows, so each hook is a small
# sh wrapper (git runs hooks with its bundled sh) that execs the qtrepotools one.
function Install-GitHooks([string]$ModuleDir) {
    $hooksSrc = Join-Path $Qt6Dir 'qtrepotools\git-hooks'
    if (-not (Test-Path -LiteralPath $hooksSrc)) {
        Write-Warn "qtrepotools/git-hooks not found — skipping hook installation for $(Split-Path $ModuleDir -Leaf)"
        return
    }
    $gitDir = @(Invoke-Quiet git -C $ModuleDir rev-parse --absolute-git-dir) | Select-Object -First 1
    if (-not $gitDir) { return }

    $hooksDir = Join-Path $gitDir 'hooks'
    New-Directory $hooksDir
    $hooks = [ordered]@{
        'commit-msg'  = 'gerrit_commit_msg_hook'
        'post-commit' = 'git_post_commit_hook'
        'pre-commit'  = 'clang-format-pre-commit'
    }
    foreach ($hook in $hooks.Keys) {
        $target = (Join-Path $hooksSrc $hooks[$hook]) -replace '\\', '/'
        Write-TextFile (Join-Path $hooksDir $hook) "#!/bin/sh`n# Installed by please.ps1`nexec `"$target`" `"`$@`"`n"
    }
}

# ---------------------------------------------------------------------------
# Apps
# ---------------------------------------------------------------------------

# The primary executable target name in a CMakeLists.txt: the first
# qt_add_executable, add_executable, qt_internal_add_manual_test, then project(),
# then the directory name.
function Get-CMakeExeName([string]$CMakeFile) {
    $lines = [IO.File]::ReadAllLines($CMakeFile)
    foreach ($fn in 'qt_add_executable', 'add_executable', 'qt_internal_add_manual_test') {
        foreach ($l in $lines) {
            if ($l -match "^\s*$fn\s*\(\s*([^\s,)]+)") { return $Matches[1] }
        }
    }
    foreach ($l in $lines) {
        if ($l -match '^\s*project\s*\(\s*([^\s)]+)') { return $Matches[1] }
    }
    return Split-Path (Split-Path $CMakeFile -Parent) -Leaf
}

function Get-AppType([string]$AppSrcDir) {
    if (Test-Path -LiteralPath (Join-Path $AppSrcDir 'CMakeLists.txt')) { return 'cmake' }
    return 'qmake'
}

function Get-RegisteredApps([string]$Branch) {
    $dir = Get-AppsDir $Branch
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Directory | Sort-Object Name | ForEach-Object { $_.Name })
}

# Locates the built executable for a registered app, or returns $null.
# Tries the conventional locations, then the CMake File API reply (executable
# targets: exact name, then case-insensitive, then the only one), and finally a
# filename match in the build dir and its bin\.
function Find-AppExe([string]$BuildDir, [string]$Name) {
    foreach ($sub in '', 'bin', 'debug', 'release') {
        $candidate = if ($sub) { Join-Path $BuildDir "$sub\$Name.exe" } else { Join-Path $BuildDir "$Name.exe" }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    $replyDir = Join-Path $BuildDir '.cmake\api\v1\reply'
    if (Test-Path -LiteralPath $replyDir) {
        try {
            $index = Get-ChildItem -LiteralPath $replyDir -Filter 'index-*.json' | Sort-Object Name | Select-Object -Last 1
            if ($index) {
                $idx = [IO.File]::ReadAllText($index.FullName) | ConvertFrom-Json
                $cmRef = $idx.reply.'codemodel-v2'
                if ($cmRef) {
                    $codemodel = [IO.File]::ReadAllText((Join-Path $replyDir $cmRef.jsonFile)) | ConvertFrom-Json
                    $exes = [ordered]@{}
                    foreach ($config in $codemodel.configurations) {
                        foreach ($t in $config.targets) {
                            $target = [IO.File]::ReadAllText((Join-Path $replyDir $t.jsonFile)) | ConvertFrom-Json
                            if ($target.type -ne 'EXECUTABLE' -or -not ($target.PSObject.Properties.Name -contains 'artifacts')) { continue }
                            if (-not $exes.Contains($target.name)) {
                                $exes[$target.name] = Join-Path $BuildDir $target.artifacts[0].path
                            }
                        }
                    }
                    # Keys of an ordered dictionary compare case-insensitively, like target names on Windows
                    $pick = if ($exes.Contains($Name)) { $exes[$Name] } elseif ($exes.Count -eq 1) { @($exes.Values)[0] } else { $null }
                    if ($pick -and (Test-Path -LiteralPath $pick -PathType Leaf)) { return $pick }
                }
            }
        } catch {
            # A partial or unreadable reply is not fatal; fall through to the filename search
        }
    }

    foreach ($dir in $BuildDir, (Join-Path $BuildDir 'bin')) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $f = Get-ChildItem -LiteralPath $dir -Filter "$Name.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    return $null
}

function New-FileApiQuery([string]$BuildDir, [string[]]$Kinds) {
    $q = Join-Path $BuildDir '.cmake\api\v1\query'
    New-Directory $q
    foreach ($k in $Kinds) {
        $p = Join-Path $q $k
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType File -Path $p | Out-Null }
    }
}

# Configures and builds an app. Expects the MSVC environment to be loaded.
function Build-App([string]$Branch, [string]$Name) {
    $buildBase = Get-BuildDir $Branch
    $srcDir = Join-Path (Get-AppsDir $Branch) $Name
    $buildDir = Join-Path $buildBase "apps\$Name"
    New-FileApiQuery $buildDir @('codemodel-v2', 'cache-v2', 'cmakeFiles-v1')

    if ((Get-AppType $srcDir) -eq 'cmake') {
        Write-Host "Configuring $Name with qt-cmake..."
        & (Join-Path $buildBase 'qtbase\bin\qt-cmake.bat') -G Ninja -DCMAKE_BUILD_TYPE=Debug `
            -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -S $srcDir -B $buildDir
        Assert-LastExit "Configuring $Name"
        Write-Host "Building $Name..."
        & ninja -C $buildDir
        Assert-LastExit "Building $Name"
    } else {
        Push-Location -LiteralPath $buildDir
        try {
            Write-Host "Configuring $Name with qmake..."
            & (Join-Path $buildBase 'qtbase\bin\qmake.exe') (Join-Path $srcDir "$Name.pro")
            Assert-LastExit "Configuring $Name"
            Write-Host "Building $Name..."
            if (Get-Command jom.exe -ErrorAction SilentlyContinue) {
                & jom.exe -j (Get-JobCount)
            } else {
                & nmake.exe /nologo
            }
            Assert-LastExit "Building $Name"
        } finally {
            Pop-Location
        }
    }
}

# ---------------------------------------------------------------------------
# Generated files: .clangd and .code-workspace
# ---------------------------------------------------------------------------

function Update-Clangd {
    $sb = New-Object System.Text.StringBuilder
    foreach ($wt in Get-Worktrees) {
        $dirName = Split-Path $wt -Leaf
        $buildDir = "$dirName-build"
        $escaped = [regex]::Escape($dirName)
        foreach ($m in Get-InitializedModules $wt) {
            [void]$sb.Append("---`nIf:`n  PathMatch: $escaped/$m/.*`nCompileFlags:`n  CompilationDatabase: $buildDir/$m`n`n")
        }
        $appsEscaped = [regex]::Escape("$dirName-apps")
        foreach ($app in Get-RegisteredApps $dirName) {
            [void]$sb.Append("---`nIf:`n  PathMatch: $appsEscaped/$app/.*`nCompileFlags:`n  CompilationDatabase: $buildDir/apps/$app`n`n")
        }
    }
    Write-TextFile (Join-Path $ScriptDir '.clangd') $sb.ToString()
}

function New-WorkspaceFile([string]$Branch, [string]$Dest, [string]$BuildBase, [string[]]$Modules) {
    # Executables need the Qt DLLs, which a non-installed build keeps in qtbase\bin
    $pathValue = (Join-Path $BuildBase 'qtbase\bin') + ';${env:PATH}'
    $runnables = New-Object System.Collections.Generic.List[object]

    # tst_*.exe under tests\auto\
    foreach ($m in $Modules) {
        $testsDir = Join-Path $BuildBase "$m\tests\auto"
        if (-not (Test-Path -LiteralPath $testsDir)) { continue }
        Get-ChildItem -LiteralPath $testsDir -Recurse -Filter 'tst_*.exe' -File -ErrorAction SilentlyContinue |
            Sort-Object FullName |
            ForEach-Object { $runnables.Add([pscustomobject]@{ Label = "${m}: $($_.BaseName)"; Exe = $_.FullName }) }
    }

    # .exe files under examples\
    foreach ($m in $Modules) {
        $examplesDir = Join-Path $BuildBase "$m\examples"
        if (-not (Test-Path -LiteralPath $examplesDir)) { continue }
        Get-ChildItem -LiteralPath $examplesDir -Recurse -Filter '*.exe' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\CMakeFiles\\' } |
            Sort-Object FullName |
            ForEach-Object {
                $rel = $_.FullName.Substring($examplesDir.Length + 1) -replace '\.exe$', '' -replace '\\', '/'
                $runnables.Add([pscustomobject]@{ Label = "$m examples: $rel"; Exe = $_.FullName })
            }
    }

    $apps = Get-RegisteredApps $Branch

    $folders = New-Object System.Collections.Generic.List[object]
    foreach ($m in $Modules) { $folders.Add([ordered]@{ name = $m; path = "$Branch/$m" }) }
    foreach ($a in $apps) { $folders.Add([ordered]@{ name = "app: $a"; path = "$Branch-apps/$a" }) }

    $settings = [ordered]@{
        'clangd.arguments'         = @('--background-index', '--clang-tidy', '--completion-style=detailed',
                                       '--header-insertion=iwyu', '--log=error')
        'files.associations'       = [ordered]@{ '*.qml' = 'qml'; '*.pri' = 'cmake'; '*.pro' = 'cmake'; '*.prf' = 'cmake' }
        'files.exclude'            = [ordered]@{ '**/.git' = $true; '**/.moc' = $true; '**/.rcc' = $true }
        'editor.tabSize'           = 4
        'editor.insertSpaces'      = $true
        'editor.rulers'            = @(100)
        'C_Cpp.intelliSenseEngine' = 'disabled'
        'cmake.configureOnOpen'    = $false
    }

    $tasks = New-Object System.Collections.Generic.List[object]
    $launch = New-Object System.Collections.Generic.List[object]
    foreach ($r in $runnables) {
        $tasks.Add([ordered]@{
            label          = $r.Label
            type           = 'process'
            command        = $r.Exe
            options        = [ordered]@{ cwd = (Split-Path $r.Exe -Parent); env = [ordered]@{ PATH = $pathValue } }
            group          = 'test'
            problemMatcher = @()
            presentation   = [ordered]@{ reveal = 'always'; panel = 'dedicated' }
        })
        $launch.Add([ordered]@{
            name        = $r.Label
            type        = 'cppvsdbg'
            request     = 'launch'
            program     = $r.Exe
            args        = @()
            cwd         = (Split-Path $r.Exe -Parent)
            environment = @([ordered]@{ name = 'PATH'; value = $pathValue })
            console     = 'integratedTerminal'
        })
    }

    $pleasePs1 = Join-Path $ScriptDir 'please.ps1'
    foreach ($a in $apps) {
        $appBuildDir = Join-Path $BuildBase "apps\$a"
        $exe = Find-AppExe $appBuildDir $a
        if (-not $exe) { $exe = Join-Path $appBuildDir "$a.exe" }
        $label = "app: $a"
        # Build-only task, shared by the run task (dependsOn) and the debug
        # launch configuration (preLaunchTask). It goes through please.ps1 so
        # the MSVC environment is loaded.
        $tasks.Add([ordered]@{
            label          = "build $label"
            type           = 'process'
            command        = 'powershell.exe'
            args           = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $pleasePs1,
                               'app-run', $Branch, $a, '--build-only')
            group          = 'build'
            hide           = $true
            problemMatcher = @('$msCompile')
            presentation   = [ordered]@{ reveal = 'always'; panel = 'shared' }
        })
        $tasks.Add([ordered]@{
            label          = $label
            type           = 'process'
            command        = $exe
            options        = [ordered]@{ cwd = $appBuildDir; env = [ordered]@{ PATH = $pathValue } }
            dependsOn      = "build $label"
            group          = 'build'
            problemMatcher = @()
            presentation   = [ordered]@{ reveal = 'always'; panel = 'dedicated' }
        })
        $launch.Add([ordered]@{
            name          = $label
            type          = 'cppvsdbg'
            request       = 'launch'
            program       = $exe
            args          = @()
            cwd           = $appBuildDir
            environment   = @([ordered]@{ name = 'PATH'; value = $pathValue })
            console       = 'integratedTerminal'
            preLaunchTask = "build $label"
        })
    }

    $workspace = [ordered]@{
        folders  = $folders
        settings = $settings
        tasks    = [ordered]@{ version = '2.0.0'; tasks = $tasks }
        launch   = [ordered]@{ version = '0.2.0'; configurations = $launch }
    }
    Write-TextFile $Dest (Format-Json ($workspace | ConvertTo-Json -Depth 20))
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

function Invoke-Create([string[]]$CmdArgs) {

    $lts = $false
    $pos = New-Object System.Collections.Generic.List[string]
    foreach ($a in $CmdArgs) { if ($a -eq '--lts') { $lts = $true } else { $pos.Add($a) } }

    $branch = if ($pos.Count -ge 1) { $pos[0] } else { $DefaultBranch }
    $modules = if ($pos.Count -ge 2) { Split-Modules $pos[1] } else { $DefaultModules }
    $worktreeDir = Join-Path $ScriptDir $branch

    Test-LongPaths

    # Ensure the qt6 supermodule exists
    if (-not (Test-Path -LiteralPath $Qt6Dir)) {
        $answer = Read-Host 'qt6 not found. Clone from code.qt.io? [y/N]'
        if ($answer -ne 'y') { Write-Host 'Aborting.'; exit 1 }
        & git clone https://code.qt.io/qt/qt5.git $Qt6Dir
        Assert-LastExit 'Cloning qt5.git'
    }

    # Resolve the Gerrit username once up front (may emit a warning if not found)
    $gerritUser = Get-GerritUsername
    if (-not $gerritUser) {
        $answer = Read-Host 'Continue without a Gerrit username? [y/N]'
        if ($answer -ne 'y') { Write-Host 'Aborting.'; exit 1 }
    }

    # Always initialize qtrepotools so git hooks are available
    Write-Host 'Initializing qtrepotools...'
    & git -C $Qt6Dir submodule update --init qtrepotools
    Assert-LastExit 'Initializing qtrepotools'

    # Create the worktree only if it doesn't already exist
    if (-not (Test-Path -LiteralPath $worktreeDir)) {
        # Resolve the branch to an explicit remote-tracking ref first, so the
        # worktree starts from a known remote instead of relying on git's DWIM.
        $branchRef = Resolve-BranchRef $Qt6Dir $branch $lts
        if (-not $branchRef) {
            Write-Host "Branch '$branch' not found locally, fetching qt6..."
            $branchRef = Get-FetchedBranchRef $Qt6Dir 'qt5' $branch $lts $gerritUser
            if (-not $branchRef) {
                if (-not $lts) { Write-Host "  For a commercial LTS version, try: $Self create --lts $branch" }
                Fail "branch '$branch' not found on any remote of qt6."
            }
        }

        # Point out the LTS branch when the public one is the frozen leftover of
        # a version that kept getting patch releases behind the tqtc- wall.
        if (-not $lts) {
            & git -C $Qt6Dir show-ref --verify --quiet "refs/remotes/lts/tqtc/lts-$branch"
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Note: '$branch' also has an LTS branch (tqtc/lts-$branch) with later patch"
                Write-Host "      releases. Use '$Self create --lts $branch' to track that instead."
            }
        }

        # The local branch keeps the remote's own name (e.g. 'tqtc/lts-6.2'),
        # while the worktree directory stays '$branch'.
        $localBranch = $branchRef.Substring($branchRef.IndexOf('/') + 1)
        Write-Host "Creating worktree for '$branch' from '$branchRef'..."

        # git won't create a worktree for a branch already checked out elsewhere,
        # including the main worktree. Detach qt6's HEAD to free the branch.
        $qt6Branch = Invoke-Quiet git -C $Qt6Dir symbolic-ref --short HEAD
        if ("$qt6Branch".Trim() -eq $localBranch) {
            Write-Host "Detaching qt6 HEAD from '$localBranch' to allow worktree creation..."
            & git -C $Qt6Dir checkout --detach
            Assert-LastExit 'Detaching qt6 HEAD'
        }
        & git -C $Qt6Dir show-ref --verify --quiet "refs/heads/$localBranch"
        if ($LASTEXITCODE -eq 0) {
            & git -C $Qt6Dir worktree add $worktreeDir $localBranch
        } else {
            & git -C $Qt6Dir worktree add -b $localBranch $worktreeDir $branchRef
        }
        Assert-LastExit 'Creating the worktree'
    } else {
        Write-Host "Worktree '$worktreeDir' already exists, resuming..."
    }

    # The branch the worktree actually sits on, which is what Gerrit expects as
    # a review target ('tqtc/lts-6.2' rather than '6.2' for an LTS worktree).
    $upstreamBranch = Get-WorktreeUpstreamBranch $worktreeDir $branch

    # Refuse to flip an existing worktree between the public and the LTS branch.
    $wantRef = Resolve-BranchRef $Qt6Dir $branch $lts
    if ($wantRef) {
        $wantBranch = $wantRef.Substring($wantRef.IndexOf('/') + 1)
        if ($upstreamBranch -ne $wantBranch) {
            $ltsFlag = if ($lts) { ' --lts' } else { '' }
            Write-Host "  To switch between the public and the LTS branch, recreate it:"
            Write-Host "    $Self destroy $branch; $Self create$ltsFlag $branch"
            Fail "worktree '$worktreeDir' is on '$upstreamBranch', but this asks for '$wantBranch'."
        }
    }

    # Set up the gerrit remote (and lts if requested) for the supermodule
    if ($gerritUser) {
        Write-Host 'Configuring gerrit remote for supermodule...'
        Set-GerritRemote $worktreeDir 'qt5' $gerritUser $branch $lts $upstreamBranch
    }

    # A queue, so that required dependencies discovered on the way can be appended
    $queue = New-Object System.Collections.Generic.List[string]
    foreach ($m in $modules) { $queue.Add($m) }
    $planned = @{}
    # Already-initialized modules are skipped silently and don't trigger
    # dependency warnings on re-runs
    foreach ($m in Get-InitializedModules $worktreeDir) { $planned[$m] = $true }
    foreach ($m in $modules) { $planned[$m] = $true }

    for ($qi = 0; $qi -lt $queue.Count; $qi++) {
        $module = $queue[$qi]
        $moduleDir = Join-Path $worktreeDir $module

        $status = @(Invoke-Quiet git -C $worktreeDir submodule status $module) | Select-Object -First 1
        if ($status -and $status[0] -ne [char]'-') {
            Write-Host "Skipping $module (already initialized)"
            Set-GerritRemote $moduleDir $module $gerritUser $branch $lts $upstreamBranch
            Install-GitHooks $moduleDir
            continue
        }

        Write-Host "Initializing $module..."
        Initialize-Submodule $worktreeDir $module $gerritUser $lts

        $moduleRef = Get-FetchedBranchRef $moduleDir $module $branch $lts $gerritUser
        if (-not $moduleRef) { Fail "branch '$branch' not found on any remote of '$module'." }
        Write-Host "Checking out $moduleRef in $module..."
        & git -C $moduleDir checkout $moduleRef
        Assert-LastExit "Checking out $moduleRef in $module"

        Write-Host "Initializing $module submodules..."
        & git -C $moduleDir submodule update --init --recursive
        Assert-LastExit "Initializing $module submodules"

        Write-Host "Configuring gerrit remote for $module..."
        Set-GerritRemote $moduleDir $module $gerritUser $branch $lts $upstreamBranch
        Install-GitHooks $moduleDir

        # Required dependencies from dependencies.yaml (qtbase has none)
        if ($module -ne 'qtbase') {
            foreach ($dep in Get-RequiredDeps (Join-Path $moduleDir 'dependencies.yaml')) {
                if (-not $planned.ContainsKey($dep)) {
                    Write-Warn "'$dep' is a required dependency of '$module' but was not in the module list — adding implicitly"
                    $queue.Add($dep)
                    $planned[$dep] = $true
                }
            }
        }
    }

    Write-Host 'Updating .clangd...'
    Update-Clangd

    Write-Host "Done: $worktreeDir"
}

function Invoke-Build([string]$Branch, [string[]]$CmdArgs) {
    $reserve = $null
    $reconfigure = $false
    $extra = @()
    for ($i = 0; $i -lt $CmdArgs.Count; $i++) {
        $a = $CmdArgs[$i]
        if ($a -eq '--') {
            if ($i + 1 -lt $CmdArgs.Count) { $extra = @($CmdArgs[($i + 1)..($CmdArgs.Count - 1)]) }
            break
        }
        if ($a -eq '--reconfigure') { $reconfigure = $true; continue }
        if ($a -eq '--creator') { Write-Warn '--creator is not supported on Windows yet; ignoring it'; continue }
        $reserve = $a
    }

    $worktreeDir = Join-Path $ScriptDir $Branch
    $buildBase = Get-BuildDir $Branch
    $workspaceFile = Get-WorkspaceFile $Branch

    if (-not (Test-Path -LiteralPath $worktreeDir)) {
        Fail "worktree '$worktreeDir' not found — run: $Self create $Branch"
    }

    $cores = Get-JobCount
    $jobs = $cores
    if ($null -ne $reserve) {
        if ($reserve -notmatch '^\d+$') { Fail 'reserve argument must be a non-negative integer' }
        $jobs = [math]::Max(1, $cores - [int]$reserve)
    }

    $modules = @(Get-InitializedModules $worktreeDir)
    if ($modules.Count -eq 0) { Fail "no initialized submodules found in '$worktreeDir'" }

    Import-MsvcEnvironment $buildBase
    Test-Clangd

    Write-Host "Detected modules: $($modules -join ' ')"
    Write-Host "Building with -j $jobs (cores=$cores)"

    foreach ($module in $modules) {
        $moduleBuildDir = Join-Path $buildBase $module
        if ($reconfigure) {
            Remove-Item -LiteralPath (Join-Path $moduleBuildDir 'CMakeCache.txt') -Force -ErrorAction SilentlyContinue
        }
        # Request every reply Qt Creator asks for, so it can load the build
        # without re-running CMake.
        New-FileApiQuery $moduleBuildDir @('codemodel-v2', 'cache-v2', 'cmakeFiles-v1', 'toolchains-v1', 'configureLog-v1')

        Write-Host "Configuring $module..."
        Push-Location -LiteralPath $moduleBuildDir
        try {
            if ($module -eq 'qtbase') {
                & (Join-Path $worktreeDir 'qtbase\configure.bat') -developer-build @extra
            } else {
                & (Join-Path $buildBase 'qtbase\bin\qt-configure-module.bat') (Join-Path $worktreeDir $module)
            }
            Assert-LastExit "Configuring $module"
        } finally {
            Pop-Location
        }

        Write-Host "Building $module..."
        & ninja -C $moduleBuildDir -j $jobs
        Assert-LastExit "Building $module"
    }

    Write-Host 'Creating workspace file...'
    New-WorkspaceFile $Branch $workspaceFile $buildBase $modules

    Write-Host 'Updating .clangd...'
    Update-Clangd

    Write-Host "Done: $buildBase"
    Write-Host "Workspace: $workspaceFile"
}

function Invoke-Destroy([string]$Branch) {
    $worktreeDir = Join-Path $ScriptDir $Branch
    $buildBase = Get-BuildDir $Branch
    $workspaceFile = Get-WorkspaceFile $Branch
    $appsDir = Get-AppsDir $Branch

    if (-not (Test-Path -LiteralPath $worktreeDir) -and -not (Test-Path -LiteralPath $buildBase) -and
        -not (Test-Path -LiteralPath $workspaceFile)) {
        Fail "nothing found for branch '$Branch'"
    }

    if (Test-Path -LiteralPath $worktreeDir) {
        Write-Host 'Removing worktree...'
        & git -C $Qt6Dir worktree remove --force $worktreeDir
        if ($LASTEXITCODE -ne 0) {
            # git refuses some worktrees (e.g. with submodules); delete it and let git forget it
            Write-Host 'git worktree remove failed, deleting the directory instead...'
            Remove-Tree $worktreeDir
            & git -C $Qt6Dir worktree prune
        }
    }

    if (Test-Path -LiteralPath $buildBase) {
        Write-Host 'Removing build directory...'
        Remove-Tree $buildBase
    }

    if (Test-Path -LiteralPath $workspaceFile) {
        Write-Host 'Removing workspace file...'
        Remove-Item -LiteralPath $workspaceFile -Force
    }

    if (Test-Path -LiteralPath $appsDir) {
        Write-Host 'Removing app source copies...'
        Remove-Tree $appsDir
    }

    Write-Host 'Updating .clangd...'
    Update-Clangd

    Write-Host 'Done.'
}

function Invoke-Update([string[]]$CmdArgs) {
    $sync = $false
    $lts = $null
    $pos = New-Object System.Collections.Generic.List[string]
    foreach ($a in $CmdArgs) {
        if ($a -eq '--sync') { $sync = $true }
        elseif ($a -eq '--lts') { $lts = $true }
        else { $pos.Add($a) }
    }

    $branch = if ($pos.Count -ge 1) { $pos[0] } else { $DefaultBranch }
    $worktreeDir = Join-Path $ScriptDir $branch
    if (-not (Test-Path -LiteralPath $worktreeDir)) {
        Fail "worktree '$worktreeDir' not found — run: $Self create $branch"
    }

    # Unless --lts was given, take the choice from the branch the worktree is
    # already on, so LTS worktrees keep tracking their tqtc/lts-* branch.
    $upstreamBranch = Get-WorktreeUpstreamBranch $worktreeDir $branch
    if ($null -eq $lts) { $lts = Test-LtsBranch $upstreamBranch }

    $gerritUser = if ($lts) { Get-GerritUsername } else { '' }

    $modules = @(Get-InitializedModules $worktreeDir)
    if ($modules.Count -eq 0) { Fail "no initialized submodules found in '$worktreeDir'" }

    # Bail early if any module has uncommitted changes
    foreach ($module in $modules) {
        $changes = Invoke-Quiet git -C (Join-Path $worktreeDir $module) status --porcelain --untracked-files=no
        if ($changes) {
            Write-Warn "'$module' has uncommitted changes — aborting update"
            exit 1
        }
    }

    foreach ($module in $modules) {
        Write-Host "Updating $module..."
        $moduleDir = Join-Path $worktreeDir $module
        $moduleRef = Get-FetchedBranchRef $moduleDir $module $branch $lts $gerritUser
        if (-not $moduleRef) { Fail "branch '$branch' not found on any remote of '$module'." }
        & git -C $moduleDir rebase $moduleRef
        Assert-LastExit "Rebasing $module onto $moduleRef"
    }

    if ($sync) {
        $cmakeScript = Join-Path $worktreeDir 'cmake\QtSynchronizeRepo.cmake'
        if (-not (Test-Path -LiteralPath $cmakeScript)) {
            Fail "QtSynchronizeRepo.cmake not found at '$cmakeScript'"
        }
        # Visual Studio's environment may be the only place CMake comes from
        if (-not (Find-Tool 'cmake')) { Import-VcVars $null }
        Assert-Tool 'cmake'
        # Sync against the real upstream name ('tqtc/lts-6.2' for an LTS worktree)
        Write-Host "Synchronizing submodules for '$upstreamBranch'..."
        Push-Location -LiteralPath $worktreeDir
        try {
            & cmake -DSYNC_TO_MODULE=. "-DSYNC_TO_BRANCH=$upstreamBranch" -P cmake/QtSynchronizeRepo.cmake
            Assert-LastExit 'QtSynchronizeRepo.cmake'
        } finally {
            Pop-Location
        }
    }

    Write-Host 'Done.'
}

function Invoke-AppAdd([string]$Branch, [string]$Path) {
    Assert-Branch $Branch
    if (-not $Path) { Fail 'app path required' }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Fail "'$Path' is not a directory" }
    $appPath = (Resolve-Path -LiteralPath $Path).ProviderPath.TrimEnd('\')
    $buildBase = Get-BuildDir $Branch
    $workspaceFile = Get-WorkspaceFile $Branch

    # Detect the project type
    if (Test-Path -LiteralPath (Join-Path $appPath 'CMakeLists.txt')) {
        $projectType = 'cmake'
        $exeName = Get-CMakeExeName (Join-Path $appPath 'CMakeLists.txt')
    } else {
        $dirName = Split-Path $appPath -Leaf
        $proFile = Join-Path $appPath "$dirName.pro"
        if (-not (Test-Path -LiteralPath $proFile)) {
            $proFile = Get-ChildItem -LiteralPath $appPath -Filter '*.pro' -File | Select-Object -First 1 -ExpandProperty FullName
        }
        if (-not $proFile) { Fail "no CMakeLists.txt or .pro file found in '$appPath'" }
        $projectType = 'qmake'
        $exeName = [IO.Path]::GetFileNameWithoutExtension($proFile)
    }
    Write-Host "Detected project type: $projectType, executable name: $exeName"

    if (-not (Test-Path -LiteralPath (Join-Path $buildBase 'qtbase\bin\qt-cmake.bat')) -and
        -not (Test-Path -LiteralPath (Join-Path $buildBase 'qtbase\bin\qmake.exe'))) {
        Fail "Qt not built for branch '$Branch' — run: $Self build $Branch"
    }

    # Copy the source into the managed tree so the main .clangd covers it
    $appsDir = Get-AppsDir $Branch
    New-Directory $appsDir
    $appSrcDir = Join-Path $appsDir $exeName
    if ($appSrcDir -ieq $appPath) { Fail "'$appPath' is already the registered copy; use app-run to rebuild it" }
    Write-Host "Copying source to $appSrcDir..."
    Remove-Tree $appSrcDir
    Copy-Item -LiteralPath $appPath -Destination $appSrcDir -Recurse

    Import-MsvcEnvironment $buildBase
    Build-App $Branch $exeName

    Write-Host 'Updating .clangd...'
    Update-Clangd

    if (Test-Path -LiteralPath $workspaceFile) {
        Write-Host 'Updating workspace file...'
        New-WorkspaceFile $Branch $workspaceFile $buildBase @(Get-InitializedModules (Join-Path $ScriptDir $Branch))
    }

    Write-Host "Done: $(Join-Path $buildBase "apps\$exeName")"
}

function Invoke-AppRemove([string]$Branch, [string]$Name) {
    Assert-Branch $Branch
    if (-not $Name) { Fail 'app name (or --all) required' }
    $buildBase = Get-BuildDir $Branch
    $workspaceFile = Get-WorkspaceFile $Branch
    $appsDir = Get-AppsDir $Branch

    if ($Name -eq '--all') {
        $names = @(Get-RegisteredApps $Branch)
        if ($names.Count -eq 0) {
            Write-Host "No apps registered for branch '$Branch'."
            return
        }
    } else {
        if (-not (Test-Path -LiteralPath (Join-Path $appsDir $Name) -PathType Container)) {
            Fail "no registered app named '$Name' for branch '$Branch'"
        }
        $names = @($Name)
    }

    foreach ($n in $names) {
        Write-Host "Removing '$n'..."
        Remove-Tree (Join-Path $appsDir $n)
        Remove-Tree (Join-Path $buildBase "apps\$n")
    }

    Write-Host 'Updating .clangd...'
    Update-Clangd

    if (Test-Path -LiteralPath $workspaceFile) {
        Write-Host 'Updating workspace file...'
        New-WorkspaceFile $Branch $workspaceFile $buildBase @(Get-InitializedModules (Join-Path $ScriptDir $Branch))
    }

    Write-Host 'Done.'
}

function Invoke-AppList([string]$Branch) {
    Assert-Branch $Branch
    $apps = @(Get-RegisteredApps $Branch)
    if ($apps.Count -eq 0) {
        Write-Host "No apps registered for branch '$Branch'."
        return
    }
    Write-Host ('{0,-30} {1}' -f 'NAME', 'TYPE')
    foreach ($a in $apps) {
        Write-Host ('{0,-30} {1}' -f $a, (Get-AppType (Join-Path (Get-AppsDir $Branch) $a)))
    }
}

function Invoke-AppRun([string]$Branch, [string]$Name, [bool]$BuildOnly) {
    Assert-Branch $Branch
    if (-not $Name) { Fail 'app name required' }
    $buildBase = Get-BuildDir $Branch
    $appSrcDir = Join-Path (Get-AppsDir $Branch) $Name
    if (-not (Test-Path -LiteralPath $appSrcDir -PathType Container)) {
        Fail "no registered app named '$Name' for branch '$Branch'"
    }
    $appBuildDir = Join-Path $buildBase "apps\$Name"

    Import-MsvcEnvironment $buildBase
    Build-App $Branch $Name
    if ($BuildOnly) { return }

    $exe = Find-AppExe $appBuildDir $Name
    if (-not $exe) { Fail "could not find an executable for '$Name' in '$appBuildDir'" }

    # A non-installed Qt build keeps its DLLs in qtbase\bin
    $env:PATH = (Join-Path $buildBase 'qtbase\bin') + ';' + $env:PATH
    Write-Host "Running $Name..."
    & $exe
    exit $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Commands taking [branch] <arg>: two positional arguments are branch and arg,
# one is just arg on the default branch.
function Split-BranchAndArg([string[]]$Positional) {
    if ($Positional.Count -ge 2) { return @($Positional[0], $Positional[1]) }
    if ($Positional.Count -eq 1) { return @($DefaultBranch, $Positional[0]) }
    return @($DefaultBranch, '')
}

function Invoke-Main([string[]]$Argv) {
    if ($Argv.Count -lt 1) { Show-Usage; exit 1 }
    $command = $Argv[0]
    $rest = @($Argv | Select-Object -Skip 1)
    $branchArg = if ($rest.Count -ge 1 -and -not $rest[0].StartsWith('-')) { $rest[0] } else { $null }

    # Every command except help works with git
    if (@('create', 'build', 'destroy', 'update', 'app-add', 'app-remove', 'app-list', 'app-run') -contains $command) {
        Assert-Tool 'git'
    }

    switch ($command) {
        'help'    { Show-Help }
        'create'  { Invoke-Create $rest }
        'build'   {
            $branch = if ($branchArg) { $branchArg } else { $DefaultBranch }
            $buildArgs = if ($branchArg) { @($rest | Select-Object -Skip 1) } else { $rest }
            Invoke-Build $branch $buildArgs
        }
        'destroy' { Invoke-Destroy $(if ($branchArg) { $branchArg } else { $DefaultBranch }) }
        'update'  { Invoke-Update $rest }
        'app-add' {
            $ba = Split-BranchAndArg $rest
            Invoke-AppAdd $ba[0] $ba[1]
        }
        'app-remove' {
            $ba = Split-BranchAndArg $rest
            Invoke-AppRemove $ba[0] $ba[1]
        }
        'app-list' { Invoke-AppList $(if ($branchArg) { $branchArg } else { $DefaultBranch }) }
        'app-run' {
            $buildOnly = $rest -contains '--build-only'
            $ba = Split-BranchAndArg @($rest | Where-Object { $_ -ne '--build-only' })
            Invoke-AppRun $ba[0] $ba[1] $buildOnly
        }
        default { Show-Usage; exit 1 }
    }
}

# Dot-sourcing (. .\please.ps1) only loads the functions
if ($MyInvocation.InvocationName -ne '.') {
    if ($env:PLEASE_BAT -eq '1') {
        # Launched by please.bat, which passes the raw command line in PLEASE_ARGS
        $argv = Split-CommandLine $env:PLEASE_ARGS
        Remove-Item Env:PLEASE_BAT, Env:PLEASE_ARGS -ErrorAction SilentlyContinue
    } else {
        $argv = @($args)
    }
    Invoke-Main $argv
    exit 0
}
