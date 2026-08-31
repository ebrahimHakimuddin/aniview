import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'sources.dart';

const _danger = Color(0xFFFF8A8E);
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

void showSuccess(BuildContext context, String message) =>
    _snack(context, message, Icons.check_circle_rounded, _success);

void showError(BuildContext context, Object error) =>
    _snack(context, friendlyError(error), Icons.error_rounded, _danger);

void _snack(BuildContext context, String message, IconData icon, Color color) =>
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF1C1C26),
          content: Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      );

/// Shimmering placeholder block.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.width, this.height, this.radius = 12});

  final double? width, height;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) {
      final t = _controller.value * 1.6 - .3;
      return Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          gradient: LinearGradient(
            colors: const [
              Color(0xFF16161F),
              Color(0xFF252532),
              Color(0xFF16161F),
            ],
            stops: [
              (t - .3).clamp(0.0, 1.0),
              t.clamp(0.0, 1.0),
              (t + .3).clamp(0.0, 1.0),
            ],
          ),
        ),
      );
    },
  );
}

class PosterSkeleton extends StatelessWidget {
  const PosterSkeleton({super.key});

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      AspectRatio(aspectRatio: 2 / 3, child: Skeleton(radius: 14)),
      SizedBox(height: 10),
      Skeleton(height: 12, width: 110, radius: 6),
      SizedBox(height: 6),
      Skeleton(height: 10, width: 64, radius: 6),
    ],
  );
}

class ShelfSkeleton extends StatelessWidget {
  const ShelfSkeleton({super.key, this.title});

  final String? title;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
        child: title == null
            ? const Skeleton(width: 150, height: 18, radius: 6)
            : Text(
                title!,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
      ),
      SizedBox(
        height: 272,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          itemCount: 5,
          separatorBuilder: (_, _) => const SizedBox(width: 14),
          itemBuilder: (_, _) =>
              const SizedBox(width: 136, child: PosterSkeleton()),
        ),
      ),
    ],
  );
}

class EpisodeSkeleton extends StatelessWidget {
  const EpisodeSkeleton({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
    child: Row(
      children: [
        Skeleton(width: 128, height: 72, radius: 10),
        SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Skeleton(height: 14, width: 110, radius: 6),
              SizedBox(height: 8),
              Skeleton(height: 11, radius: 6),
            ],
          ),
        ),
      ],
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
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        decoration: BoxDecoration(
          color: _danger.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _danger.withValues(alpha: .2)),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline_rounded, color: _danger, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontSize: 13, color: Colors.white70),
              ),
            ),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: Text(_retryLabel)),
          ],
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Badge(icon: Icons.cloud_off_rounded, color: _danger),
            const SizedBox(height: 16),
            const Text(
              'Something went wrong',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60, height: 1.4),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 20),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(_retryLabel),
              ),
            ],
          ],
        ),
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
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Badge(icon: icon, color: color),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        if (message != null) ...[
          const SizedBox(height: 6),
          Text(
            message!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white60, height: 1.4),
          ),
        ],
        if (action != null) ...[const SizedBox(height: 20), action!],
      ],
    );
    return compact
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: body,
          )
        : Center(
            child: Padding(padding: const EdgeInsets.all(32), child: body),
          );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: color.withValues(alpha: .1),
    ),
    child: Icon(icon, size: 34, color: color),
  );
}
