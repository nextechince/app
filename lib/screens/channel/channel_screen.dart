import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../services/cloudinary_service.dart';

class ChannelChatScreen extends StatefulWidget {
  final String channelId;
  final String channelName;
  final String? channelAvatar;

  const ChannelChatScreen({
    super.key,
    required this.channelId,
    required this.channelName,
    this.channelAvatar,
  });

  @override
  State<ChannelChatScreen> createState() => _ChannelChatScreenState();
}

class _ChannelChatScreenState extends State<ChannelChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _picker = ImagePicker();

  String? _currentUserId;
  String? _myRole = 'subscriber';
  bool _isMePremium = false;
  String? _channelWallpaper;
  bool _isSearching = false;
  bool _isLoading = true;

  // Channel Data
  Map<String, dynamic>? _channelData;
  bool _signaturesEnabled = false;
  String _mySignature = '';
  bool _commentsEnabled = true;
  int _subscriberCount = 0;

  List<Map<String, dynamic>> _messages = [];
  List<Map<String, dynamic>> _pinnedMessages = [];
  StreamSubscription? _messageSub;
  StreamSubscription? _channelSub;

  // View Tracking (Debounced)
  final Set<String> _viewedMessages = {};
  final Map<String, Timer> _viewTimers = {};

  // UI State
  String? _activePanel;
  bool _multiSelectMode = false;
  final Set<String> _selectedIds = {};

  final Map<String, dynamic> _userCache = {};
  final Map<String, VideoPlayerController> _videoControllers = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    _currentUserId = auth.user?.uid ?? auth.mockUserId;
    _mySignature = auth.displayName ?? 'Admin';
    if (_currentUserId == null) return;

    // Load local cache first (Offline mode)
    _loadLocalCache();

    _listenToChannel();
    _listenToMessages();
    _listenToPremium();
  }

  Future<void> _loadLocalCache() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString('channel_${widget.channelId}_messages');
    if (cached != null && mounted) {
      final decoded = List<Map<String, dynamic>>.from(jsonDecode(cached));
      setState(() {
        _messages = decoded;
        _isLoading = false;
      });
    }
  }

  Future<void> _saveLocalCache(List<Map<String, dynamic>> msgs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('channel_${widget.channelId}_messages', jsonEncode(msgs));
  }

  void _listenToChannel() {
    _channelSub = FirebaseFirestore.instance.collection('chats').doc(widget.channelId).snapshots().listen((doc) {
      if (mounted && doc.exists) {
        setState(() {
          _channelData = doc.data();
          _myRole = _channelData?['participants_data']?[_currentUserId]?['role'] ?? 'subscriber';
          _signaturesEnabled = _channelData?['settings']?['signatures_enabled'] == true;
          _commentsEnabled = _channelData?['settings']?['comments_enabled'] != false;
          _channelWallpaper = _channelData?['wallpaper_url'];
          _subscriberCount = (_channelData?['participants'] as List?)?.length ?? 0;
          _isLoading = false;
        });
        _loadPinnedMessages();
      }
    });
  }

  void _listenToMessages() {
    _messageSub = FirebaseFirestore.instance
        .collection('chats').doc(widget.channelId).collection('messages')
        .orderBy('created_at', descending: true).limit(50)
        .snapshots().listen((snap) {
      if (!mounted) return;
      final loaded = snap.docs.map((d) => {'id': d.id, ...d.data()}).where((m) => m['deleted_for_everyone'] != true).toList();
      
      for (var m in loaded) {
        final sid = m['sender_id'];
        if (sid != null && !_userCache.containsKey(sid)) _fetchUser(sid);
      }
      
      setState(() {
        _messages = loaded;
        _isLoading = false;
      });
      _saveLocalCache(loaded);
    });
  }

  Future<void> _fetchUser(String uid) async {
    final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    if (doc.exists && mounted) setState(() => _userCache[uid] = doc.data());
  }

  void _listenToPremium() {
    FirebaseFirestore.instance.collection('users').doc(_currentUserId).snapshots().listen((doc) {
      if (mounted && doc.exists) setState(() => _isMePremium = doc.data()?['is_premium'] == true);
    });
  }

  Future<void> _loadPinnedMessages() async {
    final snap = await FirebaseFirestore.instance.collection('chats').doc(widget.channelId).collection('pinned_messages').orderBy('pinned_at', descending: true).limit(1).get();
    if (mounted) setState(() => _pinnedMessages = snap.docs.map((d) => {'id': d.id, ...d.data()}).toList());
  }

  // ═══════════════════════════════════════════════════════════════════════
  // REAL VIEW COUNTING (Debounced 1s, Once per session)
  // ═══════════════════════════════════════════════════════════════════════
  void _trackView(String msgId) {
    if (_viewedMessages.contains(msgId)) return;
    
    _viewTimers[msgId]?.cancel();
    _viewTimers[msgId] = Timer(const Duration(seconds: 1), () async {
      if (!mounted) return;
      _viewedMessages.add(msgId);
      await FirebaseFirestore.instance.collection('chats').doc(widget.channelId).collection('messages').doc(msgId).update({
        'views': FieldValue.increment(1)
      });
    });
  }

  String _formatViews(int views) {
    if (views >= 1000000) return '${(views / 1000000).toStringAsFixed(1)}M';
    if (views >= 1000) return '${(views / 1000).toStringAsFixed(1)}K';
    return views.toString();
  }

  // ═══════════════════════════════════════════════════════════════════════
  // SENDING (ADMINS ONLY)
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _sendPost({bool silent = false, DateTime? scheduleAt}) async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _messageController.clear();
    final msgId = const Uuid().v4();
    
    await FirebaseFirestore.instance.collection('chats').doc(widget.channelId).collection('messages').doc(msgId).set({
      'id': msgId,
      'sender_id': _currentUserId,
      'text': text,
      'type': 'text',
      'media_type': 'text',
      'created_at': scheduleAt != null ? Timestamp.fromDate(scheduleAt) : FieldValue.serverTimestamp(),
      'is_silent': silent,
      // SNAPSHOT SIGNATURE
      'signature': _signaturesEnabled ? _mySignature : null,
      'views': 0,
      'is_read': true,
    });
    
    if (scheduleAt != null) _showSnack('Post scheduled for ${DateFormat('MMM d, HH:mm').format(scheduleAt)}');
  }

  Future<void> _pickAndSendMedia(String type) async {
    final x = type == 'image' ? await _picker.pickImage(source: ImageSource.gallery, imageQuality: 90) : await _picker.pickVideo(source: ImageSource.gallery);
    if (x == null) return;

    final file = File(x.path);
    final size = await file.length();
    final limit = _isMePremium ? (5 * 1024 * 1024 * 1024) : (200 * 1024 * 1024); 
    if (size > limit) { _showSnack(_isMePremium ? 'Max 5GB' : 'Upgrade to Premium for >200MB'); return; }

    _showSnack('Uploading...');
    final url = type == 'image' ? await CloudinaryService.uploadImage(file, 'luma/channels') : await CloudinaryService.uploadVideo(file, 'luma/channels');
    if (url == null) return;
    if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();

    final msgId = const Uuid().v4();
    await FirebaseFirestore.instance.collection('chats').doc(widget.channelId).collection('messages').doc(msgId).set({
      'id': msgId, 'sender_id': _currentUserId, 'type': type, 'media_type': type, 'media_url': url, 'created_at': FieldValue.serverTimestamp(), 'views': 0,
    });
  }

  // ═══════════════════════════════════════════════════════════════════════
  // REAL DOWNLOAD FIRST
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _downloadAndOpen(String url, String type) async {
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    try {
      final response = await http.get(Uri.parse(url));
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/channel_${DateTime.now().millisecondsSinceEpoch}.${type == 'image' ? 'jpg' : 'mp4'}');
      await file.writeAsBytes(response.bodyBytes);
      if (mounted) {
        Navigator.pop(context);
        if (type == 'image') Navigator.push(context, MaterialPageRoute(builder: (_) => _ImageViewerScreen(imagePath: file.path)));
        else await OpenFilex.open(file.path);
      }
    } catch (e) { if (mounted) { Navigator.pop(context); _showSnack('Download failed: $e'); } }
  }

  void _showSnack(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  bool get _isAdmin => _myRole == 'owner' || _myRole == 'admin';
  bool get _isOwner => _myRole == 'owner';

  @override
  void dispose() {
    _messageSub?.cancel(); _channelSub?.cancel();
    _messageController.dispose(); _scrollController.dispose();
    for (final t in _viewTimers.values) { t.cancel(); }
    for (final v in _videoControllers.values) { v.dispose(); }
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════════
  // UI BUILD
  // ═══════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (_isLoading) return Scaffold(body: Center(child: CircularProgressIndicator(color: theme.colorScheme.primary)));

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(60),
        child: Container(
          color: isDark ? const Color(0xFF17212B) : const Color(0xFF527DA3),
          child: SafeArea(
            child: _isSearching ? _buildSearchBar(theme) : Row(
              children: [
                _headerCircle(icon: Icons.arrow_back, onTap: () => Navigator.pop(context)),
                const SizedBox(width: 4),
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.pushNamed(context, '/channel_info', arguments: {'channelId': widget.channelId}),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(20)),
                      child: Row(
                        children: [
                          CircleAvatar(radius: 16, backgroundImage: widget.channelAvatar != null ? NetworkImage(widget.channelAvatar!) : null, child: widget.channelAvatar == null ? const Icon(Icons.campaign, color: Colors.white, size: 18) : null),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  children: [
                                    Flexible(child: Text(widget.channelName, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
                                    const SizedBox(width: 4),
                                    const Icon(Icons.verified, color: Color(0xFF6FB9F3), size: 14),
                                  ],
                                ),
                                Text('$_subscriberCount subscribers', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                _headerCircle(icon: Icons.search, onTap: () => setState(() => _isSearching = true)),
                _headerCircle(icon: Icons.more_vert, onTap: _showMoreMenu),
              ],
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          if (_channelWallpaper != null) Positioned.fill(child: Image.network(_channelWallpaper!, fit: BoxFit.cover, opacity: const AlwaysStoppedAnimation(0.2))),
          Column(
            children: [
              if (_pinnedMessages.isNotEmpty) _buildPinnedBanner(theme),
              Expanded(
                child: ListView.builder(
                  controller: _scrollController, reverse: true, padding: const EdgeInsets.all(8), itemCount: _messages.length,
                  itemBuilder: (context, i) => _buildPost(_messages[i], theme, isDark),
                ),
              ),
              if (_multiSelectMode) _buildMultiSelectBar(theme),
              
              // Read-only for subscribers, real composer for admins
              if (_isAdmin) _buildComposer(theme, isDark) else _buildSubscriberFooter(theme),

              if (_activePanel != null) _buildPanel(theme, isDark),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(ThemeData theme) {
    return Row(
      children: [
        IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => setState(() => _isSearching = false)),
        const Expanded(child: TextField(autofocus: true, style: TextStyle(color: Colors.white), decoration: InputDecoration(hintText: 'Search posts...', hintStyle: TextStyle(color: Colors.white54), border: InputBorder.none))),
      ],
    );
  }

  Widget _headerCircle({required IconData icon, required VoidCallback onTap}) {
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: Material(color: Colors.black12, shape: const CircleBorder(), child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: SizedBox(width: 40, height: 40, child: Icon(icon, color: Colors.white, size: 20)))));
  }

  Widget _buildSubscriberFooter(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(12),
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        top: false,
        child: Center(
          child: Text('You are subscribed to this channel.', style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.4), fontSize: 13)),
        ),
      ),
    );
  }

  Widget _buildComposer(ThemeData theme, bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      color: isDark ? const Color(0xFF17212B) : const Color(0xFFF0F0F0),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_signaturesEnabled)
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: const Color(0xFF3390EC).withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
                  child: Text('Posting as $_mySignature', style: const TextStyle(color: Color(0xFF3390EC), fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  icon: Icon(_activePanel == 'emoji' ? Icons.keyboard : Icons.emoji_emotions_outlined, color: theme.colorScheme.onSurface.withOpacity(0.6)),
                  onPressed: () {
                    if (_activePanel == 'emoji') { setState(() => _activePanel = null); SystemChannels.textInput.invokeMethod('TextInput.show'); }
                    else { FocusScope.of(context).unfocus(); setState(() => _activePanel = 'emoji'); }
                  },
                ),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(color: isDark ? const Color(0xFF242F3D) : Colors.white, borderRadius: BorderRadius.circular(24)),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _messageController, minLines: 1, maxLines: null,
                            decoration: const InputDecoration(hintText: 'Broadcast a message...', border: InputBorder.none, contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
                            onTap: () { if (_activePanel != null) setState(() => _activePanel = null); },
                          ),
                        ),
                        IconButton(icon: Icon(Icons.attach_file, color: theme.colorScheme.onSurface.withOpacity(0.6)), onPressed: () => _showAttachmentSheet()),
                        IconButton(icon: Icon(Icons.camera_alt_outlined, color: theme.colorScheme.onSurface.withOpacity(0.6)), onPressed: () => _pickAndSendMedia('image')),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => _sendPost(),
                  onLongPress: () => _showSendOptions(),
                  child: CircleAvatar(radius: 24, backgroundColor: const Color(0xFF3390EC), child: const Icon(Icons.send, color: Colors.white, size: 22)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showSendOptions() {
    showModalBottomSheet(context: context, builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.notifications_off), title: const Text('Send Silently'), onTap: () { Navigator.pop(context); _sendPost(silent: true); }),
      ListTile(leading: const Icon(Icons.schedule), title: const Text('Schedule Post'), onTap: () { Navigator.pop(context); _showScheduleDialog(); }),
    ])));
  }

  void _showScheduleDialog() {
    showDatePicker(context: context, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 30))).then((date) {
      if (date != null) { _sendPost(scheduleAt: date); }
    });
  }

  Widget _buildPanel(ThemeData theme, bool isDark) {
    if (_activePanel == 'emoji') {
      return SizedBox(height: 300, child: EmojiPicker(onEmojiSelected: (category, emoji) => _messageController.text += emoji.emoji, config: Config(height: 300, emojiViewConfig: EmojiViewConfig(backgroundColor: isDark ? const Color(0xFF17212B) : Colors.white, columns: 8, emojiSizeMax: 28))));
    }
    return const SizedBox.shrink();
  }

  void _showAttachmentSheet() {
    showModalBottomSheet(context: context, builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.image), title: const Text('Photo'), onTap: () { Navigator.pop(context); _pickAndSendMedia('image'); }),
      ListTile(leading: const Icon(Icons.videocam), title: const Text('Video'), onTap: () { Navigator.pop(context); _pickAndSendMedia('video'); }),
    ])));
  }

  Widget _buildPinnedBanner(ThemeData theme) {
    final p = _pinnedMessages.first;
    final msg = _messages.firstWhere((m) => m['id'] == p['message_id'], orElse: () => {});
    return Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), color: theme.colorScheme.primary.withOpacity(0.1), child: Row(children: [const Icon(Icons.push_pin, size: 16, color: Color(0xFF3390EC)), const SizedBox(width: 8), Expanded(child: Text((msg['text'] ?? 'Pinned').toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))), if (_isAdmin) IconButton(icon: const Icon(Icons.close, size: 16), onPressed: () async { await FirebaseFirestore.instance.collection('chats').doc(widget.channelId).collection('pinned_messages').doc(p['id']).delete(); _loadPinnedMessages(); })]));
  }

  Widget _buildPost(Map<String, dynamic> msg, ThemeData theme, bool isDark) {
    final isSelected = _selectedIds.contains(msg['id']);
    _trackView(msg['id']); // Real view counting hook

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onLongPress: () => _showMessageMenu(msg),
        onTap: _multiSelectMode ? () => setState(() { isSelected ? _selectedIds.remove(msg['id']) : _selectedIds.add(msg['id']); }) : null,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF3390EC).withOpacity(0.3) : (isDark ? const Color(0xFF1F2C34) : Colors.white),
            borderRadius: BorderRadius.circular(16),
            border: Border(left: BorderSide(color: const Color(0xFF3390EC), width: 4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (msg['signature'] != null)
                Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(msg['signature'], style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF3390EC)))),
                
              if (msg['media_type'] == 'image' && msg['media_url'] != null)
                GestureDetector(onTap: () => _downloadAndOpen(msg['media_url'], 'image'), child: Stack(alignment: Alignment.center, children: [
                  ClipRRect(borderRadius: BorderRadius.circular(8), child: CachedNetworkImage(imageUrl: msg['media_url'], width: double.infinity, fit: BoxFit.cover)),
                  Container(padding: const EdgeInsets.all(8), decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle), child: const Icon(Icons.download, color: Colors.white)),
                ])),
                
              if (msg['media_type'] == 'video' && msg['media_url'] != null)
                _buildVideoBubble(msg['media_url']),
                
              if ((msg['text'] ?? '').toString().isNotEmpty)
                Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(msg['text'], style: TextStyle(color: theme.colorScheme.onSurface, fontSize: 15))),
                
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.remove_red_eye, size: 14, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text(_formatViews((msg['views'] ?? 0) as int), style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  const Spacer(),
                  if (_commentsEnabled)
                    GestureDetector(
                      onTap: () => Navigator.pushNamed(context, '/comments', arguments: {'postId': msg['id']}),
                      child: Row(children: [const Icon(Icons.comment, size: 16, color: Color(0xFF3390EC)), const SizedBox(width: 4), Text('${msg['comments_count'] ?? 0}', style: const TextStyle(fontSize: 12, color: Color(0xFF3390EC)))]),
                    ),
                  const SizedBox(width: 12),
                  Text(DateFormat('HH:mm').format((msg['created_at'] as Timestamp?)?.toDate() ?? DateTime.now()), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoBubble(String url) {
    final controller = _videoControllers.putIfAbsent(url, () { final c = VideoPlayerController.networkUrl(Uri.parse(url)); c.initialize().then((_) => setState(() {})); return c; });
    return GestureDetector(onTap: () { if (controller.value.isPlaying) controller.pause(); else controller.play(); setState(() {}); }, child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Container(height: 200, color: Colors.black, child: controller.value.isInitialized ? Stack(alignment: Alignment.center, children: [VideoPlayer(controller), Icon(controller.value.isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 40)]) : const Center(child: CircularProgressIndicator()))));
  }

  void _showMessageMenu(Map<String, dynamic> msg) {
    showModalBottomSheet(context: context, builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.copy), title: const Text('Copy'), onTap: () { Clipboard.setData(ClipboardData(text: msg['text'] ?? '')); Navigator.pop(context); }),
      if (_isAdmin) ...[
        ListTile(leading: const Icon(Icons.push_pin), title: const Text('Pin'), onTap: () async { Navigator.pop(context); await FirebaseFirestore.instance.collection('chats').doc(widget.channelId).collection('pinned_messages').doc(msg['id']).set({'message_id': msg['id'], 'pinned_at': FieldValue.serverTimestamp()}); _loadPinnedMessages(); }),
        ListTile(leading: const Icon(Icons.delete, color: Colors.red), title: const Text('Delete', style: TextStyle(color: Colors.red)), onTap: () async { Navigator.pop(context); await FirebaseFirestore.instance.collection('chats').doc(widget.channelId).collection('messages').doc(msg['id']).update({'deleted_for_everyone': true, 'text': 'Deleted'}); }),
      ],
      ListTile(leading: const Icon(Icons.select_all), title: const Text('Select'), onTap: () { Navigator.pop(context); setState(() { _multiSelectMode = true; _selectedIds.add(msg['id']); }); }),
    ])));
  }

  void _showMoreMenu() {
    showModalBottomSheet(context: context, builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.info_outline), title: const Text('Channel Info'), onTap: () { Navigator.pop(context); Navigator.pushNamed(context, '/channel_info', arguments: {'channelId': widget.channelId}); }),
      ListTile(leading: const Icon(Icons.discord), title: const Text('Discussion Link'), onTap: () { Navigator.pop(context); }),
      if (_isAdmin && _subscriberCount >= 500) ListTile(leading: const Icon(Icons.bar_chart), title: const Text('Channel Stats'), onTap: () { Navigator.pop(context); Navigator.pushNamed(context, '/channel_stats', arguments: {'channelId': widget.channelId}); }),
      if (_isAdmin) ListTile(leading: const Icon(Icons.edit), title: const Text('Edit Channel'), onTap: () { Navigator.pop(context); Navigator.pushNamed(context, '/edit_channel', arguments: {'channelId': widget.channelId}); }),
      if (_isAdmin && _isMePremium) ListTile(leading: const Icon(Icons.image), title: const Text('Set Premium Wallpaper'), onTap: () { Navigator.pop(context); _setWallpaper(); }),
      ListTile(leading: const Icon(Icons.share), title: const Text('Share Link'), onTap: () { Navigator.pop(context); _showSnack('Link copied'); }),
      ListTile(leading: const Icon(Icons.notifications_off), title: const Text('Mute'), onTap: () { Navigator.pop(context); _showSnack('Muted'); }),
      ListTile(leading: const Icon(Icons.cleaning_services), title: const Text('Clear History'), onTap: () { Navigator.pop(context); }),
      if (!_isAdmin) ListTile(leading: const Icon(Icons.exit_to_app, color: Colors.red), title: const Text('Leave Channel', style: TextStyle(color: Colors.red)), onTap: () { Navigator.pop(context); }),
      if (_isOwner) ListTile(leading: const Icon(Icons.delete_forever, color: Colors.red), title: const Text('Delete Channel', style: TextStyle(color: Colors.red)), onTap: () { Navigator.pop(context); }),
    ])));
  }

  Future<void> _setWallpaper() async {
    final x = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (x == null) return;
    _showSnack('Uploading wallpaper...');
    final url = await CloudinaryService.uploadImage(File(x.path), 'luma/channel_walls');
    if (url != null) {
      await FirebaseFirestore.instance.collection('chats').doc(widget.channelId).update({'wallpaper_url': url});
      _showSnack('Wallpaper updated for everyone!');
    }
  }

  Widget _buildMultiSelectBar(ThemeData theme) {
    return Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), color: theme.colorScheme.surfaceVariant.withOpacity(0.5), child: Row(children: [
      IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() { _multiSelectMode = false; _selectedIds.clear(); })),
      Text('${_selectedIds.length} selected', style: const TextStyle(fontWeight: FontWeight.bold)),
      const Spacer(),
      if (_isAdmin) IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: () async { for (final id in _selectedIds) { await FirebaseFirestore.instance.collection('chats').doc(widget.channelId).collection('messages').doc(id).update({'deleted_for_everyone': true, 'text': 'Deleted'}); } setState(() { _multiSelectMode = false; _selectedIds.clear(); }); }),
    ]));
  }
}

class _ImageViewerScreen extends StatelessWidget {
  final String imagePath;
  const _ImageViewerScreen({required this.imagePath});
  @override
  Widget build(BuildContext context) => Scaffold(backgroundColor: Colors.black, appBar: AppBar(backgroundColor: Colors.black, leading: IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(context))), body: Center(child: Image.file(File(imagePath))));
}
