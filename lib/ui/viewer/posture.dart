// A foldable in laptop posture: half open, its hinge across the window.

import 'dart:ui' show DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/widgets.dart';

/// How laptop posture was found.
enum PostureSource { displayFeature, hingeSensor }

/// The hinge across a half-open foldable, in the window's logical pixels,
/// and how it was found; null when the device is not in laptop posture.
///
/// Android's display features say it first (a hinge or fold, half open, as
/// wide as the window). Some devices report them late or not at all: then
/// the hinge sensor's angle between 30° and 150° on a large window wider
/// than tall means the same, the hinge across its middle.
(Rect, PostureSource)? laptopHinge(BuildContext context, {double? angle}) {
  for (final f in MediaQuery.displayFeaturesOf(context)) {
    final across = f.bounds.width > f.bounds.height;
    if ((f.type == DisplayFeatureType.hinge || f.type == DisplayFeatureType.fold) &&
        f.state == DisplayFeatureState.postureHalfOpened &&
        across) {
      return (f.bounds, PostureSource.displayFeature);
    }
  }
  final size = MediaQuery.sizeOf(context);
  if (angle != null && angle >= 30 && angle <= 150 && size.width > size.height && size.shortestSide >= 500) {
    return (Rect.fromLTWH(0, size.height / 2, size.width, 0), PostureSource.hingeSensor);
  }
  return null;
}
