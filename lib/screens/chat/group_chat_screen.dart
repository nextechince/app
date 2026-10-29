import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart'; // REAL RECORDER
import 'package:uuid/uuid.dart';

import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../services/api_config.dart';
import '../../services/cloudinary_service.dart';

class GroupChatScreen extends StatefulWidget {
  final String chatId;
  final String chatName;
  final String? chatAvatar;

  const GroupChatScreen({
    super.key,
    required this.chatId,
    required this.chatName,
    this.chatAvatar,
  });

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _picker = ImagePicker();
  final _audioPlayer = AudioPlayer();
  
  // REAL AUDIO RECORDER
  final AudioRecorder _audioRecorder = AudioRecorder();

  String? _currentUserId;
  String? _myRole = 'member';
  bool _isMePremium = false;
  bool _showEmojiPanel = false;
  String? _wallpaperUrl;

  Map<String, dynamic>? _chatData;
  List<Map<String, dynamic>> _messages = [];
  StreamSubscription? _messageSub;
  StreamSubscription? _chatSub;
  bool _isLoading = true;

  String? _replyingTo;
  bool _multiSelectMode = false;
  final Set<String> _selectedIds = {};

  // Audio State
  bool _isRecording = false;
  int _recordingSeconds = 0;
  Timer? _recordingTimer;
  String? _currentlyPlayingId;
  Duration _audioPosition = Duration.zero;
  Duration _audioDuration = Duration.zero;

  final Map<String, dynamic> _userCache = {};
  int _unreadCount = 0;

  @override
  void initState() {
    super.initState();
    _initAudioPlayer();
    _init();
  }

  void _initAudioPlayer() {
    _audioPlayer.positionStream.listen((pos) => setState(() => _audioPosition = pos));
    _audioPlayer.durationStream.listen((dur) => setState(() => _audioDuration = dur ?? Duration.zero));
    _audioPlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        setState(() => _currentlyPlayingId = null);
        _audioPlayer.stop();
      }
    });
  }

  Future<void> _init() async {
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    _currentUserId = auth.user?.uid ?? auth.mockUserId;
    if (_currentUserId == null) return;

    _listenToChat();
    _listenToMessages();
    _listenToPremium();
    _loadWallpaper();
  }

  void _listenToChat() {
    _chatSub = FirebaseFirestore.instance.collection('chats').doc(widget.chatId).snapshots().listen((doc) {
      if (mounted && doc.exists) {
        setState(() {
          _chatData = doc.data();
          _myRole = _chatData?['participants_data']?[_currentUserId]?['role'] ?? 'member';
          _isLoading = false;
        });
      }
    });
  }

  void _listenToMessages() {
    _messageSub = FirebaseFirestore.instance
        .collection('chats').doc(widget.chatId).collection('messages')
        .orderBy('created_at', descending: true)
        .limit(100)
        .snapshots().listen((snap) {
      if (!mounted) return;
      final loaded = snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
      
      for (var m in loaded) {
        final sid = m['sender_id'];
        if (sid != null && !_userCache.containsKey(sid)) _fetchUser(sid);
      }

      setState(() {
        _messages = loaded;
        _unreadCount = loaded.where((m) => m['sender_id'] != _currentUserId && m['is_read'] == false).length;
      });
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

  Future<void> _loadWallpaper() async {
    final doc = await FirebaseFirestore.instance.collection('user_settings').doc(_currentUserId).get();
    if (doc.exists && mounted) {
      final walls = doc.data()?['chat_wallpapers'] as Map<String, dynamic>? ?? {};
      setState(() => _wallpaperUrl = walls[widget.chatId]);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // REAL RECORDING & SENDING LOGIC
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _startRecording() async {
    if (await _audioRecorder.hasPermission()) {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      
      await _audioRecorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
      
      setState(() { _isRecording = true; _recordingSeconds = 0; });
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (mounted) setState(() => _recordingSeconds++);
      });
    }
  }

  Future<void> _stopRecording({bool send = true}) async {
    _recordingTimer?.cancel();
    setState(() => _isRecording = false);
    
    final path = await _audioRecorder.stop();
    if (!send || path == null) return;

    _showSnack('Uploading voice note...');
    final file = File(path);
    final url = await CloudinaryService.uploadAudio(file, 'luma/voices');

    if (url != null && mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      final msgId = const Uuid().v4();
      await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(msgId).set({
        'id': msgId,
        'sender_id': _currentUserId,
        'type': 'audio',
        'media_type': 'audio',
        'media_url': url,
        'duration': _recordingSeconds,
        'created_at': FieldValue.serverTimestamp(),
        'is_read': false,
      });
    }
  }

  Future<void> _playAudio(String url, String msgId) async {
    if (_currentlyPlayingId == msgId) {
      await _audioPlayer.pause();
      setState(() => _currentlyPlayingId = null);
    } else {
      await _audioPlayer.stop();
      await _audioPlayer.setUrl(url);
      await _audioPlayer.play();
      setState(() => _currentlyPlayingId = msgId);
    }
  }

  Future<void> _sendText() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final isAdmin = _myRole == 'owner' || _myRole == 'admin';
    if (_chatData?['settings']?['chat_disabled'] == true && !isAdmin) {
      _showSnack('Only admins can send messages');
      return;
    }

    _messageController.clear();
    final msgId = const Uuid().v4();
    await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(msgId).set({
      'id': msgId,
      'sender_id': _currentUserId,
      'text': text,
      'type': 'text',
      'media_type': 'text',
      'created_at': FieldValue.serverTimestamp(),
      'is_read': false,
      if (_replyingTo != null) 'reply_to': _replyingTo,
      if (_replyingTo != null) 'reply_to_content': _findMessage(_replyingTo)?['text'],
    });

    await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).update({
      'last_message': text,
      'last_message_at': FieldValue.serverTimestamp(),
    });
    setState(() => _replyingTo = null);
  }

  Future<void> _pickAndSendMedia(String type) async {
    Navigator.pop(context); 
    final x = type == 'image' 
        ? await _picker.pickImage(source: ImageSource.gallery, imageQuality: 90) 
        : await _picker.pickVideo(source: ImageSource.gallery);
    if (x == null) return;

    final file = File(x.path);
    final size = await file.length();
    final limit = _isMePremium ? (5 * 1024 * 1024 * 1024) : (200 * 1024 * 1024); 
    if (size > limit) {
      _showSnack(_isMePremium ? 'Max 5GB' : 'Upgrade to Premium to send over 200MB');
      return;
    }

    _showSnack('Uploading...');
    final url = type == 'image' ? await CloudinaryService.uploadImage(file, 'luma/groups') : await CloudinaryService.uploadVideo(file, 'luma/groups');
    if (url == null) return;
    if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();

    final msgId = const Uuid().v4();
    await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(msgId).set({
      'id': msgId,
      'sender_id': _currentUserId,
      'type': type,
      'media_type': type,
      'media_url': url,
      'created_at': FieldValue.serverTimestamp(),
      'is_read': false,
    });
  }

  Future<void> _downloadAndOpen(String url, String type) async {
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    try {
      final response = await http.get(Uri.parse(url));
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/luma_${DateTime.now().millisecondsSinceEpoch}.${type == 'image' ? 'jpg' : 'mp4'}');
      await file.writeAsBytes(response.bodyBytes);
      
      if (mounted) {
        Navigator.pop(context);
        if (type == 'image') Navigator.push(context, MaterialPageRoute(builder: (_) => _ImageViewerScreen(imagePath: file.path)));
        else await OpenFilex.open(file.path);
      }
    } catch (e) {
      if (mounted) { Navigator.pop(context); _showSnack('Download failed: $e'); }
    }
  }

  void _showSnack(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  Map<String, dynamic>? _findMessage(String? id) => id == null ? null : _messages.firstWhere((m) => m['id'] == id, orElse: () => {});

  @override
  void dispose() {
    _messageSub?.cancel();
    _chatSub?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    _audioPlayer.dispose();
    _recordingTimer?.cancel();
    _audioRecorder.dispose();
    super.dispose();
  }

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
            child: Row(
              children: [
                _headerCircle(icon: Icons.arrow_back, onTap: () => Navigator.pop(context)),
                const SizedBox(width: 4),
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.pushNamed(context, '/group_info', arguments: {'chatId': widget.chatId}),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(20)),
                      child: Row(
                        children: [
                          CircleAvatar(radius: 16, backgroundImage: widget.chatAvatar != null ? NetworkImage(widget.chatAvatar!) : null, child: widget.chatAvatar == null ? const Icon(Icons.group, color: Colors.white, size: 18) : null),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(widget.chatName, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                                Text('${_chatData?['participants']?.length ?? 0} members', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                _headerCircle(icon: Icons.call, onTap: () {}),
                _headerCircle(icon: Icons.more_vert, onTap: _showMoreMenu),
              ],
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          if (_wallpaperUrl != null)
            Positioned.fill(child: Image.network(_wallpaperUrl!, fit: BoxFit.cover, opacity: const AlwaysStoppedAnimation(0.2))),
          
          Column(
            children: [
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  padding: const EdgeInsets.all(8),
                  itemCount: _messages.length,
                  itemBuilder: (context, i) => _buildMessage(_messages[i], theme, isDark),
                ),
              ),
              
              if (_replyingTo != null) _buildReplyBar(theme),
              if (_multiSelectMode) _buildMultiSelectBar(theme),
              if (_isRecording) _buildRecordingBar(theme),

              Container(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                color: isDark ? const Color(0xFF17212B) : const Color(0xFFF0F0F0),
                child: SafeArea(
                  top: false,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      IconButton(
                        icon: Icon(_showEmojiPanel ? Icons.keyboard : Icons.emoji_emotions_outlined, color: theme.colorScheme.onSurface.withOpacity(0.6)),
                        onPressed: () {
                          if (_showEmojiPanel) { setState(() => _showEmojiPanel = false); SystemChannels.textInput.invokeMethod('TextInput.show'); } 
                          else { FocusScope.of(context).unfocus(); setState(() => _showEmojiPanel = true); }
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
                                  controller: _messageController,
                                  minLines: 1, maxLines: null,
                                  decoration: const InputDecoration(hintText: 'Message', border: InputBorder.none, contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
                                  onTap: () { if (_showEmojiPanel) setState(() => _showEmojiPanel = false); },
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
                        onLongPress: _startRecording,
                        onLongPressEnd: (_) => _stopRecording(send: true),
                        child: CircleAvatar(
                          radius: 24,
                          backgroundColor: const Color(0xFF3390EC),
                          child: Icon(_messageController.text.trim().isEmpty ? Icons.mic : Icons.send, color: Colors.white, size: 22),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_showEmojiPanel)
                SizedBox(
                  height: 300,
                  child: EmojiPicker(
                    onEmojiSelected: (category, emoji) => _messageController.text += emoji.emoji,
                    config: Config(height: 300, emojiViewConfig: EmojiViewConfig(backgroundColor: isDark ? const Color(0xFF17212B) : Colors.white, columns: 8, emojiSizeMax: 28), categoryViewConfig: CategoryViewConfig(backgroundColor: isDark ? const Color(0xFF17212B) : Colors.white, indicatorColor: const Color(0xFF3390EC))),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingBar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(12),
      color: Colors.red.withOpacity(0.1),
      child: Row(
        children: [
          const Icon(Icons.mic, color: Colors.red),
          const SizedBox(width: 12),
          Text('Recording... ${_recordingSeconds}s', style: const TextStyle(color: Colors.red)),
          const Spacer(),
          IconButton(icon: const Icon(Icons.send, color: Colors.red), onPressed: () => _stopRecording(send: true)),
          IconButton(icon: const Icon(Icons.close, color: Colors.grey), onPressed: () => _stopRecording(send: false)),
        ],
      ),
    );
  }

  Widget _buildAudioBubble(Map<String, dynamic> msg) {
    final isPlaying = _currentlyPlayingId == msg['id'];
    final duration = msg['duration'] ?? 0;
    
    return Container(
      width: 200,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(8)),
      child: Row(
        children: [
          IconButton(
            icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white),
            onPressed: () => _playAudio(msg['media_url'], msg['id']),
          ),
          Expanded(
            child: isPlaying
                ? LinearProgressIndicator(value: _audioDuration.inMilliseconds > 0 ? _audioPosition.inMilliseconds / _audioDuration.inMilliseconds : 0, color: Colors.white, backgroundColor: Colors.white24)
                : Text('${duration}s', style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _headerCircle({required IconData icon, required VoidCallback onTap}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(color: Colors.black12, shape: const CircleBorder(), child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: SizedBox(width: 40, height: 40, child: Icon(icon, color: Colors.white, size: 20)))),
    );
  }

  Widget _buildMessage(Map<String, dynamic> msg, ThemeData theme, bool isDark) {
    final isMe = msg['sender_id'] == _currentUserId;
    final isSystem = msg['type'] == 'system';
    final sender = _userCache[msg['sender_id']] ?? {'display_name': 'Member', 'avatar_url': null};
    final isSelected = _selectedIds.contains(msg['id']);

    if (isSystem) return Center(child: Container(margin: const EdgeInsets.symmetric(vertical: 6), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), decoration: BoxDecoration(color: isDark ? const Color(0xFF1A1A1A) : Colors.black.withOpacity(0.05), borderRadius: BorderRadius.circular(12)), child: Text((msg['content'] ?? '').toString(), style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.7)))));

    return Padding(
      padding: EdgeInsets.only(bottom: 8, left: isMe ? 40 : 0, right: isMe ? 0 : 40),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMe) CircleAvatar(radius: 14, backgroundImage: sender['avatar_url'] != null ? NetworkImage(sender['avatar_url']) : null, child: sender['avatar_url'] == null ? const Icon(Icons.person, size: 14) : null),
          const SizedBox(width: 6),
          Flexible(
            child: GestureDetector(
              onTap: _multiSelectMode ? () => setState(() { isSelected ? _selectedIds.remove(msg['id']) : _selectedIds.add(msg['id']); }) : null,
              onLongPress: () => _showMessageMenu(msg),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: isSelected ? const Color(0xFF3390EC).withOpacity(0.3) : (isMe ? (isDark ? const Color(0xFF005C4B) : const Color(0xFFEFFDDE)) : (isDark ? const Color(0xFF1F2C34) : Colors.white)), borderRadius: BorderRadius.circular(12)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!isMe) Text(sender['display_name'], style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF4FAE4F))),
                    if (msg['media_type'] == 'image' && msg['media_url'] != null)
                      GestureDetector(onTap: () => _downloadAndOpen(msg['media_url'], 'image'), child: Stack(alignment: Alignment.center, children: [CachedNetworkImage(imageUrl: msg['media_url'], width: 200, fit: BoxFit.cover), Container(padding: const EdgeInsets.all(8), decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle), child: const Icon(Icons.download, color: Colors.white))])),
                    if (msg['media_type'] == 'audio' && msg['media_url'] != null) _buildAudioBubble(msg),
                    if ((msg['text'] ?? '').toString().isNotEmpty)
                      Padding(padding: const EdgeInsets.only(top: 4), child: Text(msg['text'], style: TextStyle(color: isMe && isDark ? Colors.white : theme.colorScheme.onSurface, fontSize: 15))),
                    const SizedBox(height: 4),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(DateFormat('HH:mm').format((msg['created_at'] as Timestamp?)?.toDate() ?? DateTime.now()), style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurface.withOpacity(0.5))),
                      if (isMe) ...[const SizedBox(width: 4), Icon(msg['is_read'] == true ? Icons.done_all : Icons.done, size: 14, color: msg['is_read'] == true ? const Color(0xFF4FC3F7) : theme.colorScheme.onSurface.withOpacity(0.5))],
                    ]),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showAttachmentSheet() {
    showModalBottomSheet(context: context, builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [ListTile(leading: const Icon(Icons.image), title: const Text('Gallery'), onTap: () => _pickAndSendMedia('image')), ListTile(leading: const Icon(Icons.videocam), title: const Text('Video'), onTap: () => _pickAndSendMedia('video'))])));
  }

  void _showMessageMenu(Map<String, dynamic> msg) {
    showModalBottomSheet(context: context, builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.reply), title: const Text('Reply'), onTap: () { Navigator.pop(context); setState(() => _replyingTo = msg['id']); }),
      ListTile(leading: const Icon(Icons.copy), title: const Text('Copy'), onTap: () { Clipboard.setData(ClipboardData(text: msg['text'] ?? '')); Navigator.pop(context); }),
      if (msg['sender_id'] == _currentUserId) ListTile(leading: const Icon(Icons.delete, color: Colors.red), title: const Text('Delete', style: TextStyle(color: Colors.red)), onTap: () async { Navigator.pop(context); await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(msg['id']).update({'deleted_for_everyone': true, 'text': 'Deleted'}); }),
      ListTile(leading: const Icon(Icons.select_all), title: const Text('Select'), onTap: () { Navigator.pop(context); setState(() { _multiSelectMode = true; _selectedIds.add(msg['id']); }); }),
    ])));
  }

  void _showMoreMenu() {
    showModalBottomSheet(context: context, builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.info_outline), title: const Text('Group Info'), onTap: () { Navigator.pop(context); Navigator.pushNamed(context, '/group_info', arguments: {'chatId': widget.chatId}); }),
      ListTile(leading: const Icon(Icons.image), title: const Text('Change Wallpaper'), onTap: () { Navigator.pop(context); _showSnack('Wallpaper settings'); }),
    ])));
  }

  Widget _buildReplyBar(ThemeData theme) {
    final msg = _findMessage(_replyingTo);
    return Container(padding: const EdgeInsets.all(8), color: theme.colorScheme.surfaceVariant.withOpacity(0.5), child: Row(children: [const Icon(Icons.reply, size: 18, color: Color(0xFF3390EC)), const SizedBox(width: 8), Expanded(child: Text((msg?['text'] ?? 'Message').toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))), IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() => _replyingTo = null))]));
  }

  Widget _buildMultiSelectBar(ThemeData theme) {
    return Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), color: theme.colorScheme.surfaceVariant.withOpacity(0.5), child: Row(children: [IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() { _multiSelectMode = false; _selectedIds.clear(); })), Text('${_selectedIds.length} selected', style: const TextStyle(fontWeight: FontWeight.bold)), const Spacer(), IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: () async { for (final id in _selectedIds) { await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(id).update({'deleted_for_everyone': true, 'text': 'Deleted'}); } setState(() { _multiSelectMode = false; _selectedIds.clear(); }); })]));
  }
}

class _ImageViewerScreen extends StatelessWidget {
  final String imagePath;
  const _ImageViewerScreen({required this.imagePath});

  @override
  Widget build(BuildContext context) {
    return Scaffold(backgroundColor: Colors.black, appBar: AppBar(backgroundColor: Colors.black, leading: IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(context))), body: Center(child: Image.file(File(imagePath))));
  }
}
