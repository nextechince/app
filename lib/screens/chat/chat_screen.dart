import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../services/api_config.dart'; 
import '../../services/cloudinary_service.dart';

class ChatScreen extends StatefulWidget {
  final String? chatId;
  final String? chatName;
  final String? chatAvatar;
  final String? otherUserId;

  const ChatScreen({
    super.key,
    this.chatId,
    this.chatName,
    this.chatAvatar,
    this.otherUserId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _picker = ImagePicker();
  final _audioPlayer = AudioPlayer();

  String? _currentUserId;
  String? _wallpaperUrl;
  bool _isMePremium = false;
  bool _isRecording = false;
  int _recordingSeconds = 0;
  Timer? _recordingTimer;
  
  // Panel Toggle (Emoji/Keyboard)
  bool _showEmojiPanel = false;
  bool _isKeyboardOpen = false;

  List<Map<String, dynamic>> _messages = [];
  StreamSubscription? _messageSubscription;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initChat();
  }

  Future<void> _initChat() async {
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    _currentUserId = auth.user?.uid ?? auth.mockUserId;
    if (_currentUserId == null || widget.chatId == null) return;

    _loadWallpaper();
    _listenToPremiumStatus();
    _subscribeToMessages();
  }

  Future<void> _loadWallpaper() async {
    final doc = await FirebaseFirestore.instance.collection('user_settings').doc(_currentUserId).get();
    if (doc.exists && mounted) {
      final walls = doc.data()?['chat_wallpapers'] as Map<String, dynamic>? ?? {};
      setState(() => _wallpaperUrl = walls[widget.chatId] ?? doc.data()?['default_wallpaper']);
    }
  }

  void _listenToPremiumStatus() {
    FirebaseFirestore.instance.collection('users').doc(_currentUserId).snapshots().listen((doc) {
      if (mounted && doc.exists) {
        setState(() => _isMePremium = doc.data()?['is_premium'] == true);
      }
    });
  }

  void _subscribeToMessages() {
    _messageSubscription?.cancel();
    _messageSubscription = FirebaseFirestore.instance
        .collection('chats').doc(widget.chatId).collection('messages')
        .orderBy('created_at', descending: true)
        .limit(100)
        .snapshots().listen((snap) {
      if (!mounted) return;
      final loaded = snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
      setState(() {
        _messages = loaded;
        _isLoading = false;
      });
    });
  }

  // ═══════════════════════════════════════════════════════════════════════
  // REAL ACTIONS
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _sendText() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    
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
    });

    await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).update({
      'last_message': text,
      'last_message_at': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _pickAndSendMedia(String type) async {
    final x = type == 'image' 
        ? await _picker.pickImage(source: ImageSource.gallery, imageQuality: 90) 
        : await _picker.pickVideo(source: ImageSource.gallery);
        
    if (x == null) return;
    final file = File(x.path);
    final size = await file.length();

    // 🚨 200MB Limit
    final limitBytes = _isMePremium ? (5 * 1024 * 1024 * 1024) : (200 * 1024 * 1024); 
    if (size > limitBytes) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_isMePremium ? 'Max 5GB' : 'Upgrade to Premium to send files over 200MB!')));
      return;
    }

    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Uploading...')));

    final url = type == 'image' 
        ? await CloudinaryService.uploadImage(file, 'luma/chats') 
        : await CloudinaryService.uploadVideo(file, 'luma/chats');

    if (url != null && mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      final msgId = const Uuid().v4();
      await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(msgId).set({
        'id': msgId,
        'sender_id': _currentUserId,
        'type': type,
        'media_type': type,
        'media_url': url,
        'created_at': FieldValue.serverTimestamp(),
      });
    }
  }

  void _toggleEmojiPanel() {
    if (_showEmojiPanel) {
      setState(() => _showEmojiPanel = false);
      SystemChannels.textInput.invokeMethod('TextInput.show');
    } else {
      FocusScope.of(context).unfocus();
      setState(() => _showEmojiPanel = true);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // AI ACTIONS
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _processAiAction(String action, String text) async {
    if (!_isMePremium) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Upgrade to Premium to use AI tools!')));
      return;
    }

    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    
    try {
      final model = GenerativeModel(model: 'gemini-pro', apiKey: ApiConfig.geminiApiKey);
      final prompt = action == 'summarize' 
          ? 'Summarize this message: "$text"' 
          : 'Translate this to English: "$text"';
          
      final response = await model.generateContent([Content.text(prompt)]);
      
      if (mounted) {
        Navigator.pop(context);
        showDialog(context: context, builder: (_) => AlertDialog(title: Text(action.toUpperCase()), content: Text(response.text ?? 'No response'), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))]));
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('AI Error: $e')));
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // UI BUILD (Exact Telegram Style from Images)
  // ═══════════════════════════════════════════════════════════════════════
  @override
  void dispose() {
    _messageSubscription?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    _audioPlayer.dispose();
    _recordingTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Detect keyboard open/close
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    if (bottomInset > 0 && _showEmojiPanel) {
      setState(() => _showEmojiPanel = false);
    }

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
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(20)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(widget.chatName ?? 'Chat', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                        const Text('online', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                _headerCircle(icon: Icons.call, onTap: () {}),
                _headerCircle(icon: Icons.more_vert, onTap: () {}),
              ],
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                if (_wallpaperUrl != null)
                  Positioned.fill(child: Image.network(_wallpaperUrl!, fit: BoxFit.cover, opacity: const AlwaysStoppedAnimation(0.3))),
                _isLoading 
                    ? const Center(child: CircularProgressIndicator()) 
                    : ListView.builder(
                        controller: _scrollController,
                        reverse: true,
                        padding: const EdgeInsets.all(16),
                        itemCount: _messages.length,
                        itemBuilder: (context, i) => _buildMessageBubble(_messages[i], isDark),
                      ),
              ],
            ),
          ),
          
          // 🟢 THE EXACT TELEGRAM INPUT BAR FROM THE IMAGE 🟢
          Container(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            color: isDark ? const Color(0xFF17212B) : const Color(0xFFF0F0F0),
            child: SafeArea(
              top: false,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Keyboard / Emoji Icon
                  IconButton(
                    icon: Icon(
                      _showEmojiPanel ? Icons.keyboard : Icons.emoji_emotions_outlined,
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                    ),
                    onPressed: _toggleEmojiPanel,
                  ),
                  
                  // Text Input field with Clip & Camera inside
                  Expanded(
                    child: Container(
                      constraints: const BoxConstraints(maxHeight: 120),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF242F3D) : Colors.white,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _messageController,
                              minLines: 1,
                              maxLines: null,
                              keyboardType: TextInputType.multiline,
                              style: TextStyle(color: theme.colorScheme.onSurface, fontSize: 15),
                              decoration: InputDecoration(
                                hintText: 'Message',
                                hintStyle: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.4), fontSize: 15),
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              ),
                              onTap: () {
                                if (_showEmojiPanel) setState(() => _showEmojiPanel = false);
                              },
                            ),
                          ),
                          // Clip Icon
                          IconButton(
                            icon: Icon(Icons.attach_file, color: theme.colorScheme.onSurface.withOpacity(0.6)),
                            onPressed: () {},
                          ),
                          // Camera Icon
                          IconButton(
                            icon: Icon(Icons.camera_alt_outlined, color: theme.colorScheme.onSurface.withOpacity(0.6)),
                            onPressed: () => _pickAndSendMedia('image'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  
                  const SizedBox(width: 8),
                  
                  // Separate Circular Mic / Send Button
                  GestureDetector(
                    onTap: _messageController.text.trim().isEmpty ? null : _sendText,
                    child: CircleAvatar(
                      radius: 24,
                      backgroundColor: const Color(0xFF3390EC),
                      child: Icon(
                        _messageController.text.trim().isEmpty ? Icons.mic : Icons.send,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 🟢 THE EXACT TELEGRAM EMOJI PANEL FROM THE IMAGE 🟢
          if (_showEmojiPanel)
            SizedBox(
              height: 300, // Adjust height as needed
              child: EmojiPicker(
                onEmojiSelected: (category, emoji) {
                  _messageController.text += emoji.emoji;
                },
                onBackspacePressed: () {
                  if (_messageController.text.isNotEmpty) {
                    _messageController.text = _messageController.text.substring(0, _messageController.text.length - 1);
                  }
                },
                config: Config(
                  height: 300,
                  checkPlatformCompatibility: true,
                  emojiViewConfig: EmojiViewConfig(
                    backgroundColor: isDark ? const Color(0xFF17212B) : Colors.white,
                    columns: 8,
                    emojiSizeMax: 28,
                  ),
                  categoryViewConfig: CategoryViewConfig(
                    backgroundColor: isDark ? const Color(0xFF17212B) : Colors.white,
                    indicatorColor: const Color(0xFF3390EC),
                    iconColor: theme.colorScheme.onSurface.withOpacity(0.5),
                    iconColorSelected: const Color(0xFF3390EC),
                  ),
                  bottomActionBarConfig: BottomActionBarConfig(
                    backgroundColor: isDark ? const Color(0xFF17212B) : Colors.white,
                    buttonColor: theme.colorScheme.onSurface.withOpacity(0.1),
                    buttonIconColor: theme.colorScheme.onSurface,
                  ),
                  searchViewConfig: SearchViewConfig(
                    backgroundColor: isDark ? const Color(0xFF17212B) : Colors.white,
                    buttonIconColor: theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ),
        ],
      ),
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
          child: SizedBox(width: 40, height: 40, child: Icon(icon, color: Colors.white, size: 20)),
        ),
      ),
    );
  }

  Widget _buildMessageBubble(Map<String, dynamic> msg, bool isDark) {
    final isMe = msg['sender_id'] == _currentUserId;
    final type = msg['media_type'] ?? 'text';
    final text = msg['text'] ?? '';
    final mediaUrl = msg['media_url'];

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () {
          showModalBottomSheet(
            context: context,
            builder: (_) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isMePremium) ...[
                    ListTile(leading: const Icon(Icons.summarize), title: const Text('Summarize (AI)'), onTap: () { Navigator.pop(context); _processAiAction('summarize', text); }),
                    ListTile(leading: const Icon(Icons.translate), title: const Text('Translate (AI)'), onTap: () { Navigator.pop(context); _processAiAction('translate', text); }),
                  ] else
                    ListTile(leading: const Icon(Icons.lock), title: const Text('Upgrade to Premium for AI'), onTap: () => Navigator.pop(context)),
                  ListTile(leading: const Icon(Icons.copy), title: const Text('Copy'), onTap: () { Clipboard.setData(ClipboardData(text: text)); Navigator.pop(context); }),
                ],
              ),
            ),
          );
        },
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
          decoration: BoxDecoration(
            color: isMe ? (isDark ? const Color(0xFF005C4B) : const Color(0xFFEFFDDE)) : (isDark ? const Color(0xFF1F2C34) : Colors.white),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (type == 'image' && mediaUrl != null)
                GestureDetector(
                  onTap: () {},
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CachedNetworkImage(imageUrl: mediaUrl, width: 200, fit: BoxFit.cover),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                        child: const Icon(Icons.download, color: Colors.white),
                      )
                    ],
                  ),
                ),
              if (text.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(text, style: TextStyle(color: isMe && isDark ? Colors.white : Colors.black)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
