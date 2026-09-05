Set-Location -Path 'd:\gz\midu'
$git = 'C:\Program Files\Git\bin\git.exe'
if (-not (Test-Path $git)) { throw "git not found at $git" }
Write-Output '=== commit 91e2e1a (latest) ==='
& $git show --stat --oneline 91e2e1a
Write-Output '=== commit 33eb668 ==='
& $git show --stat --oneline 33eb668
Write-Output '=== my working changes ==='
& $git diff --stat
exit 0