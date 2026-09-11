import 'package:baka/services/playback/history_repository.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/services/source/rule_repository_service.dart';
import 'package:baka/services/download/download_manager.dart';
import 'package:baka/api/auth_api.dart';
import 'package:baka/api/api_config.dart';
import 'package:baka/api/bangumi_account_api.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/instance.dart';
import 'package:baka/services/account/bangumi_session.dart';
import 'package:baka/services/collection/collection_repository.dart';
import 'package:http/http.dart' as http;

ApiTransport? _previous;
void configureTestServices() {
  _previous?.close();
  final client = http.Client();
  final session = AccountSession(
    Instances.sp,
    refreshTokens: AuthApi(client, () => ApiConfig.host).refresh,
  );
  apiTransport = ApiTransport(
    session: session,
    client: client,
    version: 'test',
  );
  _previous = apiTransport;
  bangumiSession = BangumiSession(
    Instances.sp,
    session,
    BangumiApi(),
    const BangumiOAuthBroker(),
  );
  sourceCatalog = SourceCatalog(Instances.sp);
  sourceRepository = SourceAdapterService(sourceCatalog);
  ruleRepository = RuleRepositoryService(sourceRepository, sourceCatalog);
  downloads = DownloadService();
  historyRepository = HistoryRepository(session, bangumiSession);
  collections = CollectionRepository(session, bangumiSession);
}
