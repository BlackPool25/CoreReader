import 'package:flutter/material.dart';

class HighlightInParagraph extends StatelessWidget {
  const HighlightInParagraph({
    super.key,
    required this.paragraph,
    required this.highlight,
    required this.fontSize,
  });

  final String paragraph;
  final String highlight;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
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
