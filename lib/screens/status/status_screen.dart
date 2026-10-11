import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:video_player/video_player.dart';

import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../services/status_service.dart';
import '../../services/app_localizations.dart';

class StatusScreen extends StatefulWidget {
  const StatusScreen({super.key});

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  List<Map<String, dynamic>> _statuses = [];
  bool _isLoading = true;
  int _myStatusRefreshKey = 0;

  @override
  void initState() {
    super.initState();
    _loadStatuses();
    unawaited(StatusService.deleteExpiredStatuses());
  }

  String? get _myUid {
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    return auth.user?.uid ?? auth.mockUserId;
  }

  Future<void> _loadStatuses() async {
    setState(() => _isLoading = true);
    final userId = _myUid;

    if (userId != null) {
      final statuses = await StatusService.getContactStatuses(userId);
      if (!mounted) return;
      setState(() {
        _statuses = statuses;
        _isLoading = false;
      });
    } else {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final picked =
        await picker.pickImage(source: ImageSource.gallery, maxWidth: 1080);
    if (picked == null) return;

    final userId = _myUid;
    if (userId == null) return;

    setState(() => _isLoading = true);

    final url = await StatusService.uploadStatusMedia(
        File(picked.path), userId, 'image');
    if (url != null) {
      await StatusService.createMediaStatus(userId, url, 'image');
      await _refreshAll();
    }

    if (!mounted) return;
    setState(() => _isLoading = false);
  }

  Future<void> _pickVideo() async {
    final picker = ImagePicker();
    final picked = await picker.pickVideo(source: ImageSource.gallery);
    if (picked == null) return;

    final userId = _myUid;
    if (userId == null) return;

    setState(() => _isLoading = true);

    final url = await StatusService.uploadStatusMedia(
        File(picked.path), userId, 'video');
    if (url != null) {
      await StatusService.createMediaStatus(userId, url, 'video');
      await _refreshAll();
    }

    if (!mounted) return;
    setState(() => _isLoading = false);
  }

  Future<void> _addTextStatus() async {
    final theme = Theme.of(context);
    final controller = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.get('text_status') ?? 'Text Status'),
        content: TextField(
          controller: controller,
          maxLength: 140,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: "What's on your mind?",
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (controller.text.trim().isEmpty) return;
              final userId = _myUid;
              if (userId == null) return;

              Navigator.pop(context);
              setState(() => _isLoading = true);

              await StatusService.createTextStatus(
                  userId, controller.text.trim());
              await _refreshAll();

              if (!mounted) return;
              setState(() => _isLoading = false);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.colorScheme.primary,
            ),
            child: const Text('Post'),
          ),
        ],
      ),
    );
  }

  Future<void> _refreshAll() async {
    await _loadStatuses();
    if (mounted) setState(() => _myStatusRefreshKey++);
  }

  void _viewStatus(Map<String, dynamic> status) async {
    final userId = _myUid;

    if (userId != null && status['user_id'] != userId) {
      await StatusService.markAsViewed(status['id'], userId);
    }

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StatusViewerScreen(status: status),
      ),
    ).then((_) => _refreshAll());
  }

  void _onMyStatusTap(List<Map<String, dynamic>> myStatuses) async {
    if (myStatuses.isEmpty) {
      _showAddStatusOptions(context);
      return;
    }

    final latestStatus = myStatuses.first;
    final userId = _myUid;

    if (userId != null) {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();
      final userData = userDoc.data();

      final statusWithUser = {
        ...latestStatus,
        'is_mine': true,
        'users': {
          'username': userData?['username'] ?? 'You',
          'avatar_url': userData?['avatar_url'],
        },
      };

      if (mounted) _viewStatus(statusWithUser);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final userId = _myUid;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // App bar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Status',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.search),
                    onPressed: () =>
                        Navigator.pushNamed(context, '/global_search'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.more_vert),
                    onPressed: () => _showStatusMenu(context),
                  ),
                ],
              ),
            ),

            // My status row
            FutureBuilder<List<Map<String, dynamic>>>(
              key: ValueKey(_myStatusRefreshKey),
              future: userId != null
                  ? StatusService.getMyStatuses(userId)
                  : Future.value([]),
              builder: (context, snapshot) {
                final myStatuses = snapshot.data ?? [];
                final hasStatus = myStatuses.isNotEmpty;
                final latestStatus = hasStatus ? myStatuses.first : null;

                return Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _onMyStatusTap(myStatuses),
                    onLongPress: () => _showAddStatusOptions(context),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Stack(
                            children: [
                              Container(
                                width: 56,
                                height: 56,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: theme.colorScheme.primary
                                      .withOpacity(0.15),
                                  image: (hasStatus &&
                                          latestStatus?['media_url'] != null)
                                      ? DecorationImage(
                                          image: NetworkImage(
                                              latestStatus!['media_url']),
                                          fit: BoxFit.cover,
                                        )
                                      : null,
                                ),
                                child: !hasStatus ||
                                        latestStatus?['media_url'] == null
                                    ? Icon(Icons.person,
                                        color: theme.colorScheme.primary,
                                        size: 26)
                                    : null,
                              ),
                              Positioned(
                                bottom: 0,
                                right: 0,
                                child: GestureDetector(
                                  onTap: () =>
                                      _showAddStatusOptions(context),
                                  child: Container(
                                    padding: const EdgeInsets.all(2),
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primary,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: theme.scaffoldBackgroundColor,
                                        width: 2,
                                      ),
                                    ),
                                    child: const Icon(Icons.add,
                                        size: 14, color: Colors.white),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'My Status',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 15,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Row(
                                  children: [
                                    Text(
                                      hasStatus
                                          ? '${_getTimeAgo((latestStatus!['created_at'] as Timestamp).toDate())} • '
                                          : 'Tap + to add status',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                        color: theme.colorScheme.onSurface
                                            .withOpacity(0.5),
                                      ),
                                    ),
                                    if (hasStatus) ...[
                                      Icon(Icons.remove_red_eye,
                                          size: 12,
                                          color: theme.colorScheme.onSurface
                                              .withOpacity(0.4)),
                                      const SizedBox(width: 4),
                                      Text(
                                        '${latestStatus!['view_count'] ?? 0}',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                          color: theme.colorScheme.onSurface
                                              .withOpacity(0.4),
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),

            Divider(height: 0.5, color: theme.dividerColor),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _statuses.isEmpty ? 'NO UPDATES YET' : 'RECENT UPDATES',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                    letterSpacing: 0.6,
                  ),
                ),
              ),
            ),

            Expanded(
              child: _isLoading
                  ? Center(
                      child: CircularProgressIndicator(
                          color: theme.colorScheme.primary),
                    )
                  : _statuses.isEmpty
                      ? _emptyState(theme)
                      : RefreshIndicator(
                          onRefresh: _refreshAll,
                          color: theme.colorScheme.primary,
                          child: ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            itemCount: _statuses.length,
                            itemBuilder: (context, index) =>
                                _buildStatusItem(theme, _statuses[index]),
                          ),
                        ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: theme.colorScheme.primary,
        foregroundColor: Colors.white,
        elevation: 2,
        onPressed: () => _showAddStatusOptions(context),
        child: const Icon(Icons.camera_alt_outlined),
      ),
    );
  }

  Widget _emptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.donut_large_outlined,
              size: 72,
              color: theme.colorScheme.onSurface.withOpacity(0.15),
            ),
            const SizedBox(height: 16),
            Text(
              'No status updates',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              'Save contacts to see their status',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusItem(ThemeData theme, Map<String, dynamic> status) {
    final username = status['users']?['username'] ?? 'Unknown';
    final avatar = status['users']?['avatar_url'];
    final mediaUrl = status['media_url'];
    final caption = status['caption'] ?? '';
    final type = status['type'] ?? 'image';
    final createdAt = (status['created_at'] as Timestamp).toDate();
    final timeAgo = _getTimeAgo(createdAt);
    final isMine = status['is_mine'] == true;
    final viewCount = status['view_count'] ?? 0;
    final likes = status['likes'] ?? [];
    final gradientIndex = status['gradient_index'] ?? 0;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _viewStatus(status),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.primary.withOpacity(0.15),
                image: avatar != null
                    ? DecorationImage(
                        image: NetworkImage(avatar), fit: BoxFit.cover)
                    : null,
              ),
              child: avatar == null
                  ? Icon(Icons.person,
                      color: theme.colorScheme.primary, size: 26)
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isMine ? 'You' : username,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        timeAgo,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color:
                              theme.colorScheme.onSurface.withOpacity(0.5),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.remove_red_eye,
                          size: 13,
                          color: theme.colorScheme.onSurface.withOpacity(0.4)),
                      const SizedBox(width: 3),
                      Text(
                        '$viewCount',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color:
                              theme.colorScheme.onSurface.withOpacity(0.4),
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Icon(Icons.favorite,
                          size: 13,
                          color: theme.colorScheme.onSurface.withOpacity(0.4)),
                      const SizedBox(width: 3),
                      Text(
                        '${likes.length}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color:
                              theme.colorScheme.onSurface.withOpacity(0.4),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            type == 'text'
                ? Container(
                    width: 50,
                    height: 50,
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: _gradientFor(gradientIndex),
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Center(
                      child: Text(
                        caption.length > 20
                            ? '${caption.substring(0, 20)}...'
                            : caption,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.network(
                      mediaUrl ?? '',
                      width: 50,
                      height: 50,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 50,
                        height: 50,
                        color: theme.colorScheme.onSurface.withOpacity(0.08),
                        child: Icon(Icons.image_outlined,
                            color: theme.colorScheme.onSurface
                                .withOpacity(0.3)),
                      ),
                    ),
                  ),
          ],
        ),
      ),
    );
  }

  // ─── Gradient helper — matches CreateStatusScreen ───
  List<Color> _gradientFor(int i) {
    const gradients = [
      [Color(0xFF3390EC), Color(0xFF2B7CD3)],
      [Color(0xFFE0954A), Color(0xFFC97A2F)],
      [Color(0xFF8B7BB8), Color(0xFF6E5FA0)],
      [Color(0xFF4FAE4F), Color(0xFF3D8B3D)],
      [Color(0xFFE53935), Color(0xFFC62828)],
    ];
    return gradients[i.clamp(0, gradients.length - 1)];
  }

  String _getTimeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  // ── Bottom sheets ──

  void _showAddStatusOptions(BuildContext context) {
    _showFlatSheet(
      context,
      [
        _sheetTile(
          icon: Icons.camera_alt_outlined,
          label: 'Camera',
          onTap: () => Navigator.pop(context),
        ),
        _sheetTile(
          icon: Icons.photo_library_outlined,
          label: 'Gallery',
          onTap: () {
            Navigator.pop(context);
            _pickImage();
          },
        ),
        _sheetTile(
          icon: Icons.videocam_outlined,
          label: 'Video',
          onTap: () {
            Navigator.pop(context);
            _pickVideo();
          },
        ),
        _sheetTile(
          icon: Icons.text_fields,
          label: 'Text Status',
          onTap: () {
            Navigator.pop(context);
            _addTextStatus();
          },
        ),
      ],
    );
  }

  void _showStatusMenu(BuildContext context) {
    _showFlatSheet(
      context,
      [
        _sheetTile(
          icon: Icons.settings_outlined,
          label: AppLocalizations.get('settings') ?? 'Settings',
          onTap: () {
            Navigator.pop(context);
            Navigator.pushNamed(context, '/settings');
          },
        ),
        _sheetTile(
          icon: Icons.privacy_tip_outlined,
          label: AppLocalizations.get('privacy') ?? 'Privacy',
          onTap: () {
            Navigator.pop(context);
            Navigator.pushNamed(context, '/privacy_settings');
          },
        ),
      ],
    );
  }

  void _showFlatSheet(BuildContext context, List<Widget> children) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: theme.brightness == Brightness.dark
          ? const Color(0xFF1F1F1F)
          : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: theme.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ...children,
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(icon, color: theme.colorScheme.primary),
      title: Text(label, style: const TextStyle(fontSize: 15)),
      onTap: onTap,
    );
  }
}

// ============================================================================
// STATUS VIEWER SCREEN — pure black, gradient-aware
// ============================================================================
class StatusViewerScreen extends StatefulWidget {
  final Map<String, dynamic> status;

  const StatusViewerScreen({super.key, required this.status});

  @override
  State<StatusViewerScreen> createState() => _StatusViewerScreenState();
}

class _StatusViewerScreenState extends State<StatusViewerScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _progressController;
  VideoPlayerController? _videoController;
  bool _isVideoReady = false;
  bool _isLiked = false;

  // Same palette as CreateStatusScreen — must stay in sync
  static const List<List<Color>> _textGradients = [
    [Color(0xFF3390EC), Color(0xFF2B7CD3)],
    [Color(0xFFE0954A), Color(0xFFC97A2F)],
    [Color(0xFF8B7BB8), Color(0xFF6E5FA0)],
    [Color(0xFF4FAE4F), Color(0xFF3D8B3D)],
    [Color(0xFFE53935), Color(0xFFC62828)],
  ];

  @override
  void initState() {
    super.initState();
    _initController();
    _checkIfLiked();
  }

  void _initController() {
    final type = widget.status['type'] ?? 'image';
    final duration = _getDuration(type);

    _progressController = AnimationController(
      vsync: this,
      duration: duration,
    );

    _progressController.forward().then((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  void _checkIfLiked() {
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    final userId = auth.user?.uid ?? auth.mockUserId;
    final likes = widget.status['likes'] ?? [];
    setState(() => _isLiked = likes.contains(userId));
  }

  Duration _getDuration(String type) {
    switch (type) {
      case 'video':
        return const Duration(seconds: 30);
      case 'text':
        return const Duration(seconds: 5);
      case 'image':
      default:
        return const Duration(seconds: 5);
    }
  }

  void _onVideoInitialized(VideoPlayerController controller) {
    if (!mounted) return;
    final videoDuration = controller.value.duration;
    if (videoDuration.inSeconds > 0) {
      _progressController.duration = videoDuration;
      _progressController.forward(from: _progressController.value);
    }
    setState(() => _isVideoReady = true);
  }

  void _pauseProgress() {
    if (_progressController.isAnimating) _progressController.stop();
  }

  void _resumeProgress() {
    if (!_progressController.isCompleted) _progressController.forward();
  }

  Future<void> _toggleLike(String statusId) async {
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    final userId = auth.user?.uid ?? auth.mockUserId;
    if (userId == null) return;

    await StatusService.toggleLike(statusId, userId);
    setState(() => _isLiked = !_isLiked);
  }

  void _showViewsList(String statusId) async {
    _pauseProgress();
    final views = await StatusService.getViews(statusId);

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1F1F1F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.15),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Viewed by ${views.length}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            if (views.isEmpty)
              Text(
                'No views yet',
                style: TextStyle(color: Colors.white.withOpacity(0.5)),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: views.length,
                  itemBuilder: (context, index) {
                    final view = views[index];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundImage: view['avatar_url'] != null
                            ? NetworkImage(view['avatar_url'])
                            : null,
                        backgroundColor: const Color(0xFF3390EC),
                        child: view['avatar_url'] == null
                            ? Text(
                                (view['username'] ?? '?')[0].toUpperCase(),
                                style: const TextStyle(color: Colors.white),
                              )
                            : null,
                      ),
                      title: Text(
                        view['username'] ?? 'Unknown',
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: Text(
                        _getTimeAgo(
                            (view['viewed_at'] as Timestamp).toDate()),
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.5)),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    ).whenComplete(() => _resumeProgress());
  }

  void _showReplyDialog(Map<String, dynamic> status) {
    _pauseProgress();
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
        title: const Text('Reply to Status',
            style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Type a message...',
            hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _resumeProgress();
            },
            child: Text('Cancel',
                style: TextStyle(color: Colors.white.withOpacity(0.6))),
          ),
          ElevatedButton(
            onPressed: () async {
              if (controller.text.trim().isEmpty) return;
              final auth =
                  Provider.of<LumaAuthProvider>(context, listen: false);
              final userId = auth.user?.uid ?? auth.mockUserId;
              if (userId == null) return;

              await StatusService.replyToStatus(
                  status['id'], userId, controller.text.trim());
              if (!mounted) return;
              Navigator.pop(context);
              _resumeProgress();

              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Reply sent!')),
              );
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF3390EC)),
            child: const Text('Send'),
          ),
        ],
      ),
    ).whenComplete(() => _resumeProgress());
  }

  @override
  void dispose() {
    _progressController.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    final userId = auth.user?.uid ?? auth.mockUserId;
    final isMine = status['user_id'] == userId || status['is_mine'] == true;
    final username = status['users']?['username'] ?? 'Unknown';
    final avatar = status['users']?['avatar_url'];
    final mediaUrl = status['media_url'];
    final caption = status['caption'] ?? '';
    final type = status['type'] ?? 'image';
    final viewCount = status['view_count'] ?? 0;
    final likes = status['likes'] ?? [];
    final gradientIndex = status['gradient_index'] ?? 0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => Navigator.pop(context),
        onLongPressStart: (_) => _pauseProgress(),
        onLongPressEnd: (_) => _resumeProgress(),
        child: Stack(
          children: [
            Center(
              child: type == 'text'
                  ? Container(
                      padding: const EdgeInsets.all(32),
                      margin: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: _textGradients[gradientIndex
                              .clamp(0, _textGradients.length - 1)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        caption,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : type == 'video' && mediaUrl != null
                      ? _buildVideoPlayer(mediaUrl)
                      : Image.network(
                          mediaUrl ?? '',
                          fit: BoxFit.contain,
                          width: double.infinity,
                          height: double.infinity,
                          errorBuilder: (_, __, ___) => const Center(
                            child: Icon(Icons.broken_image,
                                color: Colors.white30, size: 64),
                          ),
                        ),
            ),

            SafeArea(
              child: Column(
                children: [
                  AnimatedBuilder(
                    animation: _progressController,
                    builder: (context, child) {
                      return LinearProgressIndicator(
                        value: _progressController.value,
                        backgroundColor: Colors.white.withOpacity(0.2),
                        valueColor:
                            const AlwaysStoppedAnimation(Colors.white),
                        minHeight: 2.5,
                      );
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 20,
                          backgroundImage: avatar != null
                              ? NetworkImage(avatar)
                              : null,
                          backgroundColor: const Color(0xFF3390EC),
                          child: avatar == null
                              ? Text(
                                  username.isNotEmpty
                                      ? username[0].toUpperCase()
                                      : '?',
                                  style: const TextStyle(color: Colors.white),
                                )
                              : null,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                username,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 15,
                                ),
                              ),
                              Text(
                                _getTimeAgo((status['created_at']
                                        as Timestamp)
                                    .toDate()),
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.6),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black.withOpacity(0.8), Colors.transparent],
                  ),
                ),
                child: SafeArea(
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => _toggleLike(status['id']),
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.favorite,
                            color: _isLiked ? Colors.red : Colors.white,
                            size: 22,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${likes.length}',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 14),
                      ),
                      const SizedBox(width: 24),
                      GestureDetector(
                        onTap: isMine
                            ? () => _showViewsList(status['id'])
                            : null,
                        child: Row(
                          children: [
                            Icon(
                              Icons.remove_red_eye,
                              color: isMine
                                  ? Colors.white
                                  : Colors.white.withOpacity(0.5),
                              size: 20,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '$viewCount',
                              style: TextStyle(
                                color: isMine
                                    ? Colors.white
                                    : Colors.white.withOpacity(0.5),
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      if (!isMine)
                        GestureDetector(
                          onTap: () => _showReplyDialog(status),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF3390EC),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.reply,
                                    color: Colors.white, size: 18),
                                SizedBox(width: 6),
                                Text('Reply',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),

            if (caption.isNotEmpty && type != 'text')
              Positioned(
                bottom: 100,
                left: 16,
                right: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    caption,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoPlayer(String url) {
    _videoController = VideoPlayerController.networkUrl(Uri.parse(url));
    _videoController!.initialize().then((_) {
      _onVideoInitialized(_videoController!);
      _videoController!.play();
    });
    return VideoPlayer(_videoController!);
  }

  String _getTimeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }
}
