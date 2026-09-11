import 'package:baka/utils/bgm_utils.dart';

/// 播放历史数据模型
class PlayHistory {
  final int? id;
  final int? userId;
  final int videoId;
  final String videoTitle;
  final String? videoCover;
  final int videoDuration;
  final int playProgress;
  final double? playPercentage;
  final int? episodeId;
  final String? episodeTitle;
  final int? videoType;
  final String? platform;
  final int? bgmId;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final bool isFinished;

  PlayHistory({
    required this.videoId,
    required this.videoTitle,
    required this.videoDuration,
    required this.playProgress,
    this.id,
    this.userId,
    this.videoCover,
    this.playPercentage,
    this.episodeId,
    this.episodeTitle,
    this.videoType,
    this.platform,
    this.bgmId,
    this.createdAt,
    this.updatedAt,
    this.isFinished = false,
  });

  factory PlayHistory.fromJson(Map<String, dynamic> json) => PlayHistory(
    id: BgmUtils.toInt(json['id']),
    userId: BgmUtils.toInt(json['user_id']),
    videoId: BgmUtils.toInt(json['video_id']) ?? 0,
    videoTitle: json['video_title']?.toString() ?? '',
    videoCover: json['video_cover']?.toString(),
    videoDuration: BgmUtils.toInt(json['video_duration']) ?? 0,
    playProgress: BgmUtils.toInt(json['play_progress']) ?? 0,
    playPercentage: BgmUtils.toDouble(json['play_percentage']),
    episodeId: BgmUtils.toInt(json['episode_id']),
    episodeTitle: json['episode_title']?.toString(),
    videoType: BgmUtils.toInt(json['video_type']),
    platform: json['platform']?.toString(),
    bgmId: BgmUtils.toInt(json['bgm_id']),
    createdAt: json['created_at'] != null
        ? DateTime.tryParse(json['created_at'].toString())
        : null,
    updatedAt: json['updated_at'] != null
        ? DateTime.tryParse(json['updated_at'].toString())
        : null,
    isFinished: json['is_finished'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'video_id': videoId,
    'video_title': videoTitle,
    if (videoCover != null) 'video_cover': videoCover,
    'video_duration': videoDuration,
    'play_progress': playProgress,
    if (episodeId != null) 'episode_id': episodeId,
    if (episodeTitle != null) 'episode_title': episodeTitle,
    if (videoType != null) 'video_type': videoType,
    if (platform != null) 'platform': platform,
    if (bgmId != null) 'bgm_id': bgmId,
  };
}

/// 播放历史列表响应
class PlayHistoryListResponse {
  final List<PlayHistory> list;

  PlayHistoryListResponse({required this.list});

  factory PlayHistoryListResponse.fromJson(Map<String, dynamic> json) =>
      PlayHistoryListResponse(
        list: (json['list'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(PlayHistory.fromJson)
            .toList(growable: false),
      );
}
