# 查看上次推送提交的 diff（用于排查卡顿/目录问题）
$g = 'C:\Program Files\Git\bin\git.exe'
& $g -C d:\gz\midu diff 5954ace^ 5954ace -- lib/book_sources/services/book_source_health_service.dart lib/book_sources/legado/legado_source_verifier.dart lib/book_sources/services/book_source_client.dart lib/book_sources/services/book_source_chapter_text.dart lib/book_sources/services/book_source_network_policy.dart