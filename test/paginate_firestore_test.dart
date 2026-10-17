import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paginate_firestore/bloc/pagination_cubit.dart';
import 'package:paginate_firestore/bloc/pagination_listeners.dart';
import 'package:paginate_firestore/paginate_firestore.dart';

import 'support/firestore_fakes.dart';

void main() {
  Widget buildWidget(
    RecordingFirestore store, {
    List<ChangeNotifier>? listeners,
    ScrollController? controller,
    void Function(PaginationLoaded)? onLoaded,
    int pageSize = 2,
    bool isLive = false,
    GetOptions? options,
    int? globalLimit,
    PaginateBuilderType builderType = PaginateBuilderType.listView,
    PageController? pageController,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: PaginateFirestore(
            query: store.query,
            itemsPerPage: pageSize,
            itemBuilderType: builderType,
            pageController: pageController,
            listeners: listeners,
            scrollController: controller,
            isLive: isLive,
            onLoaded: onLoaded,
            options: options,
            itemsGlobalLimit: globalLimit,
            itemBuilder: (context, docs, index) =>
                SizedBox(height: 100, child: Text(docs[index].reference.path)),
          ),
        ),
      );

  testWidgets('parent rebuilds do not repeat reads or loaded callbacks',
      (tester) async {
    final store = RecordingFirestore();
    var loadedCount = 0;
    await tester.pumpWidget(buildWidget(store, onLoaded: (_) => loadedCount++));
    store.requests.single.respond([TestDocument('items/a')]);
    await tester.pumpAndSettle();
    expect(find.text('items/a'), findsOneWidget);
    expect(loadedCount, 1);
    await tester.pumpWidget(buildWidget(store, onLoaded: (_) => loadedCount++));
    await tester.pumpAndSettle();
    expect(loadedCount, 1);
    expect(store.requests, hasLength(1));
  });

  testWidgets('zero limit reports loaded without making a query',
      (tester) async {
    final store = RecordingFirestore();
    var loadedCount = 0;
    await tester.pumpWidget(
        buildWidget(store, globalLimit: 0, onLoaded: (_) => loadedCount++));
    await tester.pumpAndSettle();
    expect(store.requests, isEmpty);
    expect(loadedCount, 1);
    expect(find.text('No documents found'), findsOneWidget);
  });

  testWidgets('changing the query cancels the old listener and shows new data',
      (tester) async {
    final first = RecordingFirestore();
    final second = RecordingFirestore();
    await tester.pumpWidget(buildWidget(first, isLive: true));
    first.requests.single.respond([TestDocument('items/a')]);
    await tester.pumpAndSettle();
    await tester.pumpWidget(buildWidget(second, isLive: true));
    expect(first.requests.single.cancelled, isTrue);
    expect(second.requests, hasLength(1));
    first.requests.single.respond([TestDocument('items/stale')]);
    second.requests.single.respond([TestDocument('items/b')]);
    await tester.pumpAndSettle();
    expect(find.text('items/a'), findsNothing);
    expect(find.text('items/stale'), findsNothing);
    expect(find.text('items/b'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(second.requests.single.cancelled, isTrue);
  });

  testWidgets('changing page size creates a request with the new limit',
      (tester) async {
    final store = RecordingFirestore();
    await tester.pumpWidget(buildWidget(store));
    store.requests.single.respond([TestDocument('items/a')]);
    await tester.pumpAndSettle();
    await tester.pumpWidget(buildWidget(store, pageSize: 3));
    expect(store.requests, hasLength(2));
    expect(store.requests.last.query.pageLimit, 3);
    store.requests.last.respond([TestDocument('items/b')]);
    await tester.pumpAndSettle();
    expect(find.text('items/b'), findsOneWidget);
  });

  testWidgets('equivalent get options do not reread on parent rebuild',
      (tester) async {
    final store = RecordingFirestore();
    await tester.pumpWidget(buildWidget(store));
    store.requests.single.respond([TestDocument('items/a')]);
    await tester.pumpAndSettle();
    await tester.pumpWidget(buildWidget(store, options: GetOptions()));
    await tester.pumpAndSettle();
    expect(store.requests, hasLength(1));
    await tester.pumpWidget(
        buildWidget(store, options: const GetOptions(source: Source.cache)));
    expect(store.requests, hasLength(2));
    expect(store.requests.last.options!.source, Source.cache);
    store.requests.last.respond([TestDocument('items/b')]);
    await tester.pumpAndSettle();
  });

  testWidgets('caller-owned controllers and notifiers survive disposal',
      (tester) async {
    final store = RecordingFirestore();
    final controller = ScrollController();
    final filter = PaginateFilterChangeListener();
    await tester.pumpWidget(
        buildWidget(store, controller: controller, listeners: [filter]));
    store.requests.single.respond([TestDocument('items/a')]);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    expect(() => controller.addListener(() {}), returnsNormally);
    expect(() => filter.searchTerm = 'a', returnsNormally);
    expect(() => filter.addListener(() {}), returnsNormally);
    controller.dispose();
    filter.dispose();
  });

  testWidgets('clearing filters restores data and listener replacements work',
      (tester) async {
    final store = RecordingFirestore();
    final oldFilter = PaginateFilterChangeListener();
    final newFilter = PaginateFilterChangeListener();
    await tester.pumpWidget(buildWidget(store, listeners: [oldFilter]));
    store.requests.single.respond([TestDocument('items/a', 'apple')]);
    await tester.pumpAndSettle();
    oldFilter.searchTerm = 'missing';
    await tester.pumpAndSettle();
    expect(find.text('No documents found'), findsOneWidget);
    oldFilter.searchTerm = '';
    await tester.pumpAndSettle();
    expect(find.text('items/a'), findsOneWidget);
    await tester.pumpWidget(buildWidget(store, listeners: [newFilter]));
    oldFilter.searchTerm = 'missing';
    await tester.pumpAndSettle();
    expect(find.text('items/a'), findsOneWidget);
    newFilter.searchTerm = 'missing';
    await tester.pumpAndSettle();
    expect(find.text('No documents found'), findsOneWidget);
    expect(store.requests, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    oldFilter.dispose();
    newFilter.dispose();
  });

  testWidgets('errors reach the error widget', (tester) async {
    final store = RecordingFirestore();
    await tester.pumpWidget(buildWidget(store));
    store.requests.single.fail(Exception('denied'));
    await tester.pumpAndSettle();
    expect(find.text('Error occurred: Exception: denied'), findsOneWidget);
  });

  testWidgets('collection-group documents use distinct widget keys',
      (tester) async {
    final store = RecordingFirestore();
    await tester.pumpWidget(buildWidget(store, pageSize: 3));
    store.requests.single.respond([
      TestDocument('parents/one/items/shared'),
      TestDocument('parents/two/items/shared'),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('parents/one/items/shared'), findsOneWidget);
    expect(find.text('parents/two/items/shared'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final builderType in PaginateBuilderType.values) {
    testWidgets('cached pages resume after confirmation in ${builderType.name}',
        (tester) async {
      final store = RecordingFirestore();
      final a = TestDocument('items/a');
      final b = TestDocument('items/b');
      final pageController = PageController(initialPage: 2);
      var loadedCount = 0;
      await tester.pumpWidget(buildWidget(store,
          isLive: true,
          builderType: builderType,
          pageController: pageController,
          onLoaded: (_) => loadedCount++));
      store.requests.single.respond([a, b], fromCache: true);
      await tester.pump();
      await tester.pump();
      expect(store.requests, hasLength(1));
      expect(loadedCount, 1);
      store.requests.single.respond([a, b], metadataOnly: true);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(store.requests, hasLength(2));
      expect(loadedCount, 1);
      store.requests.last.respond([]);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      pageController.dispose();
    });
  }

  testWidgets('removing a filter listener restores the unfiltered list',
      (tester) async {
    final store = RecordingFirestore();
    final filter = PaginateFilterChangeListener()..searchTerm = 'missing';
    await tester.pumpWidget(buildWidget(store, listeners: [filter]));
    store.requests.single.respond([TestDocument('items/a', 'apple')]);
    await tester.pumpAndSettle();
    expect(find.text('No documents found'), findsOneWidget);
    await tester.pumpWidget(buildWidget(store));
    await tester.pumpAndSettle();
    expect(find.text('items/a'), findsOneWidget);
    expect(store.requests, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    filter.dispose();
  });
}
