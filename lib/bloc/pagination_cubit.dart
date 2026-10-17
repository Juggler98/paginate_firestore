import 'dart:async';
import 'dart:math';

import 'package:bloc/bloc.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

part 'pagination_state.dart';

class PaginationCubit extends Cubit<PaginationState> {
  PaginationCubit(
    this._query,
    this._limit,
    this._startAfterDocument, {
    this.isLive = false,
    this.includeMetadataChanges = false,
    this.options,
    this.itemsGlobalLimit,
    this.isAllItemsLive = true,
  })  : assert(_limit > 0),
        assert(itemsGlobalLimit == null || itemsGlobalLimit >= 0),
        super(PaginationInitial());

  final int _limit;
  final Query _query;
  final DocumentSnapshot? _startAfterDocument;
  final bool isLive;
  final bool includeMetadataChanges;
  final GetOptions? options;
  final int? itemsGlobalLimit;
  final bool isAllItemsLive;

  // Each listener owns its page. An update to an earlier page must not replace
  // later pages or move the cursor used to fetch the next page.
  final _pages = <_PaginationPage>[];
  final _streams = <StreamSubscription<QuerySnapshot>>[];
  final _pendingSnapshots = <Completer<void>>{};
  List<DocumentSnapshot> _documents = [];
  Future<void>? _request;
  Future<void>? _refreshRequest;
  String _filterTerm = '';
  int _generation = 0;
  int _revision = 0;
  bool _disposed = false;
  bool _hasError = false;

  int get _requestedCount =>
      _pages.fold(0, (total, page) => total + page.limit);

  bool get _hasReachedEnd =>
      itemsGlobalLimit == 0 ||
      (_pages.isNotEmpty &&
          _pages.last.confirmed &&
          ((itemsGlobalLimit != null && _requestedCount >= itemsGlobalLimit!) ||
              _pages.last.hasReachedEnd));

  bool _isCurrent(int generation) =>
      !_disposed && !_hasError && generation == _generation;

  @override
  Future<void> close() async {
    _disposed = true;
    _generation++;
    await _clearStreams();
    await super.close();
  }

  Future<void> _clearStreams() async {
    final streams = List.of(_streams);
    _streams.clear();
    for (final pending in _pendingSnapshots) {
      if (!pending.isCompleted) pending.complete();
    }
    _pendingSnapshots.clear();
    await Future.wait(streams.map((stream) => stream.cancel()));
  }

  /// Filters only documents already loaded, without issuing Firestore reads.
  /// An empty term restores the unfiltered list.
  void filterPaginatedList(String searchTerm) {
    final normalizedTerm = searchTerm.toLowerCase();
    if (_filterTerm == normalizedTerm) return;
    _filterTerm = normalizedTerm;
    if (!_disposed && state is PaginationLoaded) {
      try {
        _emitLoaded();
      } catch (error) {
        _handleError(error, _generation);
      }
    }
  }

  Future<void> refreshPaginatedList() {
    if (_disposed) return Future.value();
    if (_refreshRequest != null) return _refreshRequest!;

    final generation = ++_generation;
    _hasError = false;
    _pages.clear();
    _documents = [];
    _request = null;
    emit(PaginationInitial());

    late final Future<void> request;
    request = _clearStreams().then((_) async {
      if (_isCurrent(generation)) await _fetchPage(generation);
    }).whenComplete(() {
      if (identical(_refreshRequest, request)) _refreshRequest = null;
    });
    _refreshRequest = request;
    return request;
  }

  /// Concurrent calls share the same request, including while a live listener
  /// is waiting for its first server-confirmed snapshot.
  Future<void> fetchPaginatedList() {
    if (_disposed) return Future.value();
    if (_refreshRequest != null) return _refreshRequest!;
    if (_request != null) return _request!;
    if (_hasError) return refreshPaginatedList();
    if (_hasReachedEnd && state is! PaginationInitial) {
      return Future.value();
    }

    late final Future<void> request;
    request = _fetchPage(_generation).whenComplete(() {
      if (identical(_request, request)) _request = null;
    });
    _request = request;
    return request;
  }

  Future<void> _fetchPage(int generation) async {
    // An already loaded live page can later receive pending local writes or
    // cached updates. Wait for its latest cursor, not just its first snapshot.
    while (_pages.isNotEmpty && !_pages.last.cursorIsCurrent) {
      final page = _pages.last;
      final confirmation = page.confirmation ??= Completer<void>();
      _pendingSnapshots.add(confirmation);
      await confirmation.future;
      if (!_isCurrent(generation)) return;
    }
    if (_hasReachedEnd) {
      // Match asynchronous query completion so widget listeners can subscribe
      // before a zero-limit request reports that it has loaded.
      await Future<void>.value();
      if (_isCurrent(generation)) _emitLoaded();
      return;
    }
    final pageLimit = itemsGlobalLimit == null
        ? _limit
        : min(_limit, itemsGlobalLimit! - _requestedCount);
    final cursor = _pages.isEmpty ? _startAfterDocument : _pages.last.cursor;
    final page = _PaginationPage(pageLimit, cursor);
    _pages.add(page);

    try {
      final query =
          (cursor == null ? _query : _query.startAfterDocument(cursor))
              .limit(pageLimit);
      if (isLive && (_pages.length == 1 || isAllItemsLive)) {
        final ready = Completer<void>();
        _pendingSnapshots.add(ready);
        final listener = query
            // A cache snapshot can be incomplete. Metadata events let us wait
            // for confirmation even when the server returns identical data.
            .snapshots(includeMetadataChanges: true)
            .listen((snapshot) {
          if (!_isCurrent(generation)) return;
          try {
            final confirmed = !snapshot.metadata.isFromCache &&
                !snapshot.metadata.hasPendingWrites;
            _updatePage(page, snapshot,
                confirmed: confirmed, emitMetadata: includeMetadataChanges);
            if (confirmed && !ready.isCompleted) {
              ready.complete();
              _pendingSnapshots.remove(ready);
            }
          } catch (error) {
            // Converter failures happen inside the data callback, not onError.
            _handleError(error, generation);
          }
        }, onError: (Object error, StackTrace stackTrace) {
          _handleError(error, generation);
        }, onDone: () {
          _handleError(
              StateError('The Firestore listener closed unexpectedly.'),
              generation);
        });
        _streams.add(listener);
        await ready.future;
      } else {
        final snapshot = await query.get(options);
        if (_isCurrent(generation)) {
          _updatePage(page, snapshot, confirmed: true);
        }
      }
    } catch (error) {
      _handleError(error, generation);
    }
  }

  void _handleError(Object error, int generation) {
    if (!_isCurrent(generation)) return;
    _hasError = true;
    emit(PaginationError(
      error: error is Exception ? error : Exception(error.toString()),
    ));
    unawaited(_clearStreams());
  }

  void _updatePage(
    _PaginationPage page,
    QuerySnapshot snapshot, {
    required bool confirmed,
    bool emitMetadata = true,
  }) {
    final documentsInPage = snapshot.docs;
    final wasAtEnd = _hasReachedEnd;
    page.cursorIsCurrent = confirmed;
    if (confirmed) {
      page.confirmed = true;
      page.hasReachedEnd = documentsInPage.length < page.limit;
      // Retain the cursor on an empty result; never restart from page one.
      if (documentsInPage.isNotEmpty) page.cursor = documentsInPage.last;
      final confirmation = page.confirmation;
      if (confirmation != null) {
        confirmation.complete();
        _pendingSnapshots.remove(confirmation);
        page.confirmation = null;
      }
    }
    final changes = snapshot.docChanges;
    final hasDocumentChanges = !page.receivedSnapshot || changes.isNotEmpty;
    page.receivedSnapshot = true;
    if (hasDocumentChanges || emitMetadata) {
      if (hasDocumentChanges) {
        final revision = ++_revision;
        final changedPaths =
            changes.map((change) => change.doc.reference.path).toSet();
        // Only changed documents gain a new revision. An update to another
        // document on this page must not overwrite a newer overlapping copy.
        page.documentRevisions = {
          for (final document in documentsInPage)
            document.reference.path: changedPaths
                    .contains(document.reference.path)
                ? revision
                : page.documentRevisions[document.reference.path] ?? revision,
        };
      }
      page.documents = documentsInPage;
      _mergePages();
    }

    if (hasDocumentChanges ||
        emitMetadata ||
        wasAtEnd != _hasReachedEnd ||
        state is PaginationInitial) {
      // Only the initial empty cache is inconclusive. Later local deletions
      // must also be reflected while their writes are still pending.
      if (_documents.isNotEmpty || confirmed || state is PaginationLoaded) {
        _emitLoaded();
      }
    }
  }

  void _mergePages() {
    // Full paths also distinguish documents in collection-group queries.
    // When live pages overlap, keep the most recently received document data.
    final documents = <String, DocumentSnapshot>{};
    final revisions = <String, int>{};
    for (final loadedPage in _pages) {
      for (final document in loadedPage.documents) {
        final path = document.reference.path;
        final revision = loadedPage.documentRevisions[path]!;
        if (!revisions.containsKey(path) || revisions[path]! < revision) {
          documents[path] = document;
          revisions[path] = revision;
        }
      }
    }
    _documents = documents.values.toList();
  }

  void _emitLoaded() {
    final documents = _filterTerm.isEmpty
        ? _documents
        : _documents
            .where((document) =>
                document.data().toString().toLowerCase().contains(_filterTerm))
            .toList();
    emit(PaginationLoaded(
      documentSnapshots: List.unmodifiable(documents),
      hasReachedEnd: _hasReachedEnd,
    ));
  }
}

class _PaginationPage {
  _PaginationPage(this.limit, this.cursor);

  final int limit;
  DocumentSnapshot? cursor;
  List<QueryDocumentSnapshot> documents = [];
  bool hasReachedEnd = false;
  bool confirmed = false;
  bool cursorIsCurrent = false;
  Completer<void>? confirmation;
  bool receivedSnapshot = false;
  Map<String, int> documentRevisions = {};
}
