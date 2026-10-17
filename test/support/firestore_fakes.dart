// Firestore exposes these interfaces for mocking in tests.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Json = Map<String, dynamic>;

class RecordingFirestore {
  final requests = <RecordedRequest>[];
  late final Query<Json> query = RecordingQuery(this);
}

class RecordingQuery extends Fake implements Query<Json> {
  RecordingQuery(this.store, {this.cursor, this.pageLimit});

  final RecordingFirestore store;
  final DocumentSnapshot? cursor;
  final int? pageLimit;

  @override
  Query<Json> startAfterDocument(DocumentSnapshot documentSnapshot) =>
      RecordingQuery(store, cursor: documentSnapshot, pageLimit: pageLimit);

  @override
  Query<Json> limit(int limit) =>
      RecordingQuery(store, cursor: cursor, pageLimit: limit);

  @override
  Future<QuerySnapshot<Json>> get([GetOptions? options]) {
    final request = RecordedRequest(this, options: options);
    store.requests.add(request);
    return request.result.future;
  }

  @override
  Stream<QuerySnapshot<Json>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) {
    final request = RecordedRequest(this,
        isLive: true, includeMetadataChanges: includeMetadataChanges);
    store.requests.add(request);
    return request.stream.stream;
  }
}

class RecordedRequest {
  RecordedRequest(this.query,
      {this.isLive = false, this.includeMetadataChanges = false, this.options});

  final RecordingQuery query;
  final bool isLive;
  final bool includeMetadataChanges;
  final GetOptions? options;
  final result = Completer<QuerySnapshot<Json>>();
  bool cancelled = false;
  late final stream = StreamController<QuerySnapshot<Json>>(
    onCancel: () => cancelled = true,
  );

  void respond(List<TestDocument> docs,
      {bool fromCache = false,
      bool pendingWrites = false,
      bool metadataOnly = false}) {
    final snapshot = TestSnapshot(docs,
        fromCache: fromCache,
        pendingWrites: pendingWrites,
        metadataOnly: metadataOnly);
    if (isLive) {
      stream.add(snapshot);
    } else {
      result.complete(snapshot);
    }
  }

  void fail(Exception error) {
    if (isLive) {
      stream.addError(error, StackTrace.current);
    } else {
      result.completeError(error, StackTrace.current);
    }
  }
}

class TestDocument extends Fake implements QueryDocumentSnapshot<Json> {
  TestDocument(String path, [this.value = ''])
      : reference = TestReference(path);

  final String value;

  @override
  final DocumentReference<Json> reference;

  @override
  String get id => reference.path.split('/').last;

  @override
  Json data() => {'value': value};
}

class TestReference extends Fake implements DocumentReference<Json> {
  TestReference(this.path);

  @override
  final String path;
}

class TestSnapshot extends Fake implements QuerySnapshot<Json> {
  TestSnapshot(this.docs,
      {bool fromCache = false,
      bool pendingWrites = false,
      this.metadataOnly = false})
      : metadata = TestMetadata(fromCache, pendingWrites);

  @override
  final List<TestDocument> docs;

  @override
  final SnapshotMetadata metadata;
  final bool metadataOnly;

  @override
  List<DocumentChange<Json>> get docChanges =>
      metadataOnly ? [] : [TestDocumentChange()];
}

class TestDocumentChange extends Fake implements DocumentChange<Json> {}

class InvalidSnapshot extends TestSnapshot {
  InvalidSnapshot() : super([]);

  @override
  List<TestDocument> get docs => throw const FormatException('Invalid data');
}

class TestMetadata extends Fake implements SnapshotMetadata {
  TestMetadata(this.isFromCache, this.hasPendingWrites);

  @override
  final bool isFromCache;

  @override
  final bool hasPendingWrites;
}
