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

  const PlayHistory({
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
    videoId: json['video_id'] as int,
    videoTitle: json['video_title'] as String,
    videoCover: json['video_cover'] as String?,
    videoDuration: json['video_duration'] as int,
    playProgress: json['play_progress'] as int,
    episodeId: json['episode_id'] as int?,
    episodeTitle: json['episode_title'] as String?,
    videoType: json['video_type'] as int?,
    platform: json['platform'] as String?,
    bgmId: json['bgm_id'] as int?,
    updatedAt: json['updated_at'] != null
        ? DateTime.parse(json['updated_at'] as String)
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
