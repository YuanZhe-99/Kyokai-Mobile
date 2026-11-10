// The trackpad cursor's size: a slider with the ring itself as preview,
// over a dark patch like a remote screen, and the smallest, middle and
// largest rings under the slider's start, middle and end for reference.

import 'package:flutter/material.dart';

import '../../data/prefs.dart';
import '../shell/app.dart';
import '../viewer/surface.dart';

class CursorSizeTile extends StatelessWidget {
  const CursorSizeTile({super.key, required this.prefs});
  final Prefs prefs;

  static const _min = Prefs.cursorMin;
  static const _max = Prefs.cursorMax;
  static const _mid = (_min + _max) / 2;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final size = prefs.cursorSize.clamp(_min, _max);
    // Room for the largest ring and its glow, so nothing moves as it grows.
    const box = _max + 10;

    Widget sample(double s) => SizedBox(
      width: box,
      height: box,
      child: Center(child: CursorRing(size: s)),
    );

    return ListTile(
      title: Text(l.cursorSize),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Slider(
                  min: _min,
                  max: _max,
                  divisions: ((_max - _min) / 2).round(),
                  value: size,
                  label: '${size.round()}',
                  onChanged: (v) => prefs.cursorSize = v,
                ),
              ),
              // The ring as it will look over a remote screen.
              Container(
                key: const ValueKey('cursorPreview'),
                width: 72,
                height: 56,
                decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(10)),
                child: Center(child: CursorRing(size: size)),
              ),
            ],
          ),
          // Under the slider's start, middle and end: tap one to take it.
          Padding(
            padding: const EdgeInsets.only(right: 72),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final s in const [_min, _mid, _max])
                  InkWell(
                    key: ValueKey('cursorRef$s'),
                    customBorder: const CircleBorder(),
                    onTap: () => prefs.cursorSize = s,
                    child: sample(s),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
