import 'package:flutter/material.dart';

class MenuTracker {
  static final List<MenuController> _controllers = [];

  static void register(MenuController controller) {
    if (!_controllers.contains(controller)) {
      _controllers.add(controller);
    }
  }

  static void unregister(MenuController controller) {
    _controllers.remove(controller);
  }

  static bool closeAnyOpenMenu() {
    bool closedAny = false;
    for (var controller in _controllers.reversed) {
      if (controller.isOpen) {
        controller.close();
        closedAny = true;
      }
    }
    return closedAny;
  }
}

class TrackedDropdownMenu<T> extends StatefulWidget {
  final EdgeInsetsGeometry? expandedInsets;
  final Widget? label;
  final InputDecorationTheme? inputDecorationTheme;
  final T? initialSelection;
  final bool enabled;
  final List<DropdownMenuEntry<T>> dropdownMenuEntries;
  final ValueChanged<T?>? onSelected;

  const TrackedDropdownMenu({
    super.key,
    this.expandedInsets,
    this.label,
    this.inputDecorationTheme,
    this.initialSelection,
    this.enabled = true,
    required this.dropdownMenuEntries,
    this.onSelected,
  });

  @override
  State<TrackedDropdownMenu<T>> createState() => _TrackedDropdownMenuState<T>();
}

class _TrackedDropdownMenuState<T> extends State<TrackedDropdownMenu<T>> {
  final MenuController _controller = MenuController();
  final GlobalKey _key = GlobalKey();
  double _maxMenuHeight = 300;

  @override
  void initState() {
    super.initState();
    MenuTracker.register(_controller);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateMaxHeight());
  }

  @override
  void didUpdateWidget(TrackedDropdownMenu<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateMaxHeight());
  }

  void _updateMaxHeight() {
    final ctx = _key.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;

    final position = box.localToGlobal(Offset.zero);
    final mq = MediaQuery.of(ctx);
    final bottomOfWidget = position.dy + box.size.height;
    final available =
        mq.size.height -
        bottomOfWidget -
        mq.viewInsets.bottom -
        mq.padding.bottom -
        8;

    if (mounted) {
      final newHeight = available > 50 ? available : 50.0;
      if ((_maxMenuHeight - newHeight).abs() > 1.0) {
        setState(() {
          _maxMenuHeight = newHeight;
        });
      }
    }
  }

  @override
  void dispose() {
    MenuTracker.unregister(_controller);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _updateMaxHeight(),
      behavior: HitTestBehavior.translucent,
      child: DropdownMenu<T>(
        key: _key,
        menuController: _controller,
        expandedInsets: widget.expandedInsets,
        label: widget.label,
        inputDecorationTheme: widget.inputDecorationTheme,
        initialSelection: widget.initialSelection,
        enabled: widget.enabled,
        dropdownMenuEntries: widget.dropdownMenuEntries,
        onSelected: widget.onSelected,
        menuStyle: MenuStyle(
          alignment: AlignmentDirectional.bottomStart,
          maximumSize: WidgetStatePropertyAll(
            Size(double.infinity, _maxMenuHeight),
          ),
        ),
      ),
    );
  }
}
