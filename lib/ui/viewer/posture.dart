// A foldable in laptop posture: half open, its hinge across the window.

import 'dart:ui' show DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/widgets.dart';

/// How laptop posture was found.
enum PostureSource { displayFeature, hingeSensor }

/// The hinge across a half-open foldable, in the window's logical pixels,
/// and how it was found; null when the device is not in laptop posture.
///
/// The fold's place and direction come from Android's display features;
/// whether it is half open, from their state or else the hinge sensor's
/// angle (30° to 150°): a Galaxy Z Fold reports its fold as flat at any
/// angle. Laptop posture needs the fold across the window; one down its
/// middle is a book.
(Rect, PostureSource)? laptopHinge(BuildContext context, {double? angle}) {
  final half = angle != null && angle >= 30 && angle <= 150;
  for (final f in MediaQuery.displayFeaturesOf(context)) {
    if (f.type != DisplayFeatureType.hinge && f.type != DisplayFeatureType.fold) continue;
    if (f.bounds.width <= f.bounds.height) continue; // down the window: a book
    if (f.state == DisplayFeatureState.postureHalfOpened) return (f.bounds, PostureSource.displayFeature);
    if (half) return (f.bounds, PostureSource.hingeSensor);
  }
  return null;
}
