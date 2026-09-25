import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'sources.dart';
import 'tv.dart';
import 'ui.dart';

const _success = Color(0xFF4ADE80);

/// Turns exceptions into short messages people can act on.
String friendlyError(Object error) => switch (error) {
  CloudflareChallenge() =>
    'This site needs a quick verification before it can be reached',
  SocketException() ||
  HandshakeException() ||
  http.ClientException() => 'No connection. Check your internet and try again',
  TimeoutException() => 'The site took too long to respond',
  HttpException(:final message) => 'The site returned an error ($message)',
  FormatException() =>
    'The site sent something unexpected. It may have changed its layout',
  _ => '$error'.replaceFirst('Exception: ', ''),
};

/// A bottom sheet on phones; on TV a panel in the middle of the screen, since a sheet from the bottom
/// edge is a touch idiom. [height] fixes a phone sheet at that share of the screen below the status bar.
Future<T?> showSheet<T>(
  BuildContext context,
  WidgetBuilder builder, {
  bool scrollControlled = false,
  double? height,
}) => isTv
    ? showDialog<T>(
        context: context,
        builder: (context) => PanelDialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.only(top: 24, bottom: 8),
              child: builder(context),
            ),
          ),
        ),
      )
    : showModalBottomSheet<T>(
        context: context,
        isScrollControlled: scrollControlled || height != null,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        showDragHandle: false, // drawn on the panel below
        builder: (context) {
          final screen = MediaQuery.sizeOf(context).height;
          final sheet = Panel(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(nested(24)),
              ),
            ),
            color: scheme.surfaceContainerLow,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 16),
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: scheme.onSurfaceVariant.withValues(alpha: .4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                if (height != null)
                  Expanded(child: builder(context))
                else
                  Flexible(child: builder(context)),
              ],
            ),
          );
          return height == null
              ? sheet
              : SizedBox(height: screen * height, child: sheet);
        },
      );

void showSuccess(BuildContext context, String message) =>
    _snack(context, message, Icons.check_circle_rounded, _success);

void showError(BuildContext context, Object error) => _snack(
  context,
  friendlyError(error),
  Icons.error_rounded,
  scheme.errorContainer,
);

void _snack(BuildContext context, String message, IconData icon, Color color) =>
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(icon, color: color == _success ? _success : scheme.error),
              const SizedBox(width: 12),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      );

/// A placeholder block that pulses gently while content loads.
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    this.width,
    this.height,
    this.radius = radiusLarge,
  });

  final double? width, height;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    // Still, with animations turned off in the system settings.
    opacity: MediaQuery.disableAnimationsOf(context)
        ? const AlwaysStoppedAnimation(.7)
        : Tween(begin: .45, end: 1.0).animate(_controller),
    child: Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(widget.radius),
      ),
    ),
  );
}

class ErrorState extends StatelessWidget {
  const ErrorState(this.error, {super.key, this.onRetry, this.compact = false});

  final Object error;
  final VoidCallback? onRetry;
  final bool compact;

  String get _retryLabel =>
      error is CloudflareChallenge ? 'Verify' : 'Try again';

  @override
  Widget build(BuildContext context) {
    final message = friendlyError(error);
    if (compact) {
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: side, vertical: 8),
        child: Material(
          color: scheme.errorContainer.withValues(alpha: .35),
          borderRadius: BorderRadius.circular(nested(8)), // its button's inset
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                Icon(Icons.error_outline_rounded, color: scheme.error),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    message,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                if (onRetry != null)
                  TextButton(onPressed: onRetry, child: Text(_retryLabel)),
              ],
            ),
          ),
        ),
      );
    }
    return EmptyState(
      icon: Icons.cloud_off_rounded,
      title: 'Something went wrong',
      message: message,
      error: true,
      action: onRetry == null
          ? null
          : FilledButton.tonalIcon(
              autofocus: isTv,
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(_retryLabel),
            ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.compact = false,
    this.error = false,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final bool compact, error;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final body = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 48,
            color: error ? scheme.error : scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(title, textAlign: TextAlign.center, style: text.titleMedium),
          if (message != null) ...[
            const SizedBox(height: 8),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 24), action!],
        ],
      ),
    );
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: side * 2,
        vertical: compact ? 24 : 32,
      ),
      child: Center(child: body),
    );
  }
}
