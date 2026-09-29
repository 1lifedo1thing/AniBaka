import 'package:baka/utils/json_values.dart';

/// 播放历史数据模型
class PlayHistory {
  final int videoId;
  final String videoTitle;
  final String? videoCover;
  final int videoDuration;
  final int playProgress;
  final int? episodeId;
  final String? episodeTitle;
  final int? videoType;
  final String? platform;
  final int? bgmId;
  final DateTime? updatedAt;

  PlayHistory({
    required this.videoId,
    required this.videoTitle,
    required this.videoDuration,
    required this.playProgress,
    this.videoCover,
    this.episodeId,
    this.episodeTitle,
    this.videoType,
    this.platform,
    this.bgmId,
    this.updatedAt,
  });

  factory PlayHistory.fromJson(Map<String, dynamic> json) => PlayHistory(
    videoId: toInt(json['video_id']) ?? 0,
    videoTitle: json['video_title']?.toString() ?? '',
    videoCover: json['video_cover']?.toString(),
    videoDuration: toInt(json['video_duration']) ?? 0,
    playProgress: toInt(json['play_progress']) ?? 0,
    episodeId: toInt(json['episode_id']),
    episodeTitle: json['episode_title']?.toString(),
    videoType: toInt(json['video_type']),
    platform: json['platform']?.toString(),
    bgmId: toInt(json['bgm_id']),
    updatedAt: json['updated_at'] != null
        ? DateTime.tryParse(json['updated_at'].toString())
        : null,
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
