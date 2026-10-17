# Pagination in Firestore

<!-- ALL-CONTRIBUTORS-BADGE:START - Do not remove or modify this section -->

[![All Contributors](https://img.shields.io/badge/all_contributors-10-orange.svg?style=flat-square)](#contributors-)

<!-- ALL-CONTRIBUTORS-BADGE:END -->

[![pub package](https://img.shields.io/pub/v/paginate_firestore.svg)](https://pub.dev/packages/paginate_firestore)
[![style: effective dart](https://img.shields.io/badge/style-effective_dart-40c4ff.svg)](https://github.com/tenhobi/effective_dart)
[![License: MIT](https://img.shields.io/badge/license-MIT-purple.svg)](https://opensource.org/licenses/MIT)

<p align="center">
  <img src="https://raw.githubusercontent.com/excogitatr/paginate_firestore/master/assets/screen.gif" height="500px">
</p>

## Setup

Use the same setup used for `cloud_firestore` package (or follow [this](https://pub.dev/packages/cloud_firestore#setup)).

## Usage

In your pubspec.yaml

```yaml
dependencies:
  paginate_firestore: # latest version
```

Import it

```dart
import 'package:paginate_firestore/paginate_firestore.dart';
```

Implement it

```dart
      PaginateFirestore(
        //item builder type is compulsory.
        itemBuilder: (context, documentSnapshots, index) {
          final data = documentSnapshots[index].data() as Map?;
          return ListTile(
            leading: CircleAvatar(child: Icon(Icons.person)),
            title: data == null ? Text('Error in data') : Text(data['name']),
            subtitle: Text(documentSnapshots[index].id),
          );
        },
           // Use a stable ordering for predictable pagination
        query: FirebaseFirestore.instance.collection('users').orderBy('name'),
        //Change types accordingly
        itemBuilderType: PaginateBuilderType.listView,
        // to fetch real-time data
        isLive: true,
      ),
```

To use with listeners:

```dart
      PaginateRefreshedChangeListener refreshChangeListener = PaginateRefreshedChangeListener();

      RefreshIndicator(
        child: PaginateFirestore(
          itemBuilder: (context, documentSnapshots, index) => ListTile(
            leading: CircleAvatar(child: Icon(Icons.person)),
            title: Text((documentSnapshots[index].data() as Map)['name']),
            subtitle: Text(documentSnapshots[index].id),
          ),
          // Use a stable ordering for predictable pagination
          query: FirebaseFirestore.instance.collection('users').orderBy('name'),
          itemBuilderType: PaginateBuilderType.listView,
          listeners: [
            refreshChangeListener,
          ],
        ),
        onRefresh: () async {
          refreshChangeListener.refreshed = true;
        },
      )
```

## Pagination behavior and Firestore reads

Pages use `startAfterDocument` and `limit`, so scrolling fetches the next page
without fetching all previous pages again. Concurrent fetch calls share one
request. A refresh cancels existing listeners and starts again from the original
cursor; results from older requests are ignored. Refreshing deliberately reads
the first page again.

`itemsGlobalLimit` caps the total document slots requested across pages. For
example, `itemsPerPage: 15` and `itemsGlobalLimit: 25` request 15 documents, then
10, and stop. A limit of zero makes no query. Filtering and live deletions do not
reset this allowance. It is **not a billing cap**: subsequent live updates,
refreshes and reconnects can cause more reads. Overlapping live pages can also
mean fewer unique displayed documents than the allowance.

| Configuration | Read behavior |
| --- | --- |
| `isLive: false` (default) | One `get()` per requested page. Best when refresh-on-demand is sufficient. |
| `isLive: true, isAllItemsLive: false` | One listener on the first page; later pages use `get()`. Historical pages remain unchanged until refresh. |
| `isLive: true, isAllItemsLive: true` (default for live mode) | One listener per requested page; updates to loaded pages stay visible. |

Larger pages reduce request/listener count but can fetch documents the user never
views. Scrolling prefetches when Flutter builds the bottom loader, which can occur
just before it becomes visible. Avoid `shrinkWrap: true` inside an unbounded outer
scroll view for large collections: laying out the list can build the loader and
trigger more pages even without scrolling.

Firestore charges for documents returned and for billable live changes, with
possible index and security-rule reads. Cursors avoid the skipped-document reads
incurred by offsets. A short page marks the end; an exactly full final page needs
one subsequent empty query to discover the end unless a global limit was reached.
Even an empty query has a minimum one-document read charge. Reconnecting listeners
can incur fresh-query charges depending on persistence and disconnect duration.
See [Firestore billing](https://firebase.google.com/docs/firestore/pricing).

### Live pagination boundaries

Every live page has its own fixed start cursor and limit. Updates to an earlier
page preserve later loaded pages and their pagination cursor. However, inserts,
deletes, or changes to ordered fields can move documents across these fixed
boundaries, causing overlaps or gaps. Duplicates are removed by full document
path, including for collection-group queries. **Refresh to reconcile page
membership after such changes.** First-page-only live mode has the same boundary
limitation, including for new messages in a descending chat feed. Prefer immutable
sort fields, and use one-time pagination when a stable browsing session matters.
The package does not automatically requery all loaded pages on every change.

Live listeners can first return an incomplete local cache. Cached documents may
be displayed, but fetching another page waits for a server-confirmed snapshot
without pending writes, including after later local changes to that page.
There is no timeout: live pagination can remain waiting while offline.
Internal metadata events allow this confirmation even
when the server data is identical; they do not open additional queries. An empty
cache alone does not show the empty state. For explicit offline browsing use
`isLive: false` with `options: GetOptions(source: Source.cache)`; its results and
end-of-list status describe the cache. See
[Firestore snapshot events](https://firebase.google.com/docs/firestore/query-data/listen).

With `includeMetadataChanges: false`, metadata-only confirmations do not repeat
`onLoaded` unless they change the end-of-list status. The visible loader resumes
pagination when confirmation arrives. `onLoaded` and `onReachedEnd` respond to
loaded state changes, not parent rebuilds; they can still run again after data,
filter, or end-of-list changes. `onLoaded` may describe cached data.

`PaginateFilterChangeListener` searches **only already loaded documents**, locally,
without Firestore reads. Changing or clearing the term always uses the full loaded
list. Removing a filter listener also clears its filter. Use a different
Firestore query for server-side filtering; updating `query`
or pagination settings restarts the widget automatically. A failed request is
reported through `onError`; refresh to retry. Controllers and notifier instances
passed to the widget remain owned by the caller and should be disposed there.

## Contributions

Feel free to contribute to this project.

If you find a bug or want a feature, but don't know how to fix/implement it, please fill an [issue](https://github.com/excogitatr/paginate_firestore/issues).
If you fixed a bug or implemented a feature, please send a [pull request](https://github.com/excogitatr/paginate_firestore/pulls).

## Getting Started

This project is a starting point for a Dart
[package](https://flutter.dev/developing-packages/),
a library module containing code that can be shared easily across
multiple Flutter or Dart projects.

For help getting started with Flutter, view our
[online documentation](https://flutter.dev/docs), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Contributors ✨

Thanks goes to these wonderful people:

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->
<table>
  <tr>
    <td align="center"><a href="https://adamdupuis.com"><img src="https://avatars1.githubusercontent.com/u/6547826?v=4?s=100" width="100px;" alt=""/><br /><sub><b>Adam Dupuis</b></sub></a><br /><a href="https://github.com/vedartm/paginate_firestore/commits?author=adamdupuis" title="Code">💻</a></td>
    <td align="center"><a href="https://gauthamasir.github.io/Portfolio_Dart/"><img src="https://avatars1.githubusercontent.com/u/26927742?v=4?s=100" width="100px;" alt=""/><br /><sub><b>Gautham</b></sub></a><br /><a href="https://github.com/vedartm/paginate_firestore/commits?author=GauthamAsir" title="Code">💻</a></td>
    <td align="center"><a href="https://github.com/imhafeez"><img src="https://avatars3.githubusercontent.com/u/21155655?v=4?s=100" width="100px;" alt=""/><br /><sub><b>Hafeez Ahmed</b></sub></a><br /><a href="https://github.com/vedartm/paginate_firestore/commits?author=imhafeez" title="Code">💻</a></td>
    <td align="center"><a href="https://claudemir.casa"><img src="https://avatars3.githubusercontent.com/u/7956750?v=4?s=100" width="100px;" alt=""/><br /><sub><b>Claudemir Casa</b></sub></a><br /><a href="https://github.com/vedartm/paginate_firestore/commits?author=claudemircasa" title="Code">💻</a></td>
    <td align="center"><a href="https://www.nikhil27.com"><img src="https://avatars.githubusercontent.com/u/45140298?v=4?s=100" width="100px;" alt=""/><br /><sub><b>Nikhil27bYt</b></sub></a><br /><a href="https://github.com/vedartm/paginate_firestore/commits?author=Nikhil27b" title="Documentation">📖</a></td>
    <td align="center"><a href="https://github.com/ghprod"><img src="https://avatars.githubusercontent.com/u/1922652?v=4?s=100" width="100px;" alt=""/><br /><sub><b>Ferri Sutanto</b></sub></a><br /><a href="https://github.com/vedartm/paginate_firestore/commits?author=ghprod" title="Code">💻</a></td>
    <td align="center"><a href="https://github.com/jslattery26"><img src="https://avatars.githubusercontent.com/u/44002583?v=4?s=100" width="100px;" alt=""/><br /><sub><b>jslattery26</b></sub></a><br /><a href="https://github.com/vedartm/paginate_firestore/commits?author=jslattery26" title="Code">💻</a></td>
  </tr>
  <tr>
    <td align="center"><a href="https://approachablegeek.com"><img src="https://avatars.githubusercontent.com/u/68708352?v=4?s=100" width="100px;" alt=""/><br /><sub><b>garrettApproachableGeek</b></sub></a><br /><a href="https://github.com/vedartm/paginate_firestore/commits?author=garrettApproachableGeek" title="Code">💻</a></td>
    <td align="center"><a href="https://www.suamusica.com.br/"><img src="https://avatars.githubusercontent.com/u/30954979?v=4?s=100" width="100px;" alt=""/><br /><sub><b>Sua Música</b></sub></a><br /><a href="https://github.com/vedartm/paginate_firestore/commits?author=SuaMusica" title="Code">💻</a></td>
    <td align="center"><a href="https://nelsonnerds.wordpress.com/"><img src="https://avatars.githubusercontent.com/u/1161152?v=4?s=100" width="100px;" alt=""/><br /><sub><b>Austin Nelson</b></sub></a><br /><a href="https://github.com/vedartm/paginate_firestore/commits?author=austinn" title="Code">💻</a></td>
  </tr>
</table>

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->

This project follows the [all-contributors](https://github.com/all-contributors/all-contributors) specification. Contributions of any kind welcome!
