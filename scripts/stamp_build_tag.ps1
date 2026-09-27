# Regenerate rtl/build_tag.v from the current HEAD, so a hardware capture can
# name the bitstream it came from (read back on the PBLD probe).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/stamp_build_tag.ps1
#   (the machine's execution policy blocks scripts without the Bypass)
#
# Run this IMMEDIATELY BEFORE a Quartus compile, after everything else is
# committed. The tag then names the commit whose RTL is being built, and
# build_tag.v itself is left dirty in the tree -- that is expected and correct.
#
# The file is COMMITTED as 0 ("unstamped") on purpose, so a missed stamp reads
# back as UNSTAMPED instead of as the previous commit's SHA. Never commit the
# stamped value -- a stray 'git add -A' has poisoned it before (MacPlus,
# 2026-08-22: the tag was hand-stamped, then committed, and so named the
# PREVIOUS commit). A capture that misnames its own build is worse than no
# tag at all.
#
# The ritual (MacPlus's, SE30_PLAN.md 3.6): stamp -> compile ->
# scripts/archive_build.ps1 <label> WHILE THE TAG IS STILL STAMPED (it reads
# the SHA out of this file to name the archive) -> git checkout -- rtl/build_tag.v
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    $sha = (git rev-parse --short=8 HEAD).Trim()
    if ($sha -notmatch '^[0-9a-f]{8}$') { throw "unexpected SHA from git: '$sha'" }

    $dirty = git status --porcelain -- rtl sys MacSE30.sv MacSE30.qsf MacSE30.sdc files.qip |
             Where-Object { $_ -notmatch 'rtl/build_tag\.v' }
    if ($dirty) {
        Write-Warning "Design files are dirty; the tag will name HEAD, not what you are building:"
        $dirty | ForEach-Object { Write-Warning "  $_" }
    }

    # Byte-identical to the COMMITTED rtl/build_tag.v except for the SHA,
    # so `git diff` on a stamped tree is a one-line change and an accidental
    # `git add -A` is obvious. Keep the guard paragraph below in step with
    # the committed file if either is ever reworded.
    $body = @"
// build_tag.v -- REGENERATED BEFORE EVERY COMPILE by scripts/stamp_build_tag.ps1.
//
// The COMMITTED value is deliberately 0, meaning "unstamped". Do not commit a
// real SHA here: the file is stamped from HEAD just before a compile, so any
// SHA committed into it necessarily names the PREVIOUS commit. That happened
// on the MacPlus core (the file read ac38fc96 while HEAD was 3426398e), and a
// capture that misnames its own build is worse than no tag at all.
//
// With 0 committed, forgetting to stamp is reported by scripts/read_probes.tcl
// as "bitstream=UNSTAMPED" rather than as a confident, wrong SHA, and a stray
// ``git add -A`` cannot poison the tag.
//
// Read back on the PBLD probe (rtl/dbg_probes.sv). See SE30_PLAN.md 3.5.
module build_tag(output [31:0] tag);
	assign tag = 32'h$sha;
endmodule
"@
    # NOT Set-Content -Encoding utf8: on Windows PowerShell 5.1 that writes a
    # BOM, and iverilog then fails to parse the file. Plain UTF-8, no BOM, LF
    # (the file is ours, and ours are LF).
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $lf = ($body -replace "`r`n", "`n") + "`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $root 'rtl/build_tag.v'), $lf, $utf8NoBom)
    Write-Host "rtl/build_tag.v stamped $sha"
} finally { Pop-Location }
