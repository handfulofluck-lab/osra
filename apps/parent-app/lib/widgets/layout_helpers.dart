import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_tokens.dart';

/// Formats a device's platform and optional OS version into a clean,
/// human-readable label (for example `Android 14` or `iPhone 17.4`).
/// Returns the version alone or an empty string when [platform] is blank so no
/// untranslated fallback word is introduced in code.
String formatDevicePlatformLabel(String platform, String osVersion) {
  final trimmedPlatform = platform.trim();
  final normalized = trimmedPlatform.toLowerCase();
  final String base;
  if (normalized == 'android') {
    base = 'Android';
  } else if (normalized == 'ios') {
    base = 'iPhone';
  } else {
    base = trimmedPlatform;
  }

  final trimmedVersion = osVersion.trim();
  if (base.isNotEmpty && trimmedVersion.isNotEmpty) {
    return '$base $trimmedVersion';
  }
  if (base.isNotEmpty) {
    return base;
  }
  return trimmedVersion;
}

/// A label/value pair that keeps [label] intact and lays [value] out beside
/// it when space permits, or cleanly wraps [value] onto the next line without
/// using `LayoutBuilder` (safe inside `IntrinsicHeight` and `AlertDialog`).
class LabelValueRow extends StatelessWidget {
  const LabelValueRow({
    super.key,
    required this.label,
    required this.value,
    this.labelStyle,
    this.valueStyle,
    this.gap = AppSpace.md,
    this.onValueTap,
  });

  final String label;
  final String value;
  final TextStyle? labelStyle;
  final TextStyle? valueStyle;
  final double gap;
  final VoidCallback? onValueTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SizedBox(
      width: double.infinity,
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        runAlignment: WrapAlignment.start,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: gap,
        runSpacing: AppSpace.xxs,
        children: [
          Text(
            label,
            style: labelStyle ?? textTheme.bodySmall,
            softWrap: true,
          ),
          onValueTap != null
              ? TextButton(
                  onPressed: onValueTap,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(kMinInteractiveDimension, 48),
                  ),
                  child: Text(value, style: valueStyle),
                )
              : Text(
                  value,
                  style: valueStyle ?? textTheme.bodyMedium,
                ),
        ],
      ),
    );
  }
}

/// Wraps a [TabBar] and fades the leading/trailing edges via [ShaderMask] when
/// horizontal scroll extent remains in that direction, while keeping all tab
/// pointer hit-testing intact.
class FadingScrollableTabBar extends StatefulWidget
    implements PreferredSizeWidget {
  const FadingScrollableTabBar({
    super.key,
    required this.tabBar,
  });

  /// Computes a [Tab] height from the scaled tab label metrics so tabs never
  /// clip vertically at large accessibility text scales (e.g. 200%–310%).
  static double tabHeightFor(BuildContext context, Iterable<String> labels) {
    final theme = Theme.of(context);
    final labelStyle =
        theme.tabBarTheme.labelStyle ?? theme.textTheme.titleSmall;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    double maxTextHeight = 0;
    for (final label in labels) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        maxLines: 1,
        textDirection: direction,
        textScaler: scaler,
      )..layout();
      if (painter.height > maxTextHeight) {
        maxTextHeight = painter.height;
      }
      painter.dispose();
    }
    return math.max(46.0, maxTextHeight + AppSpace.md).ceilToDouble();
  }

  /// Builds [Tab] widgets sized cleanly for the current [MediaQuery.textScalerOf].
  static List<Widget> scaledTabs(BuildContext context, List<String> labels) {
    final height = tabHeightFor(context, labels);
    return [for (final label in labels) Tab(height: height, text: label)];
  }

  final TabBar tabBar;

  @override
  Size get preferredSize => tabBar.preferredSize;

  @override
  State<FadingScrollableTabBar> createState() => _FadingScrollableTabBarState();
}

class _FadingScrollableTabBarState extends State<FadingScrollableTabBar> {
  bool _showStartFade = false;
  bool _showEndFade = false;

  @override
  void initState() {
    super.initState();
    if (widget.tabBar.isScrollable) {
      _scheduleInspectScrollable();
    }
  }

  @override
  void didUpdateWidget(covariant FadingScrollableTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.tabBar.isScrollable) {
      _showStartFade = false;
      _showEndFade = false;
    } else if (widget.tabBar != oldWidget.tabBar) {
      _scheduleInspectScrollable();
    }
  }

  void _scheduleInspectScrollable() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _inspectScrollable();
    });
  }

  void _inspectScrollable() {
    ScrollableState? found;
    void visitor(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is ScrollableState) {
        found = element.state as ScrollableState;
        return;
      }
      element.visitChildren(visitor);
    }

    context.visitChildElements(visitor);
    final position = found?.position;
    if (position != null && position.hasContentDimensions) {
      _updateFromMetrics(position);
    }
  }

  void _updateFromMetrics(ScrollMetrics metrics) {
    if (metrics.axis != Axis.horizontal) return;
    final nextStart = metrics.extentBefore > 0.5;
    final nextEnd = metrics.extentAfter > 0.5;
    if (nextStart == _showStartFade && nextEnd == _showEndFade) return;
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (nextStart != _showStartFade || nextEnd != _showEndFade) {
          setState(() {
            _showStartFade = nextStart;
            _showEndFade = nextEnd;
          });
        }
      });
    } else {
      setState(() {
        _showStartFade = nextStart;
        _showEndFade = nextEnd;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final textDirection = Directionality.of(context);
    Widget content = widget.tabBar;
    if (_showStartFade || _showEndFade) {
      final colors = <Color>[
        if (_showStartFade) Colors.transparent else Colors.white,
        Colors.white,
        Colors.white,
        if (_showEndFade) Colors.transparent else Colors.white,
      ];
      const stops = <double>[0.0, 0.10, 0.90, 1.0];
      content = ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => LinearGradient(
          begin: AlignmentDirectional.centerStart,
          end: AlignmentDirectional.centerEnd,
          colors: colors,
          stops: stops,
        ).createShader(bounds, textDirection: textDirection),
        child: content,
      );
    }

    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        _updateFromMetrics(notification.metrics);
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          _updateFromMetrics(notification.metrics);
          return false;
        },
        child: content,
      ),
    );
  }
}
