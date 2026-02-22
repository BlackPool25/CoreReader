import 'package:flutter/material.dart';

class HighlightInParagraph extends StatelessWidget {
  const HighlightInParagraph({
    super.key,
    required this.paragraph,
    required this.highlight,
    this.highlightStart,
    this.highlightEnd,
    required this.fontSize,
  });

  final String paragraph;
  final String highlight;
  final int? highlightStart;
  final int? highlightEnd;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (paragraph.isEmpty) {
      return Text(paragraph, style: TextStyle(fontSize: fontSize));
    }

    // Preferred: highlight by explicit char range.
    final hs = highlightStart;
    final he = highlightEnd;
    if (hs != null && he != null && hs >= 0 && he > hs && he <= paragraph.length) {
      final before = paragraph.substring(0, hs);
      final mid = paragraph.substring(hs, he);
      final after = paragraph.substring(he);
      return RichText(
        text: TextSpan(
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: fontSize),
          children: [
            TextSpan(text: before),
            TextSpan(
              text: mid,
              style: TextStyle(
                backgroundColor: cs.primaryContainer,
                color: cs.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(text: after),
          ],
        ),
      );
    }

    // Fallback: old behavior (string match).
    if (highlight.isEmpty) {
      return Text(paragraph, style: TextStyle(fontSize: fontSize));
    }

    final idx = paragraph.indexOf(highlight);
    if (idx < 0) {
      return Text(paragraph, style: TextStyle(fontSize: fontSize));
    }

    final before = paragraph.substring(0, idx);
    final mid = paragraph.substring(idx, idx + highlight.length);
    final after = paragraph.substring(idx + highlight.length);

    return RichText(
      text: TextSpan(
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: fontSize),
        children: [
          TextSpan(text: before),
          TextSpan(
            text: mid,
            style: TextStyle(
              backgroundColor: cs.primaryContainer,
              color: cs.onPrimaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(text: after),
        ],
      ),
    );
  }
}
