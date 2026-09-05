Set-Location -Path 'd:\gz\midu'
$git = 'C:\Program Files\Git\bin\git.exe'
if (-not (Test-Path $git)) { throw "git not found at $git" }
& $git add lib/book_sources/legado/legado_runtime.dart
if ($LASTEXITCODE -ne 0) { Write-Output 'ADD_FAILED'; exit $LASTEXITCODE }
& $git commit -m 'fix(book-source): 修复zzs5系公告混排目录乱序与目录翻页空转卡顿'
if ($LASTEXITCODE -ne 0) { Write-Output 'COMMIT_FAILED'; exit $LASTEXITCODE }
& $git push origin main
exit $LASTEXITCODE