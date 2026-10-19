import '../l10n/app_strings.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'remote_view_memory.dart';

/// Only the panel intercepts input. The rest of the remote surface stays live.
class FloatingControls extends StatefulWidget {
  const FloatingControls({
    super.key,
    required this.memory,
    required this.title,
    required this.actions,
  });
  final RemoteViewMemory memory;
  final String title;
  final List<Widget> actions;
  @override
  State<FloatingControls> createState() => _FloatingControlsState();
}

class _FloatingControlsState extends State<FloatingControls> {
  final _panel = GlobalKey();
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final safe = MediaQuery.paddingOf(context);
      final collapsed = widget.memory.controlsCollapsed;
      final available = Size(
        math.max(0, bounds.maxWidth - safe.horizontal - 16),
        math.max(0, bounds.maxHeight - safe.vertical - 16),
      );
      final width = math.min(collapsed ? 56.0 : 340.0, available.width);
      final position = widget.memory.controlsPosition;
      void drag(DragUpdateDetails details) => setState(() {
        final size =
            (_panel.currentContext!.findRenderObject() as RenderBox).size;
        final xSpace = math.max(0.0, available.width - size.width);
        final ySpace = math.max(0.0, available.height - size.height);
        final current = widget.memory.controlsPosition;
        widget.memory.controlsPosition = Offset(
          xSpace == 0
              ? 0
              : (current.dx + details.delta.dx / xSpace).clamp(0, 1),
          ySpace == 0
              ? 0
              : (current.dy + details.delta.dy / ySpace).clamp(0, 1),
        );
      });
      return CustomSingleChildLayout(
        delegate: _PanelLayout(position, safe, width),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: available.height),
          child: Material(
            key: _panel,
            elevation: 8,
            clipBehavior: Clip.antiAlias,
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(collapsed ? 28 : 18),
            child: collapsed
                ? GestureDetector(
                    onPanUpdate: drag,
                    child: IconButton(
                      key: const Key('expandSessionControls'),
                      tooltip: context.tr("展开会话工具"),
                      icon: const Icon(Icons.tune),
                      constraints: const BoxConstraints(
                        minWidth: 56,
                        minHeight: 56,
                      ),
                      onPressed: () => setState(
                        () => widget.memory.controlsCollapsed = false,
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanUpdate: drag,
                          child: SizedBox(
                            height: 52,
                            child: Row(
                              children: [
                                const SizedBox(width: 12),
                                const Icon(Icons.drag_indicator, size: 20),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    widget.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                IconButton(
                                  key: const Key('collapseSessionControls'),
                                  tooltip: context.tr("收起会话工具"),
                                  icon: const Icon(Icons.keyboard_arrow_up),
                                  onPressed: () => setState(
                                    () =>
                                        widget.memory.controlsCollapsed = true,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.all(6),
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            children: widget.actions,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      );
    },
  );
}

class _PanelLayout extends SingleChildLayoutDelegate {
  _PanelLayout(this.position, this.safe, this.width);
  final Offset position;
  final EdgeInsets safe;
  final double width;
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.tightFor(width: width).copyWith(
        minHeight: 0,
        maxHeight: math.max(0, constraints.maxHeight - safe.vertical - 16),
      );
  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    safe.left +
        8 +
        math.max(0, size.width - safe.horizontal - 16 - childSize.width) *
            position.dx,
    safe.top +
        8 +
        math.max(0, size.height - safe.vertical - 16 - childSize.height) *
            position.dy,
  );
  @override
  bool shouldRelayout(_PanelLayout old) =>
      old.position != position || old.safe != safe || old.width != width;
}
