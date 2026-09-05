Set-Location -Path 'd:\gz\midu'
D:\flutter\bin\flutter.bat analyze lib/pages/book_sources/book_sources_page.dart 2>&1 | Out-File -FilePath 'd:\gz\midu\tool\out\analyze_stream.log' -Encoding utf8
exit $LASTEXITCODE