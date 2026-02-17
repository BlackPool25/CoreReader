import 'dart:collection';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

class NovelIndex {
  NovelIndex({required this.novelUrl, required this.chapterUrls});

  final String novelUrl;
  final List<String> chapterUrls;

  int get count => chapterUrls.length;

  String? urlForChapterNum(int n) {
    if (n < 1 || n > chapterUrls.length) return null;
    return chapterUrls[n - 1];
  }
}

class NovelIndexResolver {
  static const _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0 Safari/537.36'
  };

  final _cache = HashMap<String, NovelIndex>();

  NovelIndex? getCached(String novelUrl) => _cache[novelUrl];

  Future<NovelIndex> load(String novelUrl) async {
    final existing = _cache[novelUrl];
    if (existing != null) return existing;

    final res = await http.get(Uri.parse(novelUrl), headers: _headers);
    if (res.statusCode != 200) {
      throw Exception('Failed to fetch novel page: ${res.statusCode}');
    }

    final doc = html_parser.parse(res.body);
    final seen = HashSet<String>();
    final urls = <String>[];

    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href'];
      if (href == null || !href.contains('/chapter/')) continue;
      final abs = Uri.parse(novelUrl).resolve(href).toString();
      if (!seen.add(abs)) continue;
      urls.add(abs);
    }

    // Best-effort sort: many NovelCool chapter URLs include "Chapter-<n>".
    int keyOf(String url) {
      final m = RegExp(r'Chapter-(\d+)', caseSensitive: false).firstMatch(url);
      if (m != null) {
        return int.tryParse(m.group(1) ?? '') ?? (1 << 30);
      }
      return 1 << 30;
    }

    urls.sort((a, b) => keyOf(a).compareTo(keyOf(b)));

    final idx = NovelIndex(novelUrl: novelUrl, chapterUrls: List.unmodifiable(urls));
    _cache[novelUrl] = idx;
    return idx;
  }
}
