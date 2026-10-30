import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../services/api_config.dart';
import '../../services/cloudinary_service.dart';

// ═══════════════════════════════════════════════════════════════════════════
// NATIVE RECORDER (Talks directly to MainActivity.kt)
// ═══════════════════════════════════════════════════════════════════════════
class LocalRecorder {
  static const _channel = MethodChannel('com.lumachat.app/recorder');
  Future<void> start(String path) async => await _channel.invokeMethod('start', {'path': path});
  Future<String?> stop() async => await _channel.invokeMethod<String>('stop');
  Future<void> cancel() async => await _channel.invokeMethod('cancel');
}

class GroupChatScreen extends StatefulWidget {
  final String chatId;
  final String chatName;
  final String? chatAvatar;

  const GroupChatScreen({super.key, required this.chatId, required this.chatName, this.chatAvatar});

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  final _picker = ImagePicker();
  final _audioPlayer = AudioPlayer();
  final LocalRecorder _audioRecorder = LocalRecorder();

  String? _currentUserId;
  String? _myRole = 'member';
  bool _isMePremium = false;
  String? _wallpaperUrl;
  
  String? _activePanel; // 'emoji', 'sticker', 'gif'
  bool _isSearching = false;
  
  Map<String, dynamic>? _chatData;
  List<Map<String, dynamic>> _messages = [];
  List<Map<String, dynamic>> _pinnedMessages = [];
  StreamSubscription? _messageSub;
  StreamSubscription? _chatSub;
  bool _isLoading = true;

  String? _replyingTo;
  bool _multiSelectMode = false;
  final Set<String> _selectedIds = {};

  bool _isRecording = false;
  int _recordingSeconds = 0;
  Timer? _recordingTimer;
  String? _currentlyPlayingId;
  Duration _audioPosition = Duration.zero;
  Duration _audioDuration = Duration.zero;

  final Map<String, dynamic> _userCache = {};
  final Map<String, VideoPlayerController> _videoControllers = {};
  final Map<String, bool> _typingUsers = {};
  Timer? _typingTimer;

  // Custom Attachment State
  int _selectedBottomTab = 0; 
  List<File> _selectedImages = [];

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
    _listenToTyping();
  }

  void _listenToChat() {
    _chatSub = FirebaseFirestore.instance.collection('chats').doc(widget.chatId).snapshots().listen((doc) {
      if (mounted && doc.exists) {
        setState(() {
          _chatData = doc.data();
          _myRole = _chatData?['participants_data']?[_currentUserId]?['role'] ?? 'member';
          _isLoading = false;
        });
        _loadPinnedMessages();
      }
    });
  }

  void _listenToMessages() {
    _messageSub = FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').orderBy('created_at', descending: true).limit(100).snapshots().listen((snap) {
      if (!mounted) return;
      final loaded = snap.docs.map((d) => {'id': d.id, ...d.data()}).where((m) => m['deleted_for_everyone'] != true).toList();
      for (var m in loaded) {
        final sid = m['sender_id'];
        if (sid != null && !_userCache.containsKey(sid)) _fetchUser(sid);
      }
      setState(() => _messages = loaded);
    });
  }

  void _listenToTyping() {
    FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('typing').snapshots().listen((snap) {
      if (!mounted) return;
      setState(() {
        _typingUsers.clear();
        for (final doc in snap.docs) {
          if (doc.id != _currentUserId && doc.data()['is_typing'] == true) _typingUsers[doc.id] = true;
        }
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

  Future<void> _loadPinnedMessages() async {
    final snap = await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('pinned_messages').orderBy('pinned_at', descending: true).limit(1).get();
    if (mounted) setState(() => _pinnedMessages = snap.docs.map((d) => {'id': d.id, ...d.data()}).toList());
  }

  void _sendTypingStatus(bool isTyping) {
    _typingTimer?.cancel();
    if (isTyping) {
      FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('typing').doc(_currentUserId).set({'is_typing': true});
      _typingTimer = Timer(const Duration(seconds: 3), () => _sendTypingStatus(false));
    } else {
      FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('typing').doc(_currentUserId).delete();
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // SENDING
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _sendText() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    
    // IMAGE 1: Check if group is locked
    final isLocked = _chatData?['is_locked'] == true;
    if (isLocked && _myRole != 'admin' && _myRole != 'owner') {
      _showSnack('Text not allowed. Group is locked to admins.');
      return;
    }

    _messageController.clear();
    _sendTypingStatus(false);
    final msgId = const Uuid().v4();
    
    await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(msgId).set({
      'id': msgId, 'sender_id': _currentUserId, 'text': text, 'type': 'text', 'media_type': 'text', 'created_at': FieldValue.serverTimestamp(), 'is_read': false,
      if (_replyingTo != null) 'reply_to': _replyingTo,
      if (_replyingTo != null) 'reply_to_content': _findMessage(_replyingTo)?['text'],
    });
    setState(() => _replyingTo = null);
  }

  Future<void> _sendSticker(String url) async {
    final msgId = const Uuid().v4();
    await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(msgId).set({
      'id': msgId, 'sender_id': _currentUserId, 'type': 'sticker', 'media_type': 'sticker', 'media_url': url, 'created_at': FieldValue.serverTimestamp(), 'is_read': false,
    });
    setState(() => _activePanel = null);
  }

  Future<void> _pickAndSendMedia(String type) async {
    Navigator.pop(context); 
    final x = type == 'image' ? await _picker.pickImage(source: ImageSource.gallery, imageQuality: 90) : await _picker.pickVideo(source: ImageSource.gallery);
    if (x == null) return;

    final file = File(x.path);
    final size = await file.length();
    final limit = _isMePremium ? (5 * 1024 * 1024 * 1024) : (200 * 1024 * 1024); 
    if (size > limit) { _showSnack(_isMePremium ? 'Max 5GB' : 'Upgrade to Premium for >200MB'); return; }

    _showSnack('Uploading...');
    final url = type == 'image' ? await CloudinaryService.uploadImage(file, 'luma/groups') : await CloudinaryService.uploadVideo(file, 'luma/groups');
    if (url == null) return;
    if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();

    final msgId = const Uuid().v4();
    await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(msgId).set({
      'id': msgId, 'sender_id': _currentUserId, 'type': type, 'media_type': type, 'media_url': url, 'created_at': FieldValue.serverTimestamp(), 'is_read': false,
    });
  }

  // New: Send actual camera image from custom picker
  Future<void> _pickFromCamera() async {
    try {
      final XFile? photo = await _picker.pickImage(source: ImageSource.camera);
      if (photo != null) {
        Navigator.pop(context); // close modal
        final file = File(photo.path);
        _showSnack('Uploading...');
        final url = await CloudinaryService.uploadImage(file, 'luma/groups');
        if (url != null && mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          final msgId = const Uuid().v4();
          await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(msgId).set({
            'id': msgId, 'sender_id': _currentUserId, 'type': 'image', 'media_type': 'image', 'media_url': url, 'created_at': FieldValue.serverTimestamp(), 'is_read': false,
          });
        }
      }
    } catch (e) {
      _showSnack('Camera error: $e');
    }
  }

  Future<void> _startRecording() async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _audioRecorder.start(path);
    setState(() { _isRecording = true; _recordingSeconds = 0; });
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (t) { if (mounted) setState(() => _recordingSeconds++); });
  }

  Future<void> _stopRecording({bool send = true}) async {
    _recordingTimer?.cancel();
    setState(() => _isRecording = false);
    if (!send) { await _audioRecorder.cancel(); return; }
    final path = await _audioRecorder.stop();
    if (path == null) return;

    _showSnack('Uploading voice note...');
    final url = await CloudinaryService.uploadAudio(File(path), 'luma/voices');
    if (url != null && mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      final msgId = const Uuid().v4();
      await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(msgId).set({
        'id': msgId, 'sender_id': _currentUserId, 'type': 'audio', 'media_type': 'audio', 'media_url': url, 'duration': _recordingSeconds, 'created_at': FieldValue.serverTimestamp(), 'is_read': false,
      });
    }
  }

  Future<void> _processAiAction(String action, String text) async {
    if (!_isMePremium) { _showSnack('Upgrade to Premium to use AI tools!'); return; }
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    try {
      final model = GenerativeModel(model: 'gemini-pro', apiKey: ApiConfig.geminiApiKey);
      final prompt = action == 'summarize' ? 'Summarize this chat message: "$text"' : 'Translate this message to English: "$text"';
      final response = await model.generateContent([Content.text(prompt)]);
      if (mounted) { Navigator.pop(context); showDialog(context: context, builder: (_) => AlertDialog(title: Text(action.toUpperCase()), content: Text(response.text ?? 'No response'), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))])); }
    } catch (e) { if (mounted) { Navigator.pop(context); _showSnack('AI Error: $e'); } }
  }

  void _showSnack(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  Map<String, dynamic>? _findMessage(String? id) => id == null ? null : _messages.firstWhere((m) => m['id'] == id, orElse: () => {});

  @override
  void dispose() {
    _messageSub?.cancel(); _chatSub?.cancel();
    _messageController.dispose(); _scrollController.dispose(); _searchController.dispose();
    _audioPlayer.dispose(); _recordingTimer?.cancel(); _typingTimer?.cancel(); _audioRecorder.cancel();
    for (final v in _videoControllers.values) { v.dispose(); }
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
            child: _isSearching ? _buildSearchBar(theme) : Row(
              children: [
                _headerCircle(icon: Icons.arrow_back, onTap: () => Navigator.pop(context)),
                const SizedBox(width: 4),
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.pushNamed(context, '/group_info', arguments: {'chatId': widget.chatId}),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(20)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(widget.chatName, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                          Text(_typingUsers.isNotEmpty ? 'typing...' : '${_chatData?['participants']?.length ?? 0} members', style: TextStyle(color: _typingUsers.isNotEmpty ? const Color(0xFF8ECAFB) : Colors.white70, fontSize: 12)),
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
          if (_wallpaperUrl != null) Positioned.fill(child: Image.network(_wallpaperUrl!, fit: BoxFit.cover, opacity: const AlwaysStoppedAnimation(0.2))),
          Column(
            children: [
              if (_pinnedMessages.isNotEmpty) _buildPinnedBanner(theme),
              Expanded(
                child: ListView.builder(
                  controller: _scrollController, reverse: true, padding: const EdgeInsets.all(8), itemCount: _messages.length,
                  itemBuilder: (context, i) => _buildMessage(_messages[i], theme, isDark),
                ),
              ),
              if (_replyingTo != null) _buildReplyBar(theme),
              if (_multiSelectMode) _buildMultiSelectBar(theme),
              if (_isRecording) _buildRecordingBar(theme),
              _buildComposer(theme, isDark),
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
        Expanded(
          child: TextField(
            controller: _searchController, autofocus: true, style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(hintText: 'Search messages...', hintStyle: TextStyle(color: Colors.white54), border: InputBorder.none),
            onChanged: (val) => setState(() {}),
          ),
        ),
      ],
    );
  }

  Widget _buildComposer(ThemeData theme, bool isDark) {
    final isLocked = _chatData?['is_locked'] == true;
    final canText = !isLocked || _myRole == 'admin' || _myRole == 'owner';

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      color: isDark ? const Color(0xFF17212B) : const Color(0xFFF0F0F0),
      child: SafeArea(
        top: false,
        child: Row(
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
                        onChanged: (val) => _sendTypingStatus(val.isNotEmpty),
                        enabled: canText,
                        decoration: InputDecoration(
                          hintText: canText ? 'Message' : 'Text not allowed', // Image 1 Fix
                          hintStyle: TextStyle(color: Colors.grey[500]),
                          border: InputBorder.none, 
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)
                        ),
                        onTap: () { if (_activePanel != null) setState(() => _activePanel = null); },
                      ),
                    ),
                    IconButton(icon: Icon(Icons.attach_file, color: theme.colorScheme.onSurface.withOpacity(0.6)), onPressed: () => _showAttachmentSheet()),
                    // Camera Icon quick action
                    IconButton(icon: Icon(Icons.camera_alt_outlined, color: theme.colorScheme.onSurface.withOpacity(0.6)), onPressed: _pickFromCamera),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Image 3 Fix: Sharp circle, no overlay background
            GestureDetector(
              onLongPress: canText ? _startRecording : null, 
              onLongPressEnd: (_) => canText ? _stopRecording(send: true) : null,
              child: Container(
                width: 48, height: 48,
                decoration: const BoxDecoration(color: Color(0xFF3390EC), shape: BoxShape.circle),
                child: Icon(_messageController.text.trim().isEmpty ? Icons.mic : Icons.send, color: Colors.white, size: 22),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPanel(ThemeData theme, bool isDark) {
    if (_activePanel == 'emoji') {
      return SizedBox(height: 300, child: EmojiPicker(onEmojiSelected: (category, emoji) => _messageController.text += emoji.emoji, config: Config(height: 300, emojiViewConfig: EmojiViewConfig(backgroundColor: isDark ? const Color(0xFF17212B) : Colors.white, columns: 8, emojiSizeMax: 28), categoryViewConfig: CategoryViewConfig(backgroundColor: isDark ? const Color(0xFF17212B) : Colors.white, indicatorColor: const Color(0xFF3390EC)))));
    } else if (_activePanel == 'sticker') {
      return Container(height: 300, color: isDark ? const Color(0xFF17212B) : Colors.white, child: const Center(child: Text('Sticker Packs')));
    } else if (_activePanel == 'gif') {
      return Container(height: 300, color: isDark ? const Color(0xFF17212B) : Colors.white, child: const Center(child: Text('Giphy GIFs')));
    }
    return const SizedBox.shrink();
  }

  // ==========================================
  // IMAGE 4-8 & 9: Custom Attachment Bottom Sheet
  // ==========================================
  void _showAttachmentSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Container(
              height: MediaQuery.of(context).size.height * 0.75,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                children: [
                  Container(margin: const EdgeInsets.only(top: 10, bottom: 10), height: 4, width: 40, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
                  
                  // Content Area
                  Expanded(
                    child: _buildBottomSheetContent(_selectedBottomTab, setModalState),
                  ),

                  // Bottom Tab Bar (Image 9 Style)
                  _buildBottomTabBar(setModalState),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildBottomSheetContent(int index, StateSetter setModalState) {
    switch (index) {
      case 0: return _buildCustomImagePicker(setModalState);
      case 1: return _buildFilePicker();
      case 2: return _buildLocationPicker();
      case 3: return _buildContactsPicker(); // Re-using index 3 for contacts
      case 4: return _buildMusicPicker();
      default: return const Center(child: Text("Select an option"));
    }
  }

  // Image 4: Custom Image Picker Grid & Camera
  Widget _buildCustomImagePicker(StateSetter setModalState) {
    return Column(
      children: [
        ListTile(
          leading: const CircleAvatar(backgroundColor: Colors.blue, child: Icon(Icons.camera_alt, color: Colors.white)),
          title: const Text("Open Camera", style: TextStyle(fontWeight: FontWeight.bold)),
          onTap: _pickFromCamera,
        ),
        const Divider(),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8),
          child: Align(alignment: Alignment.centerLeft, child: Text("Recent Photos", style: TextStyle(fontWeight: FontWeight.bold))),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 4, mainAxisSpacing: 4),
            itemCount: 15, 
            itemBuilder: (context, i) {
              return GestureDetector(
                onTap: () => _pickAndSendMedia('image'), // Opens standard gallery to select
                child: Container(
                  decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.photo, color: Colors.white),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // Image 5: File Picker
  Widget _buildFilePicker() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildListTile(Icons.folder, Colors.green, "Internal Storage", "Browse your file system", onTap: () async {
          FilePickerResult? result = await FilePicker.platform.pickFiles();
          if (result != null) {
             Navigator.pop(context);
             _showSnack('Uploading File...');
             final file = File(result.files.single.path!);
             final url = await CloudinaryService.uploadFile(file, 'luma/files'); // Ensure this method exists in your CloudinaryService
             if(url != null) {
                final msgId = const Uuid().v4();
                await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(msgId).set({
                  'id': msgId, 'sender_id': _currentUserId, 'type': 'file', 'media_type': 'file', 'media_url': url, 'file_name': result.files.single.name, 'created_at': FieldValue.serverTimestamp(), 'is_read': false,
                });
             }
          }
        }),
        _buildListTile(Icons.folder, Colors.blue, "Luma Chat", "Browse the app's folder", onTap: () {}), 
        _buildListTile(Icons.photo_library, Colors.orange, "Gallery", "To send images without compression", onTap: () => _pickAndSendMedia('image')),
      ],
    );
  }

  // Image 6: Location Sharing
  Widget _buildLocationPicker() {
    return Column(
      children: [
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.grey[200], borderRadius: BorderRadius.circular(16)),
            child: const Center(child: Icon(Icons.location_on, size: 80, color: Colors.red)), // Mock Map View
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              _buildActionTile(Icons.location_on, Colors.blue, "Send My Current Location", "Accurate to 3 meters", () async {
                Navigator.pop(context);
                LocationPermission permission = await Geolocator.checkPermission();
                if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
                if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
                  Position pos = await Geolocator.getCurrentPosition();
                  final msgId = const Uuid().v4();
                  await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(msgId).set({
                    'id': msgId, 'sender_id': _currentUserId, 'type': 'location', 'media_type': 'location', 'latitude': pos.latitude, 'longitude': pos.longitude, 'text': 'https://maps.google.com/?q=${pos.latitude},${pos.longitude}', 'created_at': FieldValue.serverTimestamp(), 'is_read': false,
                  });
                }
              }),
              _buildActionTile(Icons.location_searching, Colors.green, "Share My Live Location for...", "Updated in real time as you move", () {
                 _showSnack('Live location requires background service implementation.');
              }),
            ],
          ),
        ),
      ],
    );
  }

  // Image 7: Contacts (Luma Chat only)
  Widget _buildContactsPicker() {
    return FutureBuilder<List<Contact>>(
      future: FlutterContacts.getContacts(withProperties: true),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
        if (!snapshot.hasData || snapshot.data!.isEmpty) return const Center(child: Text("No contacts found or permission denied"));
        
        final contacts = snapshot.data!;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: TextField(
                decoration: InputDecoration(hintText: "Search contacts", prefixIcon: const Icon(Icons.search), filled: true, fillColor: Colors.grey[100], border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none)),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: contacts.length,
                itemBuilder: (context, index) {
                  final c = contacts[index];
                  final name = c.displayName ?? 'Unknown';
                  final phone = c.phones.isNotEmpty ? c.phones.first.number : 'No number';
                  return ListTile(
                    leading: CircleAvatar(backgroundColor: Colors.blue, child: Text(name[0], style: const TextStyle(color: Colors.white))),
                    title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(phone, style: TextStyle(color: Colors.grey[600])),
                    onTap: () async {
                      Navigator.pop(context);
                      final msgId = const Uuid().v4();
                      await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(msgId).set({
                        'id': msgId, 'sender_id': _currentUserId, 'type': 'contact', 'media_type': 'contact', 'text': '$name\n$phone', 'created_at': FieldValue.serverTimestamp(), 'is_read': false,
                      });
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  // Image 8: Music Picker
  Widget _buildMusicPicker() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12.0),
          child: TextField(
            decoration: InputDecoration(hintText: "Search music", prefixIcon: const Icon(Icons.search), filled: true, fillColor: Colors.grey[100], border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none)),
          ),
        ),
        ListTile(
          leading: const CircleAvatar(backgroundColor: Colors.blue, child: Icon(Icons.audio_file, color: Colors.white)),
          title: const Text("Pick Audio File from Device"),
          subtitle: const Text("Select an MP3 or M4A"),
          onTap: () async {
            FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.audio);
            if (result != null) {
              Navigator.pop(context);
              _showSnack('Uploading Audio...');
              final file = File(result.files.single.path!);
              final url = await CloudinaryService.uploadAudio(file, 'luma/music');
              if(url != null) {
                final msgId = const Uuid().v4();
                await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(msgId).set({
                  'id': msgId, 'sender_id': _currentUserId, 'type': 'audio', 'media_type': 'audio', 'media_url': url, 'file_name': result.files.single.name, 'created_at': FieldValue.serverTimestamp(), 'is_read': false,
                });
              }
            }
          },
        ),
      ],
    );
  }

  // Helper methods for Bottom Sheet
  Widget _buildListTile(IconData icon, Color color, String title, String subtitle, {required VoidCallback onTap}) {
    return ListTile(
      leading: CircleAvatar(backgroundColor: color, child: Icon(icon, color: Colors.white)),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Text(subtitle, style: TextStyle(color: Colors.grey[600])),
      onTap: onTap,
    );
  }

    Widget _buildActionTile(IconData icon, Color color, String title, String subtitle, VoidCallback onTap) {
    return ListTile(
      leading: CircleAvatar(backgroundColor: color, child: Icon(icon, color: Colors.white)),
      title: Text(title, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
      subtitle: Text(subtitle),
      onTap: onTap,
    );
  }

  // ==========================================
  // IMAGE 9: Sticker/GIF/Emoji Bottom Tab (Redesign)
  // ==========================================
  Widget _buildBottomTabBar(StateSetter setModalState) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.black12)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildTabIcon(Icons.photo_library, "Gallery", 0, setModalState),
          _buildTabIcon(Icons.insert_drive_file, "File", 1, setModalState),
          _buildTabIcon(Icons.location_on, "Location", 2, setModalState),
          _buildTabIcon(Icons.person, "Contact", 3, setModalState),
          _buildTabIcon(Icons.music_note, "Music", 4, setModalState),
        ],
      ),
    );
  }

  Widget _buildTabIcon(IconData icon, String label, int index, StateSetter setModalState) {
    bool isSelected = _selectedBottomTab == index;
    return GestureDetector(
      onTap: () {
        setModalState(() {
          _selectedBottomTab = index;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue[50] : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: isSelected ? Colors.blue : Colors.black87, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.blue : Colors.black87,
                fontSize: 10,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _attachTile(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap, 
      child: Column(
        mainAxisSize: MainAxisSize.min, 
        children: [
          Container(width: 56, height: 56, decoration: const BoxDecoration(color: Color(0xFF3390EC), shape: BoxShape.circle), child: Icon(icon, color: Colors.white, size: 26)), 
          const SizedBox(height: 8), 
          Text(label, style: const TextStyle(fontSize: 12))
        ]
      )
    );
  }

  Widget _headerCircle({required IconData icon, required VoidCallback onTap}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2), 
      child: Material(
        color: Colors.black12, 
        shape: const CircleBorder(), 
        child: InkWell(
          customBorder: const CircleBorder(), 
          onTap: onTap, 
          child: SizedBox(width: 40, height: 40, child: Icon(icon, color: Colors.white, size: 20))
        )
      )
    );
  }

  Widget _buildPinnedBanner(ThemeData theme) {
    final p = _pinnedMessages.first;
    final msg = _findMessage(p['message_id']);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), 
      color: theme.colorScheme.primary.withOpacity(0.1), 
      child: Row(
        children: [
          const Icon(Icons.push_pin, size: 16, color: Color(0xFF3390EC)), 
          const SizedBox(width: 8), 
          Expanded(child: Text((msg?['text'] ?? 'Pinned message').toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))), 
          IconButton(
            icon: const Icon(Icons.close, size: 16), 
            onPressed: () async { 
              await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('pinned_messages').doc(p['id']).delete(); 
              _loadPinnedMessages(); 
            }
          )
        ]
      )
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
              onDoubleTap: () async { await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(msg['id']).update({'reactions.❤️': FieldValue.arrayUnion([_currentUserId])}); },
              onLongPress: () => _showMessageMenu(msg),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: isSelected ? const Color(0xFF3390EC).withOpacity(0.3) : (isMe ? (isDark ? const Color(0xFF005C4B) : const Color(0xFFEFFDDE)) : (isDark ? const Color(0xFF1F2C34) : Colors.white)), borderRadius: BorderRadius.circular(12)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!isMe) Text(sender['display_name'], style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF4FAE4F))),
                    if (msg['reply_to'] != null) Container(margin: const EdgeInsets.only(bottom: 6), padding: const EdgeInsets.all(6), decoration: BoxDecoration(color: Colors.black.withOpacity(0.1), border: const Border(left: BorderSide(color: Color(0xFF3390EC), width: 3)), borderRadius: BorderRadius.circular(4)), child: Text((msg['reply_to_content'] ?? 'Quoted').toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
                    if (msg['media_type'] == 'image' && msg['media_url'] != null) GestureDetector(onTap: () => _downloadAndOpen(msg['media_url'], 'image'), child: Stack(alignment: Alignment.center, children: [CachedNetworkImage(imageUrl: msg['media_url'], width: 200, fit: BoxFit.cover), Container(padding: const EdgeInsets.all(8), decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle), child: const Icon(Icons.download, color: Colors.white))])),
                    if (msg['media_type'] == 'video' && msg['media_url'] != null) _buildVideoBubble(msg['media_url']),
                    if (msg['media_type'] == 'audio' && msg['media_url'] != null) _buildAudioBubble(msg),
                    if (msg['media_type'] == 'sticker' || msg['media_type'] == 'gif') CachedNetworkImage(imageUrl: msg['media_url'], width: 150, fit: BoxFit.contain),
                    if ((msg['text'] ?? '').toString().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(msg['text'], style: TextStyle(color: isMe && isDark ? Colors.white : theme.colorScheme.onSurface, fontSize: 15))),
                    const SizedBox(height: 4),
                    Row(mainAxisSize: MainAxisSize.min, children: [Text(DateFormat('HH:mm').format((msg['created_at'] as Timestamp?)?.toDate() ?? DateTime.now()), style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurface.withOpacity(0.5))), if (isMe) ...[const SizedBox(width: 4), Icon(msg['is_read'] == true ? Icons.done_all : Icons.done, size: 14, color: msg['is_read'] == true ? const Color(0xFF4FC3F7) : theme.colorScheme.onSurface.withOpacity(0.5))]]),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAudioBubble(Map<String, dynamic> msg) {
    final isPlaying = _currentlyPlayingId == msg['id'];
    return Container(width: 200, padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(8)), child: Row(children: [IconButton(icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white), onPressed: () { if (isPlaying) { _audioPlayer.pause(); setState(() => _currentlyPlayingId = null); } else { _audioPlayer.setUrl(msg['media_url']).then((_) { _audioPlayer.play(); setState(() => _currentlyPlayingId = msg['id']); }); } }), Expanded(child: isPlaying ? LinearProgressIndicator(value: _audioDuration.inMilliseconds > 0 ? _audioPosition.inMilliseconds / _audioDuration.inMilliseconds : 0, color: Colors.white, backgroundColor: Colors.white24) : Text('${msg['duration'] ?? 0}s', style: const TextStyle(color: Colors.white)))]));
  }

  Widget _buildVideoBubble(String url) {
    final controller = _videoControllers.putIfAbsent(url, () { final c = VideoPlayerController.networkUrl(Uri.parse(url)); c.initialize().then((_) => setState(() {})); return c; });
    return GestureDetector(onTap: () { if (controller.value.isPlaying) controller.pause(); else controller.play(); setState(() {}); }, child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Container(width: 200, height: 150, color: Colors.black, child: controller.value.isInitialized ? Stack(alignment: Alignment.center, children: [VideoPlayer(controller), Icon(controller.value.isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 40)]) : const Center(child: CircularProgressIndicator()))));
  }

  void _showMessageMenu(Map<String, dynamic> msg) {
    showModalBottomSheet(context: context, builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.reply), title: const Text('Reply'), onTap: () { Navigator.pop(context); setState(() => _replyingTo = msg['id']); }),
      ListTile(leading: const Icon(Icons.copy), title: const Text('Copy'), onTap: () { Clipboard.setData(ClipboardData(text: msg['text'] ?? '')); Navigator.pop(context); }),
      if (_isMePremium) ...[
        ListTile(leading: const Icon(Icons.summarize), title: const Text('Summarize (AI)'), onTap: () { Navigator.pop(context); _processAiAction('summarize', msg['text'] ?? ''); }),
        ListTile(leading: const Icon(Icons.translate), title: const Text('Translate (AI)'), onTap: () { Navigator.pop(context); _processAiAction('translate', msg['text'] ?? ''); }),
      ],
      ListTile(leading: const Icon(Icons.format_bold), title: const Text('Format (Bold)'), onTap: () { Navigator.pop(context); _messageController.text = '**${msg['text']}**'; setState(() => _replyingTo = msg['id']); }),
      ListTile(leading: const Icon(Icons.push_pin), title: const Text('Pin'), onTap: () async { Navigator.pop(context); await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('pinned_messages').doc(msg['id']).set({'message_id': msg['id'], 'pinned_at': FieldValue.serverTimestamp()}); _loadPinnedMessages(); }),
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

  Future<void> _downloadAndOpen(String url, String type) async {
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    try {
      final response = await http.get(Uri.parse(url));
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/luma_${DateTime.now().millisecondsSinceEpoch}.${type == 'image' ? 'jpg' : 'mp4'}');
      await file.writeAsBytes(response.bodyBytes);
      if (mounted) { Navigator.pop(context); if (type == 'image') Navigator.push(context, MaterialPageRoute(builder: (_) => _ImageViewerScreen(imagePath: file.path))); else await OpenFilex.open(file.path); }
    } catch (e) { if (mounted) { Navigator.pop(context); _showSnack('Download failed: $e'); } }
  }

  Widget _buildReplyBar(ThemeData theme) {
    final msg = _findMessage(_replyingTo);
    return Container(padding: const EdgeInsets.all(8), color: theme.colorScheme.surfaceVariant.withOpacity(0.5), child: Row(children: [const Icon(Icons.reply, size: 18, color: Color(0xFF3390EC)), const SizedBox(width: 8), Expanded(child: Text((msg?['text'] ?? 'Message').toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))), IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() => _replyingTo = null))]));
  }

  Widget _buildMultiSelectBar(ThemeData theme) {
    return Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), color: theme.colorScheme.surfaceVariant.withOpacity(0.5), child: Row(children: [IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() { _multiSelectMode = false; _selectedIds.clear(); })), Text('${_selectedIds.length} selected', style: const TextStyle(fontWeight: FontWeight.bold)), const Spacer(), IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: () async { for (final id in _selectedIds) { await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(id).update({'deleted_for_everyone': true, 'text': 'Deleted'}); } setState(() { _multiSelectMode = false; _selectedIds.clear(); }); })]));
  }

  Widget _buildRecordingBar(ThemeData theme) {
    return Container(padding: const EdgeInsets.all(12), color: Colors.red.withOpacity(0.1), child: Row(children: [const Icon(Icons.mic, color: Colors.red), const SizedBox(width: 12), Text('Recording... ${_recordingSeconds}s', style: const TextStyle(color: Colors.red)), const Spacer(), IconButton(icon: const Icon(Icons.send, color: Colors.red), onPressed: () => _stopRecording(send: true)), IconButton(icon: const Icon(Icons.close, color: Colors.grey), onPressed: () => _stopRecording(send: false))]));
  }
}

class _ImageViewerScreen extends StatelessWidget {
  final String imagePath;
  const _ImageViewerScreen({required this.imagePath});
  @override
  Widget build(BuildContext context) => Scaffold(backgroundColor: Colors.black, appBar: AppBar(backgroundColor: Colors.black, leading: IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(context))), body: Center(child: Image.file(File(imagePath))));
}
