import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paginate_firestore/bloc/pagination_cubit.dart';

import 'support/firestore_fakes.dart';

void main() {
  final a = TestDocument('items/a', 'Apple');
  final b = TestDocument('items/b', 'Banana');
  final c = TestDocument('items/c', 'Cherry');
  final d = TestDocument('items/d', 'Date');
  late RecordingFirestore store;
  late PaginationCubit cubit;

  PaginationLoaded loaded() => cubit.state as PaginationLoaded;
  List<String> paths() =>
      loaded().documentSnapshots.map((doc) => doc.reference.path).toList();

  Future<void> load(List<TestDocument> docs) async {
    final pending = cubit.fetchPaginatedList();
    store.requests.last.respond(docs);
    await pending;
  }

  setUp(() => store = RecordingFirestore());
  tearDown(() async => cubit.close());

  test('concurrent fetches share one read and paginate with document cursors',
      () async {
    cubit = PaginationCubit(store.query, 2, null);
    final pending = cubit.fetchPaginatedList();
    for (var i = 0; i < 10; i++) {
      expect(identical(cubit.fetchPaginatedList(), pending), isTrue);
    }
    expect(store.requests, hasLength(1));
    store.requests.first.respond([a, b]);
    await pending;
    await load([c]);
    expect(store.requests.last.query.cursor, same(b));
    expect(paths(), ['items/a', 'items/b', 'items/c']);
    expect(loaded().hasReachedEnd, isTrue);
    await cubit.fetchPaginatedList();
    expect(store.requests, hasLength(2));
  });

  test('full final pages require only one empty end probe', () async {
    cubit = PaginationCubit(store.query, 2, null);
    await load([a, b]);
    await load([]);
    await cubit.fetchPaginatedList();
    expect(store.requests, hasLength(2));
    expect(paths(), ['items/a', 'items/b']);
    expect(loaded().hasReachedEnd, isTrue);
  });

  test('global limit reduces the final query rather than overfetching',
      () async {
    cubit = PaginationCubit(store.query, 2, null, itemsGlobalLimit: 3);
    await load([a, b]);
    final pending = cubit.fetchPaginatedList();
    expect(store.requests.last.query.pageLimit, 1);
    store.requests.last.respond([c]);
    await pending;
    await cubit.fetchPaginatedList();
    expect(paths(), ['items/a', 'items/b', 'items/c']);
    expect(store.requests, hasLength(2));
    expect(loaded().hasReachedEnd, isTrue);
  });

  test('global limit applies to the first page', () async {
    cubit = PaginationCubit(store.query, 15, null, itemsGlobalLimit: 1);
    await load([a]);
    expect(store.requests.single.query.pageLimit, 1);
    expect(loaded().hasReachedEnd, isTrue);
  });

  test('zero global limit makes no query, including on refresh', () async {
    cubit = PaginationCubit(store.query, 2, null, itemsGlobalLimit: 0);
    await cubit.fetchPaginatedList();
    await cubit.refreshPaginatedList();
    expect(store.requests, isEmpty);
    expect(paths(), isEmpty);
    expect(loaded().hasReachedEnd, isTrue);
  });

  test('start cursor and get options are preserved across refresh', () async {
    const options = GetOptions(source: Source.cache);
    cubit = PaginationCubit(store.query, 2, a, options: options);
    await load([b]);
    expect(store.requests.single.query.cursor, same(a));
    expect(store.requests.single.options, same(options));
    final refreshed = cubit.refreshPaginatedList();
    await pumpEventQueue();
    expect(store.requests.last.query.cursor, same(a));
    expect(store.requests.last.options, same(options));
    store.requests.last.respond([c]);
    await refreshed;
    expect(paths(), ['items/c']);
  });

  test('filtering is reversible and never changes the cursor or read budget',
      () async {
    cubit = PaginationCubit(store.query, 2, null, itemsGlobalLimit: 3);
    await load([a, b]);
    cubit.filterPaginatedList('APPLE');
    expect(paths(), ['items/a']);
    cubit.filterPaginatedList('banana');
    expect(paths(), ['items/b']);
    expect(store.requests, hasLength(1));
    final pending = cubit.fetchPaginatedList();
    expect(store.requests.last.query.cursor, same(b));
    expect(store.requests.last.query.pageLimit, 1);
    store.requests.last.respond([c]);
    await pending;
    expect(paths(), ['items/b']);
    cubit.filterPaginatedList('');
    expect(paths(), ['items/a', 'items/b', 'items/c']);
  });

  test('collection-group documents with the same ID remain distinct', () async {
    cubit = PaginationCubit(store.query, 2, null);
    final first = TestDocument('parents/one/items/shared');
    final second = TestDocument('parents/two/items/shared');
    await load([first, second]);
    expect(paths(), [first.reference.path, second.reference.path]);
  });

  test('refresh ignores an older pending read and coalesces refresh calls',
      () async {
    cubit = PaginationCubit(store.query, 2, null);
    final oldFetch = cubit.fetchPaginatedList();
    final refreshed = cubit.refreshPaginatedList();
    expect(identical(cubit.refreshPaginatedList(), refreshed), isTrue);
    expect(identical(cubit.fetchPaginatedList(), refreshed), isTrue);
    await pumpEventQueue();
    store.requests.last.respond([c]);
    await refreshed;
    store.requests.first.respond([a, b]);
    await oldFetch;
    expect(paths(), ['items/c']);
    expect(store.requests, hasLength(2));
  });

  test('read failures surface and an explicit retry can recover', () async {
    cubit = PaginationCubit(store.query, 2, null);
    final pending = cubit.fetchPaginatedList();
    final error = FirebaseException(plugin: 'cloud_firestore', code: 'denied');
    store.requests.single.fail(error);
    await pending;
    expect((cubit.state as PaginationError).error, same(error));
    final retry = cubit.fetchPaginatedList();
    await pumpEventQueue();
    store.requests.last.respond([a]);
    await retry;
    expect(paths(), ['items/a']);
  });

  test('closing ignores an outstanding read and prevents subsequent reads',
      () async {
    cubit = PaginationCubit(store.query, 2, null);
    final pending = cubit.fetchPaginatedList();
    await cubit.close();
    store.requests.single.respond([a]);
    await pending;
    await cubit.fetchPaginatedList();
    await cubit.refreshPaginatedList();
    expect(store.requests, hasLength(1));
  });

  test('live pages keep the request locked until the first server snapshot',
      () async {
    cubit = PaginationCubit(store.query, 2, null, isLive: true);
    final first = cubit.fetchPaginatedList();
    store.requests.single.respond([a], fromCache: true);
    await pumpEventQueue();
    expect(loaded().hasReachedEnd, isFalse);
    expect(identical(cubit.fetchPaginatedList(), first), isTrue);
    expect(store.requests, hasLength(1));
    expect(store.requests.single.includeMetadataChanges, isTrue);
    store.requests.single.respond([a, b]);
    await first;
    final second = cubit.fetchPaginatedList();
    for (var i = 0; i < 10; i++) {
      cubit.fetchPaginatedList();
    }
    expect(store.requests, hasLength(2));
    store.requests.last.respond([c, d]);
    await second;
    expect(paths(), ['items/a', 'items/b', 'items/c', 'items/d']);
  });

  test('empty cache is not a terminal empty result', () async {
    cubit = PaginationCubit(store.query, 2, null, isLive: true);
    final pending = cubit.fetchPaginatedList();
    store.requests.single.respond([], fromCache: true);
    await pumpEventQueue();
    expect(cubit.state, isA<PaginationInitial>());
    store.requests.single.respond([], metadataOnly: true);
    await pending;
    expect(paths(), isEmpty);
    expect(loaded().hasReachedEnd, isTrue);
  });

  test('metadata-only server confirmation releases the pagination lock',
      () async {
    cubit = PaginationCubit(store.query, 2, null, isLive: true);
    final pending = cubit.fetchPaginatedList();
    store.requests.single.respond([a], fromCache: true);
    await pumpEventQueue();
    store.requests.single.respond([a], metadataOnly: true);
    await pending;
    expect(loaded().hasReachedEnd, isTrue);
  });

  test('pending local writes are not used as pagination cursors', () async {
    cubit = PaginationCubit(store.query, 2, null, isLive: true);
    final pending = cubit.fetchPaginatedList();
    store.requests.single.respond([a, b], pendingWrites: true);
    await pumpEventQueue();
    expect(identical(cubit.fetchPaginatedList(), pending), isTrue);
    store.requests.single.respond([b, a]);
    await pending;
    final next = cubit.fetchPaginatedList();
    expect(store.requests.last.query.cursor, same(a));
    store.requests.last.respond([]);
    await next;
  });

  test('earlier live updates preserve later pages, their cursor and end state',
      () async {
    cubit = PaginationCubit(store.query, 2, null, isLive: true);
    await load([a, b]);
    await load([c, d]);
    final updatedA = TestDocument('items/a', 'Updated');
    store.requests.first.respond([updatedA]);
    await pumpEventQueue();
    expect(paths(), ['items/a', 'items/c', 'items/d']);
    expect(loaded().documentSnapshots.first.data(), {'value': 'Updated'});
    expect(loaded().hasReachedEnd, isFalse);
    final third = cubit.fetchPaginatedList();
    expect(store.requests.last.query.cursor, same(d));
    store.requests.last.respond([]);
    await third;
    store.requests.first.respond([updatedA, b]);
    await pumpEventQueue();
    expect(paths(), ['items/a', 'items/b', 'items/c', 'items/d']);
    expect(loaded().hasReachedEnd, isTrue);
    await cubit.fetchPaginatedList();
    expect(store.requests, hasLength(3));
  });

  test('overlapping live pages deduplicate paths and retain the latest data',
      () async {
    cubit = PaginationCubit(store.query, 2, null, isLive: true);
    await load([a, b]);
    await load([c, d]);
    final updatedC = TestDocument('items/c', 'Updated cherry');
    store.requests.first.respond([b, updatedC]);
    await pumpEventQueue();
    expect(paths(), ['items/b', 'items/c', 'items/d']);
    expect(loaded().documentSnapshots[1].data(), {'value': 'Updated cherry'});
  });

  test('first-page-only live mode preserves one-time pages on updates',
      () async {
    cubit = PaginationCubit(store.query, 2, null,
        isLive: true, isAllItemsLive: false);
    await load([a, b]);
    await load([c, d]);
    expect(store.requests.map((r) => r.isLive), [true, false]);
    store.requests.first.respond([TestDocument('items/a', 'New apple'), b]);
    await pumpEventQueue();
    expect(paths(), ['items/a', 'items/b', 'items/c', 'items/d']);
  });

  test('live global allowance is not reopened by deletes or local filtering',
      () async {
    cubit = PaginationCubit(store.query, 2, null,
        isLive: true, itemsGlobalLimit: 3);
    await load([a, b]);
    await load([c]);
    expect(store.requests.last.query.pageLimit, 1);
    store.requests.first.respond([a]);
    await pumpEventQueue();
    cubit.filterPaginatedList('missing');
    await cubit.fetchPaginatedList();
    expect(loaded().hasReachedEnd, isTrue);
    expect(store.requests, hasLength(2));
  });

  test('refresh cancels old listeners and releases pending live requests',
      () async {
    cubit = PaginationCubit(store.query, 2, null, isLive: true);
    final pending = cubit.fetchPaginatedList();
    final refreshed = cubit.refreshPaginatedList();
    await pending;
    await pumpEventQueue();
    expect(store.requests.first.cancelled, isTrue);
    store.requests.first.respond([a, b]);
    store.requests.last.respond([c]);
    await refreshed;
    expect(paths(), ['items/c']);
    await cubit.close();
    expect(store.requests.last.cancelled, isTrue);
  });

  test('stream errors surface, cancel listeners and finish pending requests',
      () async {
    cubit = PaginationCubit(store.query, 2, null, isLive: true);
    await load([a, b]);
    final pending = cubit.fetchPaginatedList();
    store.requests.last.fail(Exception('permission denied'));
    await pending;
    expect(cubit.state, isA<PaginationError>());
    expect(store.requests.every((r) => r.cancelled), isTrue);
    store.requests.first.respond([c]);
    await pumpEventQueue();
    expect(cubit.state, isA<PaginationError>());
  });

  test('live conversion errors surface and release the pending request',
      () async {
    cubit = PaginationCubit(store.query, 2, null, isLive: true);
    final pending = cubit.fetchPaginatedList();
    store.requests.single.stream.add(InvalidSnapshot());
    await pending;
    expect((cubit.state as PaginationError).error, isA<FormatException>());
    expect(store.requests.single.cancelled, isTrue);
  });

  test('a pending final page does not report the global limit as loaded',
      () async {
    cubit = PaginationCubit(store.query, 2, null,
        isLive: true, itemsGlobalLimit: 3);
    await load([a, b]);
    final pending = cubit.fetchPaginatedList();
    store.requests.first.respond([TestDocument('items/a', 'Updated'), b]);
    await pumpEventQueue();
    expect(loaded().hasReachedEnd, isFalse);
    store.requests.last.respond([c]);
    await pending;
    expect(loaded().hasReachedEnd, isTrue);
  });

  test('metadata-only confirmation does not emit unchanged loaded data',
      () async {
    cubit = PaginationCubit(store.query, 2, null, isLive: true);
    final states = <PaginationState>[];
    final subscription = cubit.stream.listen(states.add);
    final pending = cubit.fetchPaginatedList();
    store.requests.single.respond([a, b], fromCache: true);
    await pumpEventQueue();
    // Real Firestore snapshots wrap the same data in new document objects.
    store.requests.single.respond([
      TestDocument('items/a', 'Apple'),
      TestDocument('items/b', 'Banana'),
    ], metadataOnly: true);
    await pending;
    await pumpEventQueue();
    expect(states.whereType<PaginationLoaded>(), hasLength(1));
    await subscription.cancel();
  });

  test('later local changes must be confirmed before using the tail cursor',
      () async {
    cubit = PaginationCubit(store.query, 2, null, isLive: true);
    await load([a, b]);
    store.requests.single.respond([a, c], pendingWrites: true);
    await pumpEventQueue();
    final next = cubit.fetchPaginatedList();
    await pumpEventQueue();
    expect(store.requests, hasLength(1));
    store.requests.first.respond([a, c], metadataOnly: true);
    await pumpEventQueue();
    expect(store.requests, hasLength(2));
    expect(store.requests.last.query.cursor, same(c));
    store.requests.last.respond([]);
    await next;
  });

  test('empty local updates remove stale rows after initial data was displayed',
      () async {
    cubit = PaginationCubit(store.query, 2, null, isLive: true);
    await load([a]);
    store.requests.single.respond([], pendingWrites: true);
    await pumpEventQueue();
    expect(paths(), isEmpty);
    store.requests.single.respond([], metadataOnly: true);
    await pumpEventQueue();
    expect(paths(), isEmpty);
  });

  test('metadata from an overlapping page does not restore older document data',
      () async {
    cubit = PaginationCubit(store.query, 2, null,
        isLive: true, includeMetadataChanges: true);
    await load([a, b]);
    await load([c, d]);
    store.requests.first.respond([b, TestDocument('items/c', 'Updated')]);
    await pumpEventQueue();
    store.requests.last.respond([c, d], metadataOnly: true);
    await pumpEventQueue();
    expect(loaded().documentSnapshots[1].data(), {'value': 'Updated'});
  });

  test('refresh cancels a wait for a later cursor confirmation', () async {
    cubit = PaginationCubit(store.query, 2, null, isLive: true);
    await load([a, b]);
    store.requests.single.respond([a, c], fromCache: true);
    await pumpEventQueue();
    final waiting = cubit.fetchPaginatedList();
    final refresh = cubit.refreshPaginatedList();
    await waiting;
    await pumpEventQueue();
    expect(store.requests, hasLength(2));
    store.requests.last.respond([d]);
    await refresh;
    expect(paths(), ['items/d']);
  });

  test(
      'a closed live stream reports an error instead of leaving a pending fetch',
      () async {
    cubit = PaginationCubit(store.query, 2, null, isLive: true);
    final pending = cubit.fetchPaginatedList();
    await store.requests.single.stream.close();
    await pending;
    expect(cubit.state, isA<PaginationError>());
  });

  test('filter conversion errors use the normal error state', () async {
    cubit = PaginationCubit(store.query, 2, null);
    await load([InvalidDocument()]);
    expect(() => cubit.filterPaginatedList('anything'), returnsNormally);
    expect((cubit.state as PaginationError).error, isA<FormatException>());
  });

  test('closing releases a pending wait for later cursor confirmation',
      () async {
    cubit = PaginationCubit(store.query, 2, null, isLive: true);
    await load([a, b]);
    store.requests.single.respond([a, c], fromCache: true);
    await pumpEventQueue();
    final waiting = cubit.fetchPaginatedList();
    await cubit.close();
    await waiting;
    expect(store.requests, hasLength(1));
    expect(store.requests.single.cancelled, isTrue);
  });

  test('an unrelated page update does not replace a newer overlapping document',
      () async {
    cubit = PaginationCubit(store.query, 2, null, isLive: true);
    await load([a, b]);
    await load([c, d]);
    store.requests.first.respond([b, TestDocument('items/c', 'New cherry')]);
    await pumpEventQueue();
    // The second listener has only observed a change to d so far. Its copy
    // of c must not override the newer c already received on the first page.
    store.requests.last.respond([c, TestDocument('items/d', 'New date')]);
    await pumpEventQueue();
    expect(loaded().documentSnapshots[1].data(), {'value': 'New cherry'});
    expect(loaded().documentSnapshots[2].data(), {'value': 'New date'});
  });
}
