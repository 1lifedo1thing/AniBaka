import 'package:baka/models/anime_detail_view_data.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('detail', () {
    test('keeps the existing cover when richer detail data arrives', () {
      final detail = AnimeDetailViewData.from(
        source: const <String, dynamic>{'title': 'Example'},
        bgmInfo: const BgmInfo(imageUrl: 'https://example.test/bgm-cover.jpg'),
        anibaka: const <String, dynamic>{
          'images': {
            'posters': [
              {'url': 'https://example.test/poster.jpg'},
            ],
            'backdrops': [
              {'url': 'https://example.test/backdrop.jpg'},
              {'url': 'https://example.test/backdrop.jpg'},
              {'url': ''},
            ],
          },
        },
      );

      expect(detail.coverUrl, 'https://example.test/bgm-cover.jpg');
      expect(detail.backgroundUrl, 'https://example.test/backdrop.jpg');
      expect(detail.backdrops, hasLength(1));
    });

    test('uses the detail poster when the existing item has no cover', () {
      final detail = AnimeDetailViewData.from(
        source: const <String, dynamic>{'title': 'Example'},
        bgmInfo: const BgmInfo(),
        anibaka: const <String, dynamic>{
          'images': {
            'posters': [
              {'url': 'https://example.test/poster.jpg'},
            ],
          },
        },
      );

      expect(detail.coverUrl, 'https://example.test/poster.jpg');
    });

    test('falls back to the cover when the API has no backdrop', () {
      final detail = AnimeDetailViewData.from(
        source: const <String, dynamic>{'title': 'Example'},
        bgmInfo: const BgmInfo(imageUrl: 'https://example.test/cover.jpg'),
      );

      expect(detail.coverUrl, 'https://example.test/cover.jpg');
      expect(detail.backgroundUrl, detail.coverUrl);
    });

    test('parses bangumi 1-10 score distribution for the desktop chart', () {
      final detail = AnimeDetailViewData.from(
        source: const <String, dynamic>{'title': 'Example'},
        bgmInfo: const BgmInfo(score: 8.2),
        bgm: const <String, dynamic>{
          'rating': {
            'score': 8.2,
            'total': 100,
            'rank': 42,
            'count': {
              '1': 1,
              '2': 0,
              '3': 2,
              '4': 3,
              '5': 5,
              '6': 10,
              '7': 20,
              '8': 30,
              '9': 20,
              '10': 9,
            },
          },
        },
      );

      expect(detail.score, 8.2);
      expect(detail.rank, 42);
      expect(detail.hasScoreDistribution, isTrue);
      expect(detail.scoreDistribution, [1, 0, 2, 3, 5, 10, 20, 30, 20, 9]);
    });

    test('selects the localized logo used by the player', () {
      final logo = AnimeDetailViewData.resolveLogoUrl(const <String, dynamic>{
        'images': {
          'logos': [
            {'url': 'https://example.test/en-logo.png', 'lang': 'en'},
            {'url': 'https://example.test/zh-logo.png', 'lang': 'zh'},
          ],
        },
      });

      expect(logo, 'https://example.test/zh-logo.png');
    });
  });

  group('images', () {
    test(
      'builds a cached BGM cover URL without exposing the blocked image host',
      () {
        final url = Uri.parse(BgmUtils.bgmCoverProxyUrl(400602));

        expect(url.host, 'wsrv.nl');
        expect(url.queryParameters['w'], '360');
        expect(url.queryParameters['output'], 'webp');
        expect(
          url.queryParameters['url'],
          'https://api.bgm.tv/v0/subjects/400602/image?type=large',
        );
      },
    );

    test('bgmImageProxyUrl unwraps WordPress Photon before wsrv.nl', () {
      final proxied = BgmUtils.bgmImageProxyUrl(
        'https://i1.wp.com/lain.bgm.tv/r/100/pic/user/l/000/00/41/4199.jpg?r=1366790712',
        width: 120,
      );
      final uri = Uri.parse(proxied);
      expect(uri.host, 'wsrv.nl');
      expect(uri.queryParameters['w'], '120');
      // Nested i1.wp.com would make wsrv.nl return 400.
      expect(uri.queryParameters['url'], isNot(contains('i1.wp.com')));
      expect(
        uri.queryParameters['url'],
        'https://lain.bgm.tv/r/100/pic/user/l/000/00/41/4199.jpg?r=1366790712',
      );
    });

    test('pickAvatarUrl prefers medium then large then small', () {
      expect(
        BgmUtils.pickAvatarUrl({
          'small': 'https://example.test/s.jpg',
          'medium': 'https://example.test/m.jpg',
          'large': 'https://example.test/l.jpg',
        }),
        'https://example.test/m.jpg',
      );
      expect(
        BgmUtils.pickAvatarUrl({'small': 'https://example.test/s.jpg'}),
        'https://example.test/s.jpg',
      );
      expect(
        BgmUtils.pickAvatarUrl('https://example.test/a.jpg'),
        'https://example.test/a.jpg',
      );
      expect(BgmUtils.pickAvatarUrl(null), '');
    });

    group('pickAniBakaTmdbBackdrop', () {
      test(
        'prefers the Chinese TMDB backdrop over BGM and other languages',
        () {
          final detail = <String, dynamic>{
            'images': {
              'backdrops': [
                {
                  'source': 'bgm',
                  'lang': 'zh',
                  'url': 'https://example.test/bgm.jpg',
                },
                {
                  'source': 'tmdb',
                  'lang': 'ja',
                  'url': 'https://example.test/tmdb-ja.jpg',
                },
                {
                  'source': 'tmdb',
                  'lang': 'zh',
                  'url': 'https://example.test/tmdb-zh.jpg',
                },
              ],
            },
          };

          expect(
            BgmUtils.pickAniBakaTmdbBackdrop(detail),
            'https://example.test/tmdb-zh.jpg',
          );
        },
      );

      test('uses another TMDB backdrop when no Chinese variant exists', () {
        final detail = <String, dynamic>{
          'images': {
            'backdrops': [
              {
                'source': 'tmdb',
                'lang': 'ja',
                'thumbnail': 'https://example.test/tmdb-ja-thumb.jpg',
              },
            ],
          },
        };

        expect(
          BgmUtils.pickAniBakaTmdbBackdrop(detail),
          'https://example.test/tmdb-ja-thumb.jpg',
        );
      });

      test('does not treat a BGM backdrop as a TMDB backdrop', () {
        final detail = <String, dynamic>{
          'images': {
            'backdrops': [
              {'source': 'bgm', 'url': 'https://example.test/bgm.jpg'},
            ],
          },
        };

        expect(BgmUtils.pickAniBakaTmdbBackdrop(detail), isNull);
      });

      test('ignores posters when picking the backdrop', () {
        final detail = <String, dynamic>{
          'images': {
            'posters': [
              {'source': 'tmdb', 'url': 'https://example.test/poster.jpg'},
            ],
            'backdrops': [
              {'source': 'bgm', 'url': 'https://example.test/bgm-backdrop.jpg'},
              {
                'source': 'tmdb',
                'url': 'https://example.test/tmdb-backdrop.jpg',
              },
            ],
          },
        };

        expect(
          BgmUtils.pickAniBakaTmdbBackdrop(detail),
          'https://example.test/tmdb-backdrop.jpg',
        );
      });
    });
  });
}
