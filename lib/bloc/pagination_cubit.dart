import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

part 'pagination_state.dart';

class PaginationCubit extends Cubit<PaginationState> {
  PaginationCubit(
    this._query,
    this._limit,
    this._startAfterDocument, {
    this.isLive = false,
    this.includeMetadataChanges = false,
    this.options,
    this.globalLimit,
  }) : super(PaginationInitial());

  DocumentSnapshot? _lastDocument;
  final int _limit;
  final Query _query;
  final DocumentSnapshot? _startAfterDocument;
  final bool isLive;
  final bool includeMetadataChanges;
  final GetOptions? options;
  final int? globalLimit;

  final _streams = <StreamSubscription<QuerySnapshot>>[];

  @override
  Future<void> close() {
    _clearStreams();
    return super.close();
  }

  void _clearStreams() {
    for (var stream in _streams) {
      stream.cancel();
    }
    _streams.clear();
  }

  void filterPaginatedList(String searchTerm) {
    if (state is PaginationLoaded) {
      final loadedState = state as PaginationLoaded;

      final filteredList = loadedState.documentSnapshots
          .where((document) => document
              .data()
              .toString()
              .toLowerCase()
              .contains(searchTerm.toLowerCase()))
          .toList();

      emit(loadedState.copyWith(
        documentSnapshots: filteredList,
        hasReachedEnd: loadedState.hasReachedEnd,
      ));
    }
  }

  Future<void> refreshPaginatedList() async {
    _clearStreams();
    _lastDocument = null;
    final localQuery = _getQuery();
    try {
      if (isLive) {
        final listener = localQuery
            .snapshots(includeMetadataChanges: includeMetadataChanges)
            .listen((querySnapshot) {
          _emitPaginatedState(querySnapshot.docs);
        });
        _streams.add(listener);
      } else {
        final querySnapshot = await localQuery.get(options);
        _emitPaginatedState(querySnapshot.docs);
      }
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrintStack(label: error.toString(), stackTrace: stackTrace);
      }
    }
  }

  bool _isFetching = false;

  void fetchPaginatedList() async {
    if (_isFetching) {
      return;
    }
    _isFetching = true;
    try {
      if (state is PaginationInitial) {
        await refreshPaginatedList();
      } else if (state is PaginationLoaded) {
        await _getDocuments();
      }
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrintStack(label: error.toString(), stackTrace: stackTrace);
      }
    } finally {
      _isFetching = false;
    }
  }

  Future<void> _getDocuments() async {
    final localQuery = _getQuery();
    try {
      final loadedState = state as PaginationLoaded;
      if (loadedState.hasReachedEnd) {
        return;
      }
      final querySnapshot = await localQuery.get(options);
      _emitPaginatedState(
        querySnapshot.docs,
        previousList:
            loadedState.documentSnapshots as List<QueryDocumentSnapshot>,
      );
    } on PlatformException catch (exception) {
      if (kDebugMode) {
        print(exception);
      }
    }
  }

  void _emitPaginatedState(
    List<QueryDocumentSnapshot> newList, {
    List<QueryDocumentSnapshot> previousList = const [],
  }) {
    if (isClosed) {
      return;
    }
    _lastDocument = newList.isNotEmpty ? newList.last : null;
    final mergedList = _mergeSnapshots(previousList, newList);
    final hasReachedLimit =
        globalLimit != null && mergedList.length >= globalLimit!;
    emit(PaginationLoaded(
      documentSnapshots: _mergeSnapshots(previousList, newList),
      hasReachedEnd: hasReachedLimit || newList.length < _limit,
    ));
  }

  List<QueryDocumentSnapshot> _mergeSnapshots(
    List<QueryDocumentSnapshot> previousList,
    List<QueryDocumentSnapshot> newList,
  ) {
    final prevIds = previousList.map((doc) => doc.id).toSet();
    final filteredNew =
        newList.where((doc) => !prevIds.contains(doc.id)).toList();
    return [...previousList, ...filteredNew];
  }

  Query _getQuery() {
    var localQuery = (_lastDocument != null)
        ? _query.startAfterDocument(_lastDocument!)
        : _startAfterDocument != null
            ? _query.startAfterDocument(_startAfterDocument!)
            : _query;
    localQuery = localQuery.limit(_limit);
    return localQuery;
  }
}
