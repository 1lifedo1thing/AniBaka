import 'package:baka/api/bangumi_account_api.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/instance.dart';
import 'package:baka/services/account/bangumi_session.dart';
import 'package:baka/services/collection/collection_repository.dart';
import 'package:baka/services/playback/history_repository.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void configureTestServices() {
  final session = AccountSession(
    Instances.sp,
    refreshTokens: (_) async => null,
  );
  final client = MockClient((_) async => http.Response('{}', 200));
  apiTransport = ApiTransport(
    session: session,
    client: client,
    version: 'test',
  );
  bangumiSession = BangumiSession(
    Instances.sp,
    session,
    BangumiApi(),
    const BangumiOAuthBroker(),
  );
  collections = CollectionRepository(session, bangumiSession);
  historyRepository = HistoryRepository(session, bangumiSession);
  sourceCatalog = SourceCatalog(Instances.sp);
  sourceRepository = SourceAdapterService(sourceCatalog);
  addTearDown(sourceRepository.close);
  addTearDown(sourceCatalog.dispose);
  addTearDown(bangumiSession.api.close);
  addTearDown(client.close);
}
