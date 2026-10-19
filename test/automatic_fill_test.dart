import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paginate_firestore/bloc/pagination_listeners.dart';
import 'package:paginate_firestore/paginate_firestore.dart';

import 'support/firestore_fakes.dart';

Widget pagination(
  RecordingFirestore store, {
  int? budget,
  int? globalLimit,
  double itemExtent = 50,
  bool hidden = false,
  bool hideLaterItems = false,
  bool reverse = false,
  bool shrinkWrap = false,
  bool nested = false,
  bool live = false,
  bool metadata = false,
  Axis axis = Axis.vertical,
  PaginateBuilderType type = PaginateBuilderType.listView,
  List<ChangeNotifier>? listeners,
  ScrollController? controller,
  PageController? pageController,
}) {
  final view = PaginateFirestore(
    query: store.query,
    itemsPerPage: 2,
    // The public default is separately asserted below.
    maxAutomaticFillPages: budget ?? 3,
    itemsGlobalLimit: globalLimit,
    loadMoreLabel: 'Načítať ďalšie',
    reverse: reverse,
    shrinkWrap: shrinkWrap || nested,
    scrollDirection: axis,
    scrollController: controller,
    pageController: pageController,
    isLive: live,
    includeMetadataChanges: metadata,
    listeners: listeners,
    itemBuilderType: type,
    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 2,
      mainAxisExtent: itemExtent,
    ),
    itemBuilder: (context, docs, index) =>
        hidden || (hideLaterItems && index >= 2)
            ? const SizedBox.shrink()
            : SizedBox(
                width: itemExtent,
                height: itemExtent,
                child: Text(docs[index].reference.path),
              ),
  );
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 300,
          height: 300,
          child: nested
              ? SingleChildScrollView(
                  child: Column(children: [
                    view,
                    const SizedBox(height: 1000),
                  ]),
                )
              : view,
        ),
      ),
    ),
  );
}

List<TestDocument> page(int index) => [
      TestDocument('items/${index * 2}', 'match'),
      TestDocument('items/${index * 2 + 1}', 'match'),
    ];

Future<void> frames(WidgetTester tester, [int count = 5]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  final button = find.widgetWithText(TextButton, 'Načítať ďalšie');

  test('automatic fill defaults to three additional pages', () {
    final widget = PaginateFirestore(
      query: RecordingFirestore().query,
      itemBuilderType: PaginateBuilderType.listView,
      itemBuilder: (_, docs, index) => const SizedBox(),
    );
    expect(widget.maxAutomaticFillPages, 3);
  });

  for (final type in [
    PaginateBuilderType.listView,
    PaginateBuilderType.gridView
  ]) {
    for (final reverse in [false, true]) {
      testWidgets(
          '${type.name}, reverse=$reverse fills then waits for scrolling',
          (tester) async {
        final store = RecordingFirestore();
        final controller = ScrollController();
        await tester.pumpWidget(pagination(store,
            type: type,
            reverse: reverse,
            controller: controller,
            itemExtent: type == PaginateBuilderType.gridView ? 100 : 50));
        // Each page contributes 100 px of actual content to a 300 px viewport.
        for (var i = 0; i < 3; i++) {
          expect(store.requests, hasLength(i + 1));
          store.requests.last.respond(page(i));
          await frames(tester);
        }
        await tester.pumpAndSettle();
        expect(store.requests, hasLength(3));

        // Programmatic movement and the continuously visible control do not
        // spend the remaining automatic allowance after the viewport is full.
        controller.jumpTo(controller.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(store.requests, hasLength(3));
        await tester.drag(
            find.byType(CustomScrollView), Offset(0, reverse ? 100 : -100));
        await frames(tester);
        expect(store.requests, hasLength(4));
        expect(store.requests.last.query.cursor!.reference.path, 'items/5');
        // Scrolling/rebuilding during an outstanding request cannot overlap it.
        await tester.drag(
            find.byType(CustomScrollView), Offset(0, reverse ? 100 : -100));
        await frames(tester);
        expect(store.requests, hasLength(4));
        store.requests.last.respond(page(3));
        await tester.pumpAndSettle();
        expect(store.requests, hasLength(4));
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      });
    }
  }

  for (final reverse in [false, true]) {
    testWidgets(
        'zero-height rows spend the budget; one tap reads one page '
        '(reverse=$reverse)', (tester) async {
      final store = RecordingFirestore();
      Widget build() => pagination(store, hidden: true, reverse: reverse);
      await tester.pumpWidget(build());
      for (var i = 0; i < 4; i++) {
        expect(store.requests, hasLength(i + 1));
        store.requests.last.respond(page(i));
        await frames(tester);
      }
      await tester.pumpAndSettle();
      expect(store.requests, hasLength(4));
      expect(button, findsOneWidget);
      expect(find.text('Load more'), findsNothing);
      for (var i = 0; i < 5; i++) {
        await tester.pumpWidget(build());
      }
      expect(store.requests, hasLength(4));
      await tester.tap(button);
      await frames(tester);
      expect(store.requests, hasLength(5));
      store.requests.last.respond(page(4));
      await tester.pumpAndSettle();
      expect(store.requests, hasLength(5));
      expect(button, findsOneWidget);
      expect(store.requests.map((r) => r.query).toSet(), hasLength(5));
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
      'a zero budget disables filling; a tap still requests just one page',
      (tester) async {
    final store = RecordingFirestore();
    await tester.pumpWidget(pagination(store, budget: 0, hidden: true));
    store.requests.single.respond(page(0));
    await tester.pumpAndSettle();
    expect(store.requests, hasLength(1));
    await tester.tap(button);
    await frames(tester);
    expect(store.requests, hasLength(2));
    store.requests.last.respond(page(1));
    await tester.pumpAndSettle();
    expect(store.requests, hasLength(2));
  });

  testWidgets('one continuing gesture cannot chain no-growth pages',
      (tester) async {
    final store = RecordingFirestore();
    await tester
        .pumpWidget(pagination(store, itemExtent: 150, hideLaterItems: true));
    store.requests.single.respond(page(0));
    await tester.pumpAndSettle();
    expect(store.requests, hasLength(1));
    final gesture = await tester.startGesture(const Offset(150, 150));
    await gesture.moveBy(const Offset(0, -60));
    await frames(tester);
    expect(store.requests, hasLength(2));
    store.requests.last.respond(page(1));
    await frames(tester);
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(0, -20));
      await frames(tester);
      expect(store.requests, hasLength(2));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(store.requests, hasLength(2));
  });

  testWidgets(
      'live updates and filtering cannot restart a completed fill cycle',
      (tester) async {
    final store = RecordingFirestore();
    final filter = PaginateFilterChangeListener();
    Widget build() =>
        pagination(store, live: true, itemExtent: 150, listeners: [filter]);
    await tester.pumpWidget(build());
    store.requests.single.respond(page(0));
    await tester.pumpAndSettle();
    expect(store.requests, hasLength(1));
    for (var i = 0; i < 5; i++) {
      filter.searchTerm = i.isEven ? 'missing' : '';
      store.requests.single.respond(page(0));
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();
    }
    expect(store.requests, hasLength(1));
    expect(button, findsOneWidget);
    // A manual page still must not restart the unused three-page allowance.
    await tester.tap(button);
    await frames(tester);
    expect(store.requests, hasLength(2));
    store.requests.last.respond(page(1));
    await tester.pumpAndSettle();
    expect(store.requests, hasLength(2));
    await tester.pumpWidget(const SizedBox());
    filter.dispose();
  });

  testWidgets('a short page confirms the end before the fill budget is spent',
      (tester) async {
    final store = RecordingFirestore();
    await tester.pumpWidget(pagination(store, hidden: true));
    store.requests.single.respond(page(0));
    await frames(tester);
    store.requests.last.respond([TestDocument('items/last')]);
    await tester.pumpAndSettle();
    expect(store.requests, hasLength(2));
    expect(button, findsNothing);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(store.requests, hasLength(2));
  });

  testWidgets('global limit truncates the final request and stops filling',
      (tester) async {
    final store = RecordingFirestore();
    await tester.pumpWidget(pagination(store, hidden: true, globalLimit: 3));
    store.requests.single.respond(page(0));
    await frames(tester);
    expect(store.requests, hasLength(2));
    expect(store.requests.last.query.pageLimit, 1);
    store.requests.last.respond([TestDocument('items/last')]);
    await tester.pumpAndSettle();
    expect(store.requests, hasLength(2));
    expect(button, findsNothing);
  });

  testWidgets(
      'live inserts after a confirmed end do not restart automatic filling',
      (tester) async {
    final store = RecordingFirestore();
    await tester.pumpWidget(pagination(store, live: true));
    store.requests.single.respond([page(0).first]);
    await tester.pumpAndSettle();
    expect(button, findsNothing);
    store.requests.single.respond(page(0));
    await tester.pumpAndSettle();
    expect(store.requests, hasLength(1));
    expect(button, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final live in [false, true]) {
    testWidgets(
        'error and explicit retry stop filling and retain pages (live=$live)',
        (tester) async {
      final store = RecordingFirestore();
      final retry = PaginateRetryChangeListener();
      Widget build() => pagination(store, live: live, listeners: [retry]);
      await tester.pumpWidget(build());
      store.requests.single.respond(page(0));
      await frames(tester);
      final failedQuery = store.requests.last.query;
      store.requests.last.fail(Exception('denied'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 5; i++) {
        await tester.pumpWidget(build());
      }
      expect(store.requests, hasLength(2));
      for (var i = 0; i < 5; i++) {
        retry.retry();
      }
      await frames(tester);
      expect(store.requests, hasLength(3));
      expect(store.requests.last.query, failedQuery);
      store.requests.last.respond(page(1));
      await tester.pumpAndSettle();
      expect(find.text('items/0'), findsOneWidget);
      expect(find.text('items/2'), findsOneWidget);
      expect(store.requests.first.cancelled, isFalse);
      expect(button, findsOneWidget);
      expect(store.requests, hasLength(3));
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();
      expect(store.requests, hasLength(3));
      await tester.pumpWidget(const SizedBox());
      retry.dispose();
    });
  }

  for (final type in [
    PaginateBuilderType.listView,
    PaginateBuilderType.gridView
  ]) {
    testWidgets(
        'filtered pages, rebuilds and live confirmations share one budget '
        'in ${type.name}', (tester) async {
      final store = RecordingFirestore();
      final filter = PaginateFilterChangeListener()..searchTerm = 'missing';
      Widget build(bool metadata) => pagination(store,
          type: type, live: true, metadata: metadata, listeners: [filter]);
      await tester.pumpWidget(build(false));
      for (var i = 0; i < 4; i++) {
        expect(store.requests, hasLength(i + 1));
        store.requests.last.respond(page(i), fromCache: true);
        await frames(tester);
        expect(store.requests, hasLength(i + 1));
        store.requests.last.respond(page(i), metadataOnly: true);
        await frames(tester);
      }
      await tester.pumpAndSettle();
      expect(store.requests, hasLength(4));
      expect(button, findsOneWidget);
      for (var i = 0; i < 6; i++) {
        filter.searchTerm = i.isEven ? 'another missing term' : 'missing';
        store.requests.first.respond(page(0), metadataOnly: i.isEven);
        await tester.pumpWidget(build(i.isEven));
        await frames(tester);
      }
      expect(store.requests, hasLength(4));
      expect(button, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      filter.dispose();
    });

    testWidgets('unbounded nested ${type.name} uses bounded fallback',
        (tester) async {
      final store = RecordingFirestore();
      await tester.pumpWidget(pagination(store, nested: true, type: type));
      store.requests.single.respond(page(0));
      await frames(tester);
      expect(store.requests, hasLength(2));
      store.requests.last.respond(page(1));
      await tester.pumpAndSettle();
      expect(button, findsOneWidget);
      for (var i = 0; i < 3; i++) {
        await tester.drag(
            find.byType(SingleChildScrollView), const Offset(0, -100));
        await tester.pumpAndSettle();
      }
      expect(store.requests, hasLength(2));
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('bounded shrink-wrapped and horizontal lists fill their viewport',
      (tester) async {
    for (final axis in Axis.values) {
      final store = RecordingFirestore();
      await tester.pumpWidget(pagination(store, shrinkWrap: true, axis: axis));
      for (var i = 0; i < 3; i++) {
        expect(store.requests, hasLength(i + 1));
        store.requests.last.respond(page(i));
        await frames(tester);
      }
      await tester.pumpAndSettle();
      expect(store.requests, hasLength(3));
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('refresh and new query reset the fill budget', (tester) async {
    final first = RecordingFirestore();
    final second = RecordingFirestore();
    final refresh = PaginateRefreshedChangeListener();
    Widget build(RecordingFirestore store) =>
        pagination(store, hidden: true, listeners: [refresh]);
    await tester.pumpWidget(build(first));
    for (var i = 0; i < 4; i++) {
      first.requests.last.respond(page(i));
      await frames(tester);
    }
    expect(first.requests, hasLength(4));
    refresh.refreshed = true;
    await frames(tester);
    for (var i = 0; i < 4; i++) {
      expect(first.requests, hasLength(5 + i));
      first.requests.last.respond(page(i));
      await frames(tester);
    }
    expect(first.requests, hasLength(8));
    await tester.pumpWidget(build(second));
    for (var i = 0; i < 4; i++) {
      expect(second.requests, hasLength(i + 1));
      second.requests.last.respond(page(i));
      await frames(tester);
    }
    expect(second.requests, hasLength(4));
    await tester.pumpWidget(const SizedBox());
    refresh.dispose();
  });

  testWidgets('PageView retains one automatic prefetch when its tail is built',
      (tester) async {
    final store = RecordingFirestore();
    final controller = PageController(initialPage: 2);
    await tester.pumpWidget(pagination(store,
        type: PaginateBuilderType.pageView, pageController: controller));
    store.requests.single.respond(page(0));
    await frames(tester);
    expect(store.requests, hasLength(2));
    store.requests.last.respond(page(1));
    await tester.pumpAndSettle();
    controller.jumpToPage(4);
    await tester.pumpAndSettle();
    expect(button, findsOneWidget);
    expect(store.requests, hasLength(2));
    await tester.tap(button);
    await frames(tester);
    expect(store.requests, hasLength(3));
    store.requests.last.respond(page(2));
    await tester.pumpAndSettle();
    expect(store.requests, hasLength(3));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
