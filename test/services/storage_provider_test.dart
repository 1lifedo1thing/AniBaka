import 'dart:async';
import 'dart:io';

import 'package:baka/storage/webdav_storage_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'WebDAV listing returns playable paths across namespace prefixes',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requestCompleter = Completer<HttpRequest>();
      server.listen(requestCompleter.complete);
      final provider = WebDavStorageProvider(
        baseUrl: 'http://${server.address.host}:${server.port}/dav/',
        username: 'user',
        password: 'pass',
        rootPath: '/anime',
      );

      try {
        final resultFuture = provider.listDirectory('/anime');
        final request = await requestCompleter.future;
        expect(request.method, 'PROPFIND');
        expect(request.uri.path, '/dav/anime/');
        expect(request.headers.value('depth'), '1');
        await request.drain<void>();

        request.response
          ..statusCode = 207
          ..headers.contentType = ContentType(
            'application',
            'xml',
            charset: 'utf-8',
          )
          ..write('''<?xml version="1.0"?>
<x:multistatus xmlns:x="DAV:">
  <x:response>
    <x:href>/dav/anime/</x:href>
    <x:propstat><x:prop><x:resourcetype><x:collection/></x:resourcetype></x:prop></x:propstat>
  </x:response>
  <x:response>
    <x:href>/dav/anime/Season%201/</x:href>
    <x:propstat><x:prop>
      <x:displayname>Season 1</x:displayname>
      <x:resourcetype><x:collection/></x:resourcetype>
    </x:prop></x:propstat>
  </x:response>
  <x:response>
    <x:href>/dav/anime/Episode%2001.mkv</x:href>
    <x:propstat><x:prop>
      <x:displayname>Episode &amp; 01.mkv</x:displayname>
      <x:getcontentlength>2048</x:getcontentlength>
      <x:getlastmodified>Wed, 15 Nov 1995 04:58:08 GMT</x:getlastmodified>
      <x:resourcetype/>
    </x:prop></x:propstat>
  </x:response>
</x:multistatus>''');
        await request.response.close();

        final items = await resultFuture;
        expect(items, hasLength(2));
        expect(items.first.name, 'Season 1');
        expect(items.first.path, '/anime/Season 1/');
        expect(items.first.isDirectory, isTrue);
        expect(items.last.name, 'Episode & 01.mkv');
        expect(items.last.path, '/anime/Episode 01.mkv');
        expect(items.last.size, 2048);
        expect(items.last.modified, DateTime.utc(1995, 11, 15, 4, 58, 8));
        expect(
          provider.playableUrl(items.last.path),
          'http://${server.address.host}:${server.port}/dav/anime/Episode%2001.mkv',
        );
        expect(provider.httpHeaders, contains('Authorization'));
      } finally {
        provider.dispose();
        await server.close(force: true);
      }
    },
  );
}
