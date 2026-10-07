import 'dart:math' as math;

import 'package:baka/api/bgm.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/format_utils.dart';
import 'package:baka/widgets/common/skeletonizer.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

String _voiceActorNames(Map<String, dynamic> character) {
  final actors = character['actors'] as List?;
  if (actors == null || actors.isEmpty) return '';

  final names = StringBuffer();
  for (final actor in actors) {
    final name = (actor as Map<String, dynamic>)['name'] as String;
    if (names.isNotEmpty) names.write(' / ');
    names.write(name);
  }
  return names.toString();
}

/// 统一的网络图片组件（封装 wsrv.nl 图片代理 + 缓存 + 错误处理）
class _NetImage extends StatelessWidget {
  final String url;
  final double? width;
  final double? height;
  final double borderRadius;
  final int proxyWidth;

  const _NetImage({
    required this.url,
    this.width,
    this.height,
    this.borderRadius = 0,
    this.proxyWidth = 240,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final proxyUrl = BgmUtils.bgmImageProxyUrl(url, width: proxyWidth);
    final fallbackBg = (isDark ? Colors.white : Colors.black).withValues(
      alpha: 0.05,
    );
    late final fallback = Container(
      width: width,
      height: height,
      color: fallbackBg,
      alignment: Alignment.center,
      child: Icon(
        Icons.person_off,
        color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.24),
        size: (width != null && width! < 50) ? 18 : 32,
      ),
    );
    final child = proxyUrl.isEmpty
        ? fallback
        : CachedNetworkImage(
            imageUrl: proxyUrl,
            width: width,
            height: height,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            memCacheWidth: proxyWidth,
            placeholder: (_, _) =>
                Container(width: width, height: height, color: fallbackBg),
            errorWidget: (_, _, _) => fallback,
          );

    return borderRadius > 0
        ? ClipRRect(
            borderRadius: BorderRadius.circular(borderRadius),
            child: child,
          )
        : child;
  }
}

/// 角色卡片（用于角色 Tab 的网格展示）
class CharacterCard extends StatelessWidget {
  final Map<String, dynamic> character;
  const CharacterCard({required this.character, super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final name = character['name'] as String;
    final role = character['relation'] as String;
    final voiceActor = _voiceActorNames(character);
    final images = character['images'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 3 / 4,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: _NetImage(
              url:
                  images?['large']?.toString() ??
                  images?['grid']?.toString() ??
                  '',
              borderRadius: 12,
              proxyWidth: 240,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          name,
          style: TextStyle(
            color: textColor,
            fontWeight: FontWeight.w600,
            fontSize: 13,
            height: 1.2,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (role.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            role,
            style: TextStyle(
              color: textColor.withValues(alpha: 0.6),
              fontSize: 11,
              height: 1.2,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (voiceActor.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            'CV: $voiceActor',
            style: TextStyle(
              color: textColor.withValues(alpha: 0.4),
              fontSize: 10,
              height: 1.2,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

/// 角色 Tab 的网格布局
class CharactersSection extends StatefulWidget {
  final int subjectId;

  const CharactersSection({required this.subjectId, super.key});

  @override
  State<CharactersSection> createState() => _CharactersSectionState();
}

class _CharactersSectionState extends State<CharactersSection>
    with AutomaticKeepAliveClientMixin {
  late Future<List<Map<String, dynamic>>> _characters = getBgmCharacters(
    widget.subjectId,
  );

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(covariant CharactersSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.subjectId != widget.subjectId) {
      _characters = getBgmCharacters(widget.subjectId);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _characters,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: TextButton(
              onPressed: () => setState(() {
                _characters = getBgmCharacters(widget.subjectId);
              }),
              child: const Text('角色加载失败，点击重试'),
            ),
          );
        }
        final characters = snapshot.data!;
        if (characters.isEmpty) return const Center(child: Text('暂无角色信息'));
        return LayoutBuilder(
          builder: (context, constraints) {
            final columns = math.max(
              3,
              ((constraints.maxWidth - 8) / 120).floor(),
            );
            final width =
                (constraints.maxWidth - 8 - 12 * (columns - 1)) / columns;
            final textScaler = MediaQuery.textScalerOf(context);
            return GridView.builder(
              key: PageStorageKey(widget.subjectId),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 16),
              physics: const BouncingScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 12,
                mainAxisSpacing: 24,
                mainAxisExtent:
                    width * 4 / 3 +
                    18 +
                    (textScaler.scale(13) * 1.2).ceilToDouble() +
                    (textScaler.scale(11) * 1.2).ceilToDouble() +
                    (textScaler.scale(10) * 1.2).ceilToDouble(),
              ),
              itemCount: characters.length,
              itemBuilder: (context, index) {
                final character = characters[index];
                return GestureDetector(
                  onTap: () => showCharacterDetailSheet(context, character),
                  behavior: HitTestBehavior.opaque,
                  child: CharacterCard(character: character),
                );
              },
            );
          },
        );
      },
    );
  }
}

/// 显示角色详情弹窗的便捷方法
void showCharacterDetailSheet(
  BuildContext context,
  Map<String, dynamic> character,
) {
  final characterId = character['id'] as int;
  HapticFeedback.selectionClick();
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.8),
    builder: (_) =>
        CharacterDetailSheet(characterId: characterId, initialData: character),
  );
}

/// 角色详情 + 评论底部弹窗
class CharacterDetailSheet extends StatefulWidget {
  final int characterId;
  final Map<String, dynamic>? initialData;

  const CharacterDetailSheet({
    required this.characterId,
    this.initialData,
    super.key,
  });

  @override
  State<CharacterDetailSheet> createState() => _CharacterDetailSheetState();
}

class _CharacterDetailSheetState extends State<CharacterDetailSheet> {
  Map<String, dynamic>? _charInfo;
  late Future<List<Map<String, dynamic>>> _comments;
  bool _isLoading = true;
  int _infoGeneration = 0;

  @override
  void initState() {
    super.initState();
    // 秒开预览：优先保留外部传入的角色基础信息
    _charInfo = widget.initialData;
    _loadInfo();
    _comments = getBgmCharacterComments(widget.characterId);
  }

  @override
  void didUpdateWidget(covariant CharacterDetailSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.characterId != widget.characterId) {
      _charInfo = widget.initialData;
      _isLoading = true;
      _loadInfo();
      _comments = getBgmCharacterComments(widget.characterId);
    }
  }

  Future<void> _loadInfo() async {
    final generation = ++_infoGeneration;
    try {
      final infoData = await getBgmCharacterInfo(widget.characterId);
      if (!mounted || generation != _infoGeneration) return;

      setState(() {
        _charInfo = infoData;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('获取角色详情失败: $e');
      if (mounted && generation == _infoGeneration) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fgColor = isDark ? Colors.white : Colors.black;
    final textColor = isDark ? Colors.white : Colors.black87;
    final summary = _charInfo?['summary']?.toString().trim() ?? '';
    final hasBasicData = _charInfo != null && _charInfo!.isNotEmpty;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      snap: true,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF121212) : const Color(0xFFF9F9F9),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: CustomScrollView(
            controller: scrollController,
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 12, bottom: 24),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: fgColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: AppSkeletonizer(
                  enabled: _isLoading && !hasBasicData,
                  child: _CharHeader(
                    relation: widget.initialData,
                    info:
                        _charInfo ??
                        (_isLoading
                            ? const {'name': '角色名称占位'}
                            : const {'name': '暂无角色信息'}),
                  ),
                ),
              ),
              if (summary.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                    child: Text(
                      summary,
                      style: TextStyle(
                        color: textColor.withValues(alpha: 0.8),
                        fontSize: 14,
                        height: 1.7,
                      ),
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Divider(
                    color: fgColor.withValues(alpha: 0.05),
                    height: 1,
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                  child: Text(
                    '评论',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: textColor,
                    ),
                  ),
                ),
              ),
              FutureBuilder<List<Map<String, dynamic>>>(
                future: _comments,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(40),
                        child: Center(
                          child: CircularProgressIndicator.adaptive(),
                        ),
                      ),
                    );
                  }
                  final comments = snapshot.data;
                  if (snapshot.hasError || comments!.isEmpty) {
                    return SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(40),
                        child: Center(
                          child: Text(
                            snapshot.hasError ? '评论加载失败' : '暂无评论',
                            style: TextStyle(
                              color: textColor.withValues(alpha: 0.4),
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    );
                  }
                  return SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) =>
                          _CharCommentItem(comment: comments[index]),
                      childCount: math.min(comments.length, 50),
                    ),
                  );
                },
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 32)),
            ],
          ),
        );
      },
    );
  }
}

/// 角色头部信息
class _CharHeader extends StatelessWidget {
  final Map<String, dynamic> info;
  final Map<String, dynamic>? relation;
  const _CharHeader({required this.info, this.relation});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final name = info['name'] as String;
    final nameCN = info['nameCN'] as String? ?? '';
    final role = relation?['relation'] as String?;
    final voiceActor = relation == null ? '' : _voiceActorNames(relation!);
    final collects = info['collects'] as int? ?? 0;
    final commentCount = info['comment'] as int? ?? 0;
    final infoStr =
        info['info']?.toString().replaceAll('\r\n', '\n').trim() ?? '';
    final images = info['images'] as Map?;
    final imageUrl =
        images?['large']?.toString() ?? images?['grid']?.toString() ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.15),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: _NetImage(
              url: imageUrl,
              width: 110,
              height: 154,
              borderRadius: 16,
              proxyWidth: 240,
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: textColor,
                    height: 1.1,
                  ),
                ),
                if (nameCN.isNotEmpty && nameCN != name) ...[
                  const SizedBox(height: 4),
                  Text(
                    nameCN,
                    style: TextStyle(
                      fontSize: 13,
                      color: textColor.withValues(alpha: 0.6),
                    ),
                  ),
                ],
                if (role != null && role.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    '定位：$role',
                    style: TextStyle(
                      fontSize: 12,
                      color: textColor.withValues(alpha: 0.6),
                    ),
                  ),
                ],
                if (voiceActor.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    'CV：$voiceActor',
                    style: TextStyle(
                      fontSize: 12,
                      color: textColor.withValues(alpha: 0.6),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (infoStr.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    infoStr,
                    style: TextStyle(
                      fontSize: 12,
                      color: textColor.withValues(alpha: 0.4),
                      height: 1.35,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (collects > 0 || commentCount > 0) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (collects > 0)
                        _badge(
                          Icons.favorite_rounded,
                          '$collects',
                          const Color(0xFFE57373),
                        ),
                      if (commentCount > 0)
                        _badge(
                          Icons.chat_bubble_rounded,
                          '$commentCount',
                          const Color(0xFF64B5F6),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 角色评论项
class _CharCommentItem extends StatelessWidget {
  final Map<String, dynamic> comment;
  const _CharCommentItem({required this.comment});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fgColor = isDark ? Colors.white : Colors.black;
    final textColor = isDark ? Colors.white : Colors.black87;
    final user = comment['user'] as Map<String, dynamic>? ?? const {};
    final nickname = user['nickname']?.toString() ?? '匿名';
    final content = comment['content'] as String;
    final createdAt = comment['createdAt'] as int;
    final replies = comment['replies'] as List<dynamic>;
    final timeStr = createdAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(createdAt * 1000).toRelativeTime()
        : '';
    final displayReplies = math.min(replies.length, 3);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _NetImage(
                url: (user['avatar'] as Map?)?['medium']?.toString() ?? '',
                width: 32,
                height: 32,
                borderRadius: 16,
                proxyWidth: 96,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      nickname,
                      style: TextStyle(
                        color: textColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (timeStr.isNotEmpty)
                      Text(
                        timeStr,
                        style: TextStyle(
                          color: textColor.withValues(alpha: 0.4),
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (content.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 44, top: 8),
              child: Text(
                BgmUtils.cleanBbCode(content),
                style: TextStyle(
                  color: textColor.withValues(alpha: 0.85),
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
          if (replies.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 44, top: 10),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: fgColor.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (int i = 0; i < displayReplies; i++)
                      Padding(
                        padding: EdgeInsets.only(
                          bottom: i < displayReplies - 1 ? 8 : 0,
                        ),
                        child: _replyRichText(replies[i] as Map, textColor),
                      ),
                    if (replies.length > 3)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '还有 ${replies.length - 3} 条回复',
                          style: const TextStyle(
                            color: Color(0xFF64B5F6),
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _replyRichText(Map reply, Color textColor) {
    final rNick = (reply['user'] as Map?)?['nickname']?.toString() ?? '匿名';
    final rContent = reply['content']?.toString() ?? '';
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: '$rNick  ',
            style: TextStyle(
              color: textColor,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(
            text: BgmUtils.cleanBbCode(rContent),
            style: TextStyle(
              color: textColor.withValues(alpha: 0.6),
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
