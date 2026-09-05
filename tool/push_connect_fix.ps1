Set-Location -Path 'd:\gz\midu'
$git = 'C:\Program Files\Git\bin\git.exe'
if (-not (Test-Path $git)) { throw "git not found" }
& $git add lib/pages/book_sources/book_sources_page.dart test/book_source_search_scope_test.dart
if ($LASTEXITCODE -ne 0) { Write-Host 'ADD_FAILED'; exit $LASTEXITCODE }
& $git commit -m "perf(discover): rate-limit discovery source parsing to remove bg refresh jank"
if ($LASTEXITCODE -ne 0) { Write-Host 'COMMIT_FAILED'; exit $LASTEXITCODE }
& $git push origin main
exit $LASTEXITCODE