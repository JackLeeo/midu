param([string]$TestFile = 'test/probe_agg_search_count_test.dart')
Set-Location -Path 'd:\gz\midu'
Remove-Item Env:FILTER_SRC -ErrorAction SilentlyContinue
Remove-Item Env:BOOK_SOURCE_PROXY -ErrorAction SilentlyContinue
Remove-Item Env:VERIFY_SOURCES -ErrorAction SilentlyContinue
D:\flutter\bin\flutter.bat test $TestFile -j 1 2>&1 | Out-File -FilePath 'd:\gz\midu\tool\out\agg_search_count.log' -Encoding utf8
exit $LASTEXITCODE