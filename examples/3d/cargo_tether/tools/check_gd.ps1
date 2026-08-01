<#
.SYNOPSIS
    GDScript parse + lint gate for a single file. Used by the PostToolUse hook.

.DESCRIPTION
    Runs two complementary checks, in this order:

      1. Godot's own parser (`--check-only`). Authoritative: catches parse errors,
         type mismatches, wrong argument counts, duplicate declarations.
      2. gdlint. Catches naming/style violations Godot does not care about.

    Two findings from testing these against real bugs drive the design:

      * `godot --check-only` does NOT reliably set a nonzero exit code. Parser
        errors (bad numeric literal, duplicate parameter) exit 1, but ANALYZER
        errors exit 0 while still printing "Parse Error" -- assigning a String to
        an int and calling rotated() with too few arguments both exit 0. So this
        script greps the output and ignores the exit code.
      * gdlint dies with a raw lark Python traceback on a file that does not
        parse, which buries the real error. So Godot runs first and gdlint is
        skipped entirely when Godot already found a problem.

    Neither tool catches runtime-semantic bugs: lambda capture-by-value, setting
    `owner` before the parent is in the tree, or `is_inside_tree()` being false
    during `SceneTree._initialize()`. Those live in CLAUDE.md as a trap list
    because no static checker will find them.

.PARAMETER Path
    Absolute path to the .gd file to check.

.OUTPUTS
    Exit 0 = clean or not applicable. Exit 2 = problems found (blocking; the
    message on stderr is fed back to Claude).
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)][string]$Path
)

$ErrorActionPreference = 'Continue'

# tools/check_gd.ps1 -> the example this gate covers is the parent of tools/.
$exampleRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# The Godot project root is wherever project.godot lives, which is NOT the example
# root: this demo sits several directories inside a host project. Walk up to find
# it, since `--path` and every res:// path are relative to it.
$projectRoot = $null
$dir = $exampleRoot
while ($dir) {
	if (Test-Path -LiteralPath (Join-Path $dir 'project.godot')) { $projectRoot = $dir; break }
	$dir = Split-Path -Parent $dir
}

# --- applicability guards: never block on things this gate does not cover -----
if (-not $Path) { exit 0 }
if ($Path -notmatch '\.gd$') { exit 0 }
if (-not (Test-Path -LiteralPath $Path)) { exit 0 }
if (-not $projectRoot) { exit 0 }

$full = (Resolve-Path -LiteralPath $Path).Path
if (-not $full.StartsWith($exampleRoot, [StringComparison]::OrdinalIgnoreCase)) { exit 0 }

$relative = $full.Substring($projectRoot.Length).TrimStart('\', '/').Replace('\', '/')
$resPath = "res://$relative"

$problems = [System.Collections.Generic.List[string]]::new()

# --- 1. Godot's parser -------------------------------------------------------
function Find-GodotBinary {
	if ($env:GODOT_BIN -and (Test-Path -LiteralPath $env:GODOT_BIN)) { return $env:GODOT_BIN }
	$candidates = @(
		'D:\Godot_v4.7.1-stable_win64_console.exe',
		'D:\Godot_v4.7.1-stable_win64.exe'
	)
	foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
	# Any console build on PATH, newest first.
	$onPath = Get-Command 'Godot*_console.exe', 'godot' -ErrorAction SilentlyContinue |
		Select-Object -First 1 -ExpandProperty Source
	if ($onPath) { return $onPath }
	return $null
}

$godot = Find-GodotBinary
$godotRan = $false
if ($godot) {
	$godotRan = $true
	# NOTE: exit code deliberately ignored -- see .DESCRIPTION.
	$out = & $godot --headless --path $projectRoot --check-only --script $resPath 2>&1
	$errLines = $out | Select-String -Pattern 'Parse Error|SCRIPT ERROR|Failed to load script|Compile Error'
	foreach ($line in $errLines) {
		$text = $line.Line.Trim()
		# The generic "Failed to load script ... with error Parse error" line adds
		# nothing once the specific error above it is reported.
		if ($text -notmatch '^ERROR: Failed to load script') {
			$problems.Add("  [godot] $text")
		}
	}
}

# --- 2. gdlint (only if the file parses) -------------------------------------
if ($problems.Count -eq 0) {
	$gdlint = Get-Command gdlint -ErrorAction SilentlyContinue
	if ($gdlint) {
		$lintOut = & $gdlint.Source $full 2>&1
		if ($LASTEXITCODE -ne 0) {
			$traceback = $lintOut | Select-String -Pattern 'Traceback \(most recent call last\)' -Quiet
			if ($traceback) {
				# gdlint could not parse it but Godot could. Report compactly rather
				# than dumping a 20-line Python traceback.
				$problems.Add('  [gdlint] failed to parse the file (Godot accepted it; gdlint grammar may lag the engine)')
			}
			else {
				foreach ($line in ($lintOut | Select-String -Pattern ':\d+: (Error|Warning):')) {
					$problems.Add("  [gdlint] $($line.Line.Trim())")
				}
			}
		}
	}
}

# --- report ------------------------------------------------------------------
if ($problems.Count -gt 0) {
	$header = "GDScript check FAILED for $relative"
	if (-not $godotRan) {
		$header += " (godot binary not found; set GODOT_BIN to enable parse checking)"
	}
	[Console]::Error.WriteLine($header)
	foreach ($p in $problems) { [Console]::Error.WriteLine($p) }
	[Console]::Error.WriteLine('Fix these before continuing.')
	exit 2
}

exit 0
