library;

import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart';

import 'bloc/pagination_cubit.dart';
import 'bloc/pagination_listeners.dart';
import 'widgets/bottom_loader.dart';
import 'widgets/empty_display.dart';
import 'widgets/empty_separator.dart';
import 'widgets/error_display.dart';
import 'widgets/initial_loader.dart';

class PaginateFirestore extends StatefulWidget {
  const PaginateFirestore({
    super.key,
    required this.itemBuilder,
    required this.query,
    required this.itemBuilderType,
    this.gridDelegate =
        const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2),
    this.startAfterDocument,
    this.itemsPerPage = 15,
    this.itemsGlobalLimit,
    this.onError,
    this.onReachedEnd,
    this.onLoaded,
    this.onEmpty = const EmptyDisplay(),
    this.separator = const EmptySeparator(),
    this.initialLoader = const InitialLoader(),
    this.bottomLoader = const BottomLoader(),
    this.loadMoreLabel = 'Load more',
    this.shrinkWrap = false,
    this.reverse = false,
    this.scrollDirection = Axis.vertical,
    this.padding = const EdgeInsets.all(0),
    this.physics,
    this.listeners,
    this.scrollController,
    this.allowImplicitScrolling = false,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
    this.pageController,
    this.onPageChanged,
    this.header,
    this.footer,
    this.isLive = false,
    this.isAllItemsLive = true,
    this.includeMetadataChanges = false,
    this.options,
  })  : assert(itemsPerPage > 0),
        assert(itemsGlobalLimit == null || itemsGlobalLimit >= 0);

  final Widget bottomLoader;

  /// Label for the manual loading button. Pass your app's localized string.
  final String loadMoreLabel;

  final Widget onEmpty;
  final SliverGridDelegate gridDelegate;
  final Widget initialLoader;
  final PaginateBuilderType itemBuilderType;
  final int itemsPerPage;
  final List<ChangeNotifier>? listeners;
  final EdgeInsets padding;
  final ScrollPhysics? physics;
  final Query query;
  final bool reverse;
  final bool allowImplicitScrolling;
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;
  final ScrollController? scrollController;
  final PageController? pageController;
  final Axis scrollDirection;
  final Widget separator;
  final bool shrinkWrap;
  final bool isLive;
  final DocumentSnapshot? startAfterDocument;
  final Widget? header;
  final Widget? footer;

  /// Maximum document slots requested across pages, including the first page.
  /// The final query is limited to the remaining allowance. Zero issues no reads.
  /// This does not cap reads billed for live updates, reconnects, or refreshes.
  final int? itemsGlobalLimit;

  /// Use this only if `isLive = true`
  /// If true (the default), each fetched page has a live listener.
  /// If false, only the first page is live; later pages use one-time reads.
  /// Pages have fixed start cursors and limits. Inserts, deletes, or changes to
  /// sort fields can move documents between pages; refresh to reconcile them.
  /// Larger pages reduce listener count but can read more unseen documents.
  final bool isAllItemsLive;

  /// Options for one-time reads, including later pages when only page one is live.
  final GetOptions? options;

  /// Use this only if `isLive = true`
  final bool includeMetadataChanges;

  final Widget Function(Exception)? onError;

  final Widget Function(BuildContext, List<DocumentSnapshot>, int) itemBuilder;

  final void Function(PaginationLoaded)? onReachedEnd;

  final void Function(PaginationLoaded)? onLoaded;

  final void Function(int)? onPageChanged;

  @override
  State<PaginateFirestore> createState() => _PaginateFirestoreState();
}

class _PaginateFirestoreState extends State<PaginateFirestore> {
  PaginationCubit? _cubit;
  Future<void>? _nextPageRequest;
  // A visible loader may prefetch one page per session or user scroll. Rebuilds,
  // filtered-out results and live events must not replenish this allowance.
  bool _automaticFetchAllowed = true;
  List<ChangeNotifier> _attachedListeners = [];

  @override
  Widget build(BuildContext context) {
    return NotificationListener<UserScrollNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 &&
            notification.direction != ScrollDirection.idle &&
            !_automaticFetchAllowed) {
          _automaticFetchAllowed = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        }
        return false;
      },
      child: BlocConsumer<PaginationCubit, PaginationState>(
        bloc: _cubit,
        buildWhen: (prev, curr) => prev != curr,
        listener: (context, state) {
          if (state is PaginationInitial) {
            // A previous one-time read may still be in flight. It must not
            // block the loader in the refreshed pagination session.
            _nextPageRequest = null;
            _automaticFetchAllowed = true;
          }
          if (state is PaginationError) {
            // A successful explicit retry restores pages, but does not grant
            // an additional automatic fetch beyond the failed request.
            _automaticFetchAllowed = false;
          }
          if (state is PaginationLoaded) {
            widget.onLoaded?.call(state);
            if (state.hasReachedEnd) widget.onReachedEnd?.call(state);
          }
        },
        builder: (context, state) {
          if (state is PaginationInitial) {
            return widget.initialLoader;
          } else if (state is PaginationError) {
            return (widget.onError != null)
                ? widget.onError!(state.error)
                : ErrorDisplay(exception: state.error);
          } else {
            final loadedState = state as PaginationLoaded;
            if (loadedState.documentSnapshots.isEmpty) {
              return widget.onEmpty;
            }
            return widget.itemBuilderType == PaginateBuilderType.listView
                ? _buildListView(loadedState)
                : widget.itemBuilderType == PaginateBuilderType.gridView
                    ? _buildGridView(loadedState)
                    : _buildPageView(loadedState);
          }
        },
      ),
    );
  }

  @override
  void dispose() {
    for (var remove in _listenerRemovers) {
      remove();
    }
    _cubit?.close();
    super.dispose();
  }

  final _listenerRemovers = <VoidCallback>[];

  @override
  void initState() {
    super.initState();
    _createCubit();
    _attachListeners();
  }

  @override
  void didUpdateWidget(covariant PaginateFirestore oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldOptions = oldWidget.options ?? const GetOptions();
    final newOptions = widget.options ?? const GetOptions();
    final usesOneTimeReads = !widget.isLive || !widget.isAllItemsLive;
    var restarted = false;
    if (oldWidget.query != widget.query ||
        oldWidget.itemsPerPage != widget.itemsPerPage ||
        oldWidget.itemsGlobalLimit != widget.itemsGlobalLimit ||
        !_hasSameStartCursor(oldWidget) ||
        oldWidget.isLive != widget.isLive ||
        (widget.isLive && oldWidget.isAllItemsLive != widget.isAllItemsLive) ||
        (usesOneTimeReads &&
            (oldOptions.source != newOptions.source ||
                oldOptions.serverTimestampBehavior !=
                    newOptions.serverTimestampBehavior))) {
      _cubit?.close();
      _createCubit();
      restarted = true;
    }
    _cubit?.updateMetadataChanges(widget.includeMetadataChanges);
    if (restarted || !listEquals(_attachedListeners, widget.listeners ?? [])) {
      for (final remove in _listenerRemovers) {
        remove();
      }
      _listenerRemovers.clear();
      _attachListeners();
    }
  }

  bool _hasSameStartCursor(PaginateFirestore oldWidget) {
    final oldCursor = oldWidget.startAfterDocument;
    final newCursor = widget.startAfterDocument;
    if (identical(oldCursor, newCursor)) return true;
    if (oldCursor == null || newCursor == null) return false;
    try {
      // Query equality compares the document path and ordered cursor values.
      // Snapshot identity and changes to unrelated fields do not affect it.
      return oldWidget.query.startAfterDocument(oldCursor) ==
          widget.query.startAfterDocument(newCursor);
    } catch (_) {
      // Let the cubit report invalid cursors through the normal error state.
      return false;
    }
  }

  void _attachListeners() {
    _attachedListeners = List.of(widget.listeners ?? []);
    var initialFilter = '';
    for (var listener in _attachedListeners) {
      VoidCallback remover = () {};
      if (listener is PaginateRefreshedChangeListener) {
        void fn() {
          if (listener.refreshed) {
            _cubit?.refreshPaginatedList();
          }
        }

        listener.addListener(fn);
        remover = () => listener.removeListener(fn);
      } else if (listener is PaginateRetryChangeListener) {
        void fn() {
          _cubit?.retryPaginatedList();
        }

        listener.addListener(fn);
        remover = () => listener.removeListener(fn);
      } else if (listener is PaginateFilterChangeListener) {
        void fn() {
          _cubit?.filterPaginatedList(listener.searchTerm);
        }

        listener.addListener(fn);
        initialFilter = listener.searchTerm;
        remover = () => listener.removeListener(fn);
      }
      _listenerRemovers.add(remover);
    }
    _cubit?.filterPaginatedList(initialFilter);
  }

  void _createCubit() {
    _nextPageRequest = null;
    _automaticFetchAllowed = true;
    _cubit = PaginationCubit(
      widget.query,
      widget.itemsPerPage,
      widget.startAfterDocument,
      isLive: widget.isLive,
      isAllItemsLive: widget.isAllItemsLive,
      itemsGlobalLimit: widget.itemsGlobalLimit,
      includeMetadataChanges: widget.includeMetadataChanges,
      options: widget.options,
    )..fetchPaginatedList();
  }

  void _fetchNextPage() {
    if (_nextPageRequest != null || !_automaticFetchAllowed) return;
    final cubit = _cubit!;
    final currentState = cubit.state;
    // A stale loader must not turn an error into an implicit retry.
    if (currentState is! PaginationLoaded || currentState.hasReachedEnd) return;
    // Waiting for the initial cached page's confirmation does not request a new
    // page and must not consume the prefetch allowance.
    if (!cubit.isFetching) _automaticFetchAllowed = false;
    final request = cubit.fetchPaginatedList();
    _nextPageRequest = request;
    unawaited(request.then((_) {
      if (!identical(_nextPageRequest, request)) return;
      _nextPageRequest = null;
      final state = cubit.state;
      if (mounted &&
          identical(_cubit, cubit) &&
          state is PaginationLoaded &&
          !state.hasReachedEnd) {
        // Server confirmation may contain no data changes. Rebuild the visible
        // loader so scrolling resumes without emitting a duplicate onLoaded.
        setState(() {});
      }
    }));
  }

  Widget _buildPaginationControl() {
    if (_nextPageRequest != null) return widget.bottomLoader;
    if (_automaticFetchAllowed) {
      _fetchNextPage();
      return widget.bottomLoader;
    }
    return Center(
      child: TextButton(
        onPressed: () => setState(() => _automaticFetchAllowed = true),
        child: Text(widget.loadMoreLabel),
      ),
    );
  }

  ChildIndexGetter _documentIndexLookup(PaginationLoaded state,
      {int stride = 1}) {
    // Keep each item's State attached to its document when live updates or
    // filtering move it. A map avoids repeated linear searches during layout.
    final indices = {
      for (var i = 0; i < state.documentSnapshots.length; i++)
        ValueKey(state.documentSnapshots[i].reference.path): i * stride,
    };
    return (key) => indices[key];
  }

  Widget _buildGridView(PaginationLoaded loadedState) {
    var gridView = CustomScrollView(
      reverse: widget.reverse,
      controller: widget.scrollController,
      shrinkWrap: widget.shrinkWrap,
      scrollDirection: widget.scrollDirection,
      physics: widget.physics,
      keyboardDismissBehavior: widget.keyboardDismissBehavior,
      slivers: [
        if (widget.header != null) widget.header!,
        SliverPadding(
          padding: widget.padding,
          sliver: SliverGrid(
            gridDelegate: widget.gridDelegate,
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                if (index >= loadedState.documentSnapshots.length) {
                  return _buildPaginationControl();
                }
                final doc = loadedState.documentSnapshots[index];
                return KeyedSubtree(
                  key: ValueKey(doc.reference.path),
                  child: widget.itemBuilder(
                    context,
                    loadedState.documentSnapshots,
                    index,
                  ),
                );
              },
              childCount: loadedState.hasReachedEnd
                  ? loadedState.documentSnapshots.length
                  : loadedState.documentSnapshots.length + 1,
              findChildIndexCallback: _documentIndexLookup(loadedState),
            ),
          ),
        ),
        if (widget.footer != null) widget.footer!,
      ],
    );

    if (widget.listeners != null && widget.listeners!.isNotEmpty) {
      return MultiProvider(
        providers: widget.listeners!
            .map((listener) => ChangeNotifierProvider.value(value: listener))
            .toList(),
        child: gridView,
      );
    }

    return gridView;
  }

  Widget _buildListView(PaginationLoaded loadedState) {
    var listView = CustomScrollView(
      reverse: widget.reverse,
      controller: widget.scrollController,
      shrinkWrap: widget.shrinkWrap,
      scrollDirection: widget.scrollDirection,
      physics: widget.physics,
      keyboardDismissBehavior: widget.keyboardDismissBehavior,
      slivers: [
        if (widget.header != null) widget.header!,
        SliverPadding(
          padding: widget.padding,
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final itemIndex = index ~/ 2;
                if (index.isEven) {
                  if (itemIndex >= loadedState.documentSnapshots.length) {
                    return _buildPaginationControl();
                  }
                  final doc = loadedState.documentSnapshots[itemIndex];
                  return KeyedSubtree(
                    key: ValueKey(doc.reference.path),
                    child: widget.itemBuilder(
                      context,
                      loadedState.documentSnapshots,
                      itemIndex,
                    ),
                  );
                }
                return widget.separator;
              },
              semanticIndexCallback: (widget, localIndex) {
                if (localIndex.isEven) {
                  return localIndex ~/ 2;
                }
                // ignore: avoid_returning_null
                return null;
              },
              findChildIndexCallback:
                  _documentIndexLookup(loadedState, stride: 2),
              childCount: max(
                  0,
                  (loadedState.hasReachedEnd
                              ? loadedState.documentSnapshots.length
                              : loadedState.documentSnapshots.length + 1) *
                          2 -
                      1),
            ),
          ),
        ),
        if (widget.footer != null) widget.footer!,
      ],
    );

    if (widget.listeners != null && widget.listeners!.isNotEmpty) {
      return MultiProvider(
        providers: widget.listeners!
            .map((listener) => ChangeNotifierProvider.value(value: listener))
            .toList(),
        child: listView,
      );
    }

    return listView;
  }

  Widget _buildPageView(PaginationLoaded loadedState) {
    var pageView = Padding(
      padding: widget.padding,
      child: PageView.custom(
        reverse: widget.reverse,
        allowImplicitScrolling: widget.allowImplicitScrolling,
        controller: widget.pageController,
        scrollDirection: widget.scrollDirection,
        physics: widget.physics,
        onPageChanged: widget.onPageChanged,
        childrenDelegate: SliverChildBuilderDelegate(
          (context, index) {
            if (index >= loadedState.documentSnapshots.length) {
              return _buildPaginationControl();
            }
            final doc = loadedState.documentSnapshots[index];
            return KeyedSubtree(
              key: ValueKey(doc.reference.path),
              child: widget.itemBuilder(
                context,
                loadedState.documentSnapshots,
                index,
              ),
            );
          },
          childCount: loadedState.hasReachedEnd
              ? loadedState.documentSnapshots.length
              : loadedState.documentSnapshots.length + 1,
          findChildIndexCallback: _documentIndexLookup(loadedState),
        ),
      ),
    );

    if (widget.listeners != null && widget.listeners!.isNotEmpty) {
      return MultiProvider(
        providers: widget.listeners!
            .map((listener) => ChangeNotifierProvider.value(value: listener))
            .toList(),
        child: pageView,
      );
    }

    return pageView;
  }
}

enum PaginateBuilderType { listView, gridView, pageView }
