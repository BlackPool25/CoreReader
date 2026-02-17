import 'package:flutter/material.dart';

import '../services/local_store.dart';
import '../widgets/app_settings_scope.dart';
import '../widgets/library_scope.dart';
import 'novel_detail_screen.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  int _gridCountForWidth(BuildContext context, double w) {
    // User preference for phone-sized layouts.
    if (w < 600) {
      return AppSettingsScope.of(context).libraryGridColumns;
    }
    if (w >= 1100) return 6;
    if (w >= 900) return 5;
    if (w >= 700) return 4;
    if (w >= 520) return 3;
    return 2;
  }

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final novels = library.novels;

    if (novels.isEmpty) {
      return const Center(
        child: Text('No novels yet. Use “Add novel” to get started.'),
      );
    }

    return LayoutBuilder(
      builder: (context, c) {
        final crossAxisCount = _gridCountForWidth(context, c.maxWidth);
        final isPhone = c.maxWidth < 600;
        final settings = AppSettingsScope.of(context);
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: isPhone
              ? SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  // Fit an RxC matrix in the visible viewport for phone layouts.
                  // (If there are fewer than R*C novels, it will show fewer tiles.)
                  mainAxisExtent: () {
                    final rows = settings.libraryGridRows;
                    final availableH = (c.maxHeight - 32).clamp(0.0, double.infinity);
                    final extent = (availableH - 12.0 * (rows - 1)) / rows;
                    return extent.clamp(96.0, 220.0);
                  }(),
                )
              : SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.6,
                ),
          itemCount: novels.length,
          itemBuilder: (context, i) {
            final n = novels[i];
            return _NovelCard(novel: n);
          },
        );
      },
    );
  }
}

class _NovelCard extends StatelessWidget {
  const _NovelCard({required this.novel});

  final StoredNovel novel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final library = LibraryScope.of(context);
    final progress = library.progressFor(novel.id);
    final subtitle = progress == null
        ? 'Not started'
        : 'Continue: Chapter ${progress.chapterN}';

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => NovelDetailScreen(novel: novel),
          ),
        );
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                novel.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
