import 'package:flutter/material.dart';
import 'package:saarathi/l10n/app_localizations.dart';

/// Star rating + optional comment, returned to the caller on submit.
class RatingResult {
  const RatingResult(this.stars, this.comment);
  final int stars;
  final String comment;
}

Future<RatingResult?> showRatingSheet(BuildContext context) {
  return showModalBottomSheet<RatingResult>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _RatingSheet(),
  );
}

class _RatingSheet extends StatefulWidget {
  const _RatingSheet();

  @override
  State<_RatingSheet> createState() => _RatingSheetState();
}

class _RatingSheetState extends State<_RatingSheet> {
  int _stars = 5;
  final _comment = TextEditingController();

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 8,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l.rateTrip,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(5, (i) {
              final filled = i < _stars;
              return IconButton(
                iconSize: 40,
                onPressed: () => setState(() => _stars = i + 1),
                icon: Icon(
                  filled ? Icons.star_rounded : Icons.star_outline_rounded,
                  color: filled
                      ? Colors.amber
                      : Theme.of(context).colorScheme.outline,
                ),
              );
            }),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _comment,
            maxLines: 2,
            decoration: InputDecoration(hintText: l.tipOptional),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.pop(
                context, RatingResult(_stars, _comment.text.trim())),
            child: Text(l.submit),
          ),
        ],
      ),
    );
  }
}
