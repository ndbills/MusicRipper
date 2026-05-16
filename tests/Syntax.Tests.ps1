<#
    Pester syntax-guard tests for every PowerShell source file in
    the repo. Catches parse errors that PSScriptAnalyzer / VS Code
    diagnostics sometimes miss -- in particular, structural mistakes
    like dangling braces or unbalanced parens left behind by a
    sloppy multi_replace_string_in_file edit that only matched the
    first half of a script block.

    Approach
    --------
    Use the PowerShell AST parser directly:

        [System.Management.Automation.Language.Parser]::ParseFile(
            $path, [ref]$null, [ref]$errs)

    Any non-empty $errs collection = the file would parse-error at
    load time. Reported per-file via Pester's -ForEach test data so
    a failure points straight at the offending path + line number.

    History
    -------
    v0.2.2 (commit 70c48ee) shipped a broken src/ui/Show-UpdateDialog.ps1
    because a one-shot edit only matched the first half of a click
    handler's try/catch block, leaving orphaned `}` / `} catch { ... }`
    / `}.GetNewClosure())` lines below the new closure end. The bad
    file parsed without diagnostics in the IDE but failed at runtime
    -- "click the Update shortcut, nothing happens" -- because
    Update-MusicRipper.ps1's helper dot-sources Show-UpdateDialog.ps1
    and the helper pwsh process died on parse-time.

    This test catches that class of bug at CI / pre-commit time.
    If you're staring at a red entry below: the path + line in the
    failure message points exactly at the dangling structure.
#>

BeforeDiscovery {
    $repoRoot = Split-Path -Parent $PSScriptRoot

    # Enumerate every PowerShell source file the repo owns. We
    # include test files too -- a busted test file fails the test
    # discovery pass, which is its own kind of breakage worth
    # catching here.
    $exts = @('*.ps1', '*.psm1', '*.psd1')
    $roots = @(
        $repoRoot,                            # Install/Uninstall/Update at root
        (Join-Path $repoRoot 'src'),
        (Join-Path $repoRoot 'setup'),
        (Join-Path $repoRoot 'tests'),
        (Join-Path $repoRoot 'dev')           # plan.md, probe.ps1, etc.
    ) | Where-Object { Test-Path -LiteralPath $_ }

    $files = foreach ($r in $roots) {
        foreach ($ext in $exts) {
            # Top-level files for the root path; recurse for src/ etc.
            # (Get-ChildItem on the repo root with -Recurse would also
            # pull in the .git/ folder's hooks etc. -- skip that.)
            if ($r -eq $repoRoot) {
                Get-ChildItem -LiteralPath $r -Filter $ext -File -ErrorAction SilentlyContinue
            } else {
                Get-ChildItem -LiteralPath $r -Filter $ext -File -Recurse -ErrorAction SilentlyContinue
            }
        }
    }

    # Pester TestCases expects [hashtable[]] with a Path key. The
    # 'Name' key is what shows up in the Pester output line.
    $script:SyntaxCases = @(
        $files | Sort-Object -Property FullName -Unique | ForEach-Object {
            @{
                Path = $_.FullName
                # Pretty name = workspace-relative path. Keeps test
                # output readable on Windows where full paths are long.
                Name = $_.FullName.Substring($repoRoot.Length).TrimStart('\','/')
            }
        }
    )
}

Describe 'PowerShell source files parse cleanly' {

    It 'discovered at least one source file (sanity check on the enumerator itself)' {
        # Discovery-time variables aren't visible at It-execution
        # time in Pester 5, so we re-enumerate here. If this fails,
        # the BeforeDiscovery block's globbing has gone wrong and
        # every data-driven It below would silently pass with zero
        # cases.
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $count = (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src') `
                                -Include '*.ps1','*.psm1','*.psd1' `
                                -File -Recurse).Count
        $count | Should -BeGreaterThan 30
    }

    It '<Name> parses with zero AST errors' -ForEach $SyntaxCases {
        $errs   = $null
        $tokens = $null
        # ParseFile returns the AST but we only care about errors.
        [System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$tokens, [ref]$errs) | Out-Null

        if ($errs -and $errs.Count -gt 0) {
            # Build a one-line-per-error message so the Pester
            # failure summary shows file:line:column for each
            # parse error. Limit to the first 10 -- a single
            # dangling brace can cascade into dozens.
            $detail = ($errs | Select-Object -First 10 | ForEach-Object {
                "{0}({1},{2}): {3}" -f $Name,
                                       $_.Extent.StartLineNumber,
                                       $_.Extent.StartColumnNumber,
                                       $_.Message
            }) -join "`n"
            throw "Parse error(s) in '$Name':`n$detail"
        }
    }
}
