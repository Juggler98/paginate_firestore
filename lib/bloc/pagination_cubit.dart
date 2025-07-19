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
  }) : super(PaginationInitial());

  DocumentSnapshot? _lastDocument;
  final int _limit;
  final Query _query;
  final DocumentSnapshot? _startAfterDocument;
  final bool isLive;
  final bool includeMetadataChanges;
  final GetOptions? options;

  final _streams = <StreamSubscription<QuerySnapshot>>[];

  @override
  Future<void> close() {
    for (var sub in _streams) {
      sub.cancel();
    }
    _streams.clear();
    return super.close();
  }

  void _clearListeners() {
    for (var listener in _streams) {
      listener.cancel();
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
    _lastDocument = null;
    final localQuery = _getQuery();
    try {
      if (isLive) {
        final listener = localQuery
            .snapshots(includeMetadataChanges: includeMetadataChanges)
            .listen((querySnapshot) {
          _emitPaginatedState(querySnapshot.docs);
        });
        _clearListeners();
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
        if (isLive) {
          await _getLiveDocuments();
        } else {
          await _getDocuments();
        }
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

  Future<void> _getLiveDocuments() async {
    final localQuery = _getQuery();
    PaginationLoaded loadedState = state as PaginationLoaded;
    if (loadedState.hasReachedEnd) {
      return;
    }
    final previousList =
        loadedState.documentSnapshots as List<QueryDocumentSnapshot>;
    final listener = localQuery
        .snapshots(includeMetadataChanges: includeMetadataChanges)
        .listen((querySnapshot) {
      _emitPaginatedState(
        querySnapshot.docs,
        previousList: previousList,
      );
    });
    _clearListeners();
    _streams.add(listener);
  }

  void _emitPaginatedState(
    List<QueryDocumentSnapshot> newList, {
    List<QueryDocumentSnapshot> previousList = const [],
  }) {
    _lastDocument = newList.isNotEmpty ? newList.last : null;
    emit(PaginationLoaded(
      documentSnapshots: _mergeSnapshots(previousList, newList),
      hasReachedEnd: newList.isEmpty,
    ));
  }

  List<QueryDocumentSnapshot> _mergeSnapshots(
    List<QueryDocumentSnapshot> previousList,
    List<QueryDocumentSnapshot> newList,
  ) {
    final prevIds = previousList.map((prevSnapshot) => prevSnapshot.id).toSet();
    newList.retainWhere((newSnapshot) => prevIds.add(newSnapshot.id));
    return previousList + newList;
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
