# Archive the freshly built bitstream under the commit it came from.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/archive_build.ps1 dqrise
#   (the machine's execution policy blocks scripts without the Bypass)
#
# Produces output_files/<revision>_<sha>_<label>.rbf, the revision MacSE30
# unless -Revision MacIIcx is given.  (The .sof is not copied:
# MiSTer loads the .rbf and nothing here programs the FPGA over JTAG, so the
# 56 archived .sof files of 2026-10-10 were 359 MB of nothing - Daniel.)
#
# Why (MacPlus, 2026-08-22): two builds produced byte-identical hardware
# captures and answering "which build was that?" took a JTAG session
# enumerating ISSP instances, because output_files/MacSE30.rbf is one file
# every compile overwrites. PBLD answers it live; this answers it afterwards,
# off-board. Run it WHILE rtl/build_tag.v IS STILL STAMPED, before the
# `git checkout -- rtl/build_tag.v` that ends the build ritual.
param([Parameter(Mandatory=$true)][string]$Label,
      [string]$Revision = 'MacSE30')          # or MacIIcx: the Quartus revision that was compiled
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    if ($Label -notmatch '^[A-Za-z0-9._-]+$') { throw "label must be alphanumeric/._- : '$Label'" }
    # The bitstream is named by the tag COMPILED INTO IT, not by HEAD -- the
    # filename and what PBLD reports on the board must never disagree.
    $tagLine = Select-String -Path 'rtl/build_tag.v' -Pattern "assign tag = 32'h([0-9a-f]{8})"
    if (-not $tagLine) { throw 'cannot read the tag from rtl/build_tag.v' }
    $sha = $tagLine.Matches[0].Groups[1].Value
    if ($sha -eq '00000000') {
        throw 'rtl/build_tag.v is unstamped. Run scripts/stamp_build_tag.ps1 and recompile.'
    }

    # What matters is whether the DESIGN moved since that build, not whether any
    # commit did. Doc-only commits after a compile are normal and harmless; an
    # RTL commit means the bitstream no longer represents the tree.
    if ($Revision -notmatch '^(MacSE30|MacIIcx)$') { throw "revision must be MacSE30 or MacIIcx: '$Revision'" }
    $design = @('rtl','sys','MacSE30.sv',"$Revision.qsf",'MacSE30.sdc','files.qip')
    $moved  = git diff --name-only $sha HEAD -- $design 2>$null
    if ($LASTEXITCODE -ne 0) { throw "cannot diff $sha against HEAD; is it a valid commit?" }
    if ($moved) {
        throw ("design files changed since the build tagged ${sha}:" + [Environment]::NewLine +
               ($moved -join [Environment]::NewLine) + [Environment]::NewLine +
               'Re-stamp and recompile rather than archiving a stale bitstream.')
    }
    $head = (git rev-parse --short=8 HEAD).Trim()
    if ($head -ne $sha) {
        Write-Host "note: HEAD is $head; the build is $sha, design unchanged between them."
    }

    # Uncommitted design edits are the other way to build something untracked.
    $dirty = git status --porcelain -- $design
    # build_tag.v is stamped before every compile and is EXPECTED dirty.
    $dirty = $dirty | Where-Object { $_ -notmatch 'rtl/build_tag\.v' }
    if ($dirty) {
        Write-Warning 'Design files are dirty; the archive may not match any commit:'
        $dirty | ForEach-Object { Write-Warning "  $_" }
    }

    foreach ($ext in 'rbf') {
        $src = "output_files/$Revision.$ext"
        if (-not (Test-Path $src)) { Write-Warning "no $src, skipping"; continue }
        $dst = "output_files/${Revision}_${sha}_${Label}.$ext"
        if (Test-Path $dst) { throw "$dst already exists; pick another label" }
        Copy-Item $src $dst
        Write-Host "archived $dst"
    }
} finally { Pop-Location }
