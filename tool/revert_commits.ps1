Set-Location -Path 'd:\gz\midu'
$git = 'C:\Program Files\Git\bin\git.exe'
if (-not (Test-Path $git)) { throw "git not found at $git" }
# 仅回退发现页并发限流 91e2e1a，保留目录修复 33eb668
& $git revert --no-edit 91e2e1a
if ($LASTEXITCODE -ne 0) { Write-Host 'REVERT_FAILED'; exit $LASTEXITCODE }
Write-Output '=== post-revert log ==='
& $git log --oneline -3
Write-Output '=== status ==='
& $git status --short
exit 0