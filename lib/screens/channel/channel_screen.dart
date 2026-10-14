import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_view/photo_view.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../services/cloudinary_service.dart';

// ═══════════════════════════════════════════════════════════════════════════
// LOCAL NATIVE RECORDER — no external package
// ═══════════════════════════════════════════════════════════════════════════
class LocalRecorder {
  static const _channel = MethodChannel('com.lumachat.app/recorder');

  Future<bool> hasPermission() async => true;

  Future<void> start(String path) async {
    await _channel.invokeMethod('start', {'path': path});
  }

  Future<String?> stop() async {
    return await _channel.invokeMethod<String>('stop');
  }

  Future<void> cancel() async {
    await _channel.invokeMethod('cancel');
  }

  Future<void> dispose() async {
    try {
      await _channel.invokeMethod('cancel');
    } catch (_) {}
  }
}

class ChannelChatScreen extends StatefulWidget {
  final String channelId;
  final String channelName;

  const ChannelChatScreen({
    super.key,
    required this.channelId,
    required this.channelName,
  });

  @override
  State<ChannelChatScreen> createState() => _ChannelChatScreenState();
}

class _ChannelChatScreenState extends State<ChannelChatScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final _messageController = TextEditingController();
  final _editController = TextEditingController();
  final _gifSearchController = TextEditingController();
  final _scrollController = ScrollController();
  final _messageFocusNode = FocusNode();

  final AudioPlayer _audioPlayer = AudioPlayer();
  final LocalRecorder _audioRecorder = LocalRecorder();
  final ImagePicker _picker = ImagePicker();

  String? _currentUserId;
  String? _myRole = 'member';
  bool get _isAdmin =>
      _myRole == 'owner' || _myRole == 'admin' || _myRole == 'creator';

  bool _isLoading = false;
  bool _initialized = false;

  String? _channelAvatarUrl;
  String? _channelDescription;
  String? _channelLink;
  String? _channelUsername;
  String? _linkedGroupId;
  int _subscriberCount = 0;
  bool _signaturesEnabled = true;

  bool _silentMode = false;
  DateTime? _scheduledAt;

  String? _panelMode;
  String _pickerTab = 'emoji';
  double _keyboardHeight = 300;

  static const Map<String, Map<String, dynamic>> _emojiCategories = {
    'recent': {
      'icon': '🕐',
      'emojis': ['👍','❤️','😂','🔥','😍','🥰','😎','🙏','💯','🎉','😭','🤣','👏','💪','✨'],
    },
    'smileys': {
      'icon': '😀',
      'emojis': ['😀','😃','😄','😁','😆','😅','🤣','😂','🙂','🙃','😉','😊','😇','🥰','😍','🤩','😘','😗','😚','😙','😋','😛','😜','🤪','😝','🤑','🤗','🤭','🤫','🤔','🤐','🤨','😐','😑','😶','😏','😒','🙄','😬','🤥','😌','😔','😪','🤤','😴','😷','🤒','🤕','🤢','🤮','🤧','🥵','🥶','😵','🤯','🤠','🥳','😎','🤓','🧐'],
    },
    'love': {
      'icon': '❤️',
      'emojis': ['❤️','🧡','💛','💚','💙','💜','🖤','🤍','🤎','💔','❣️','💕','💞','💓','💗','💖','💘','💝','💟','♥️','💋','🌹','🌷','🌺','🌸','💐','💌'],
    },
    'gestures': {
      'icon': '👍',
      'emojis': ['👍','👎','👌','🤌','🤏','✌️','🤞','🤟','🤘','🤙','👈','👉','👆','👇','☝️','👋','🤚','🖐️','✋','🖖','👏','🙌','🤲','🤝','🙏','✍️','💪','👂','👃','👀','👁️','👅','👄'],
    },
    'animals': {
      'icon': '🐶',
      'emojis': ['🐶','🐱','🐭','🐹','🐰','🦊','🐻','🐼','🐨','🐯','🦁','🐮','🐷','🐸','🐵','🐔','🐧','🐦','🐤','🦆','🦅','🦉','🦇','🐺','🐴','🦄','🐝','🐛','🦋','🐌','🐞','🐜','🐢','🐍','🐙','🐬','🐳','🦈','🐊','🐘'],
    },
    'food': {
      'icon': '🍔',
      'emojis': ['🍏','🍎','🍐','🍊','🍋','🍌','🍉','🍇','🍓','🫐','🍈','🍒','🍑','🥭','🍍','🥥','🥝','🍅','🍆','🥑','🥦','🥬','🥒','🌶️','🌽','🥕','🥔','🍞','🥖','🧀','🥚','🍳','🥓','🥩','🍗','🍔','🍟','🍕','🌮','🍝','🍜','🍣','🍱','🍚','🍙','🍢','🍡','🍦','🍰','🎂'],
    },
    'activities': {
      'icon': '⚽',
      'emojis': ['⚽','🏀','🏈','⚾','🥎','🎾','🏐','🏉','🎱','🏓','🏸','🏒','🥅','⛳','🏹','🎣','🥊','🥋','🛹','🛼','🛷','⛸️','🎿','⛷️','🏂','🏋️','🤼','🤸','⛹️','🤺','🤾','🏌️','🏇','🧘','🏄','🏊','🚣','🧗','🚵','🚴','🏆','🥇','🥈','🥉','🏅'],
    },
    'travel': {
      'icon': '✈️',
      'emojis': ['🚗','🚕','🚙','🚌','🏎️','🚓','🚑','🚒','🚐','🚚','🚛','🚜','🛴','🚲','🛵','🏍️','🚨','🚔','🚃','🚋','🚞','🚝','🚄','🚅','🚈','🚂','🚆','🚇','🚊','🚉','✈️','🛫','🛬','🚀','🛸','🚁','⛵','🚤','🛳️','⛴️','🚢','⚓'],
    },
    'objects': {
      'icon': '💡',
      'emojis': ['⌚','📱','💻','⌨️','🖥️','🖨️','🖱️','🕹️','💽','💾','💿','📀','📼','📷','📸','📹','🎥','📽️','📞','☎️','📟','📠','📺','📻','🎙️','🧭','⏱️','⏰','🕰️','⌛','⏳','📡','🔋','🔌','💡','🔦','🕯️','💸','💵','💰','💳','💎','🔧','🔨','⚙️'],
    },
    'symbols': {
      'icon': '💯',
      'emojis': ['✅','❌','❎','✔️','☑️','🔘','🔴','🟠','🟡','🟢','🔵','🟣','⚫','⚪','🟤','🔺','🔻','🔸','🔹','🔶','🔷','🔳','🔲','▪️','▫️','◾','◽','◼️','◻️','🔈','🔇','🔉','🔊','🔔','🔕','📣','📢','💬','💭','💯','🔢','🔤'],
    }
  };
  String _currentEmojiCategory = 'recent';

  List<Map<String, dynamic>> _myStickers = [];
  List<Map<String, dynamic>> _favoriteStickers = [];
  List<Map<String, dynamic>> _stickerPacks = [];
  String _currentStickerPackId = 'fav';
  bool _loadingStickers = false;

  static const String _giphyApiKey = '7tXB3cisPGymcszQX85JFOY6kp3Gz47T';
  List<Map<String, dynamic>> _gifs = [];
  bool _loadingGifs = false;
  bool _gifsLoaded = false;

  bool _isRecording = false;
  bool _isRecordingLocked = false;
  double _recordingSlideOffset = 0;
  double? _recordingDragStartX;
  Timer? _recordingTimer;
  Timer? _recordingSecondsTimer;
  int _recordingSeconds = 0;
  String? _recordingPath;
  final List<double> _recordingWave = [];

  bool _isPlayingAudio = false;
  String? _currentlyPlayingAudioId;
  Duration _audioDuration = Duration.zero;
  Duration _audioPosition = Duration.zero;

  File? _selectedImage;
  File? _selectedVideo;

  final Map<String, VideoPlayerController> _videoControllers = {};

  String? _editingMessageId;
  String? _replyingTo;
  String? _replyingToContent;
  String? _replyingToSender;

  bool _multiSelectMode = false;
  final Set<String> _selectedMessageIds = {};

  Map<String, dynamic>? _pinnedMessage;
  StreamSubscription<QuerySnapshot>? _pinnedMessageSub;
  StreamSubscription<DocumentSnapshot>? _channelSub;

  final Set<String> _countedViews = {};
  final Map<String, Map<String, dynamic>> _userCache = {};

  Stream<QuerySnapshot> get _messagesStream => FirebaseFirestore.instance
      .collection('chats')
      .doc(widget.channelId)
      .collection('messages')
      .orderBy('created_at', descending: true)
      .limit(200)
      .snapshots();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAudioPlayer();
    _messageController.addListener(_onTextChanged);
    _messageFocusNode.addListener(_onFocusChange);
    _scrollController.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;

    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    _currentUserId = auth.user?.uid ?? auth.mockUserId;

    _loadChannelInfo();
    _subscribeToChannel();
    _listenToPinnedMessage();
    _loadStickers();
  }

  void _onFocusChange() {
    if (_messageFocusNode.hasFocus && _panelMode != null) {
      setState(() => _panelMode = null);
    }
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  void _onScroll() {}

  void _initAudioPlayer() {
    _audioPlayer.durationStream.listen((d) {
      if (mounted && d != null) setState(() => _audioDuration = d);
    });
    _audioPlayer.positionStream.listen((p) {
      if (mounted) setState(() => _audioPosition = p);
    });
    _audioPlayer.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() => _isPlayingAudio = state.playing);
      if (state.processingState == ProcessingState.completed) {
        setState(() {
          _currentlyPlayingAudioId = null;
          _audioPosition = Duration.zero;
        });
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _audioPlayer.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageController.removeListener(_onTextChanged);
    _messageFocusNode.removeListener(_onFocusChange);
    _scrollController.removeListener(_onScroll);
    _messageController.dispose();
    _editController.dispose();
    _gifSearchController.dispose();
    _scrollController.dispose();
    _messageFocusNode.dispose();
    _audioPlayer.dispose();
    _audioRecorder.dispose();
    _recordingTimer?.cancel();
    _recordingSecondsTimer?.cancel();
    _pinnedMessageSub?.cancel();
    _channelSub?.cancel();
    for (final v in _videoControllers.values) {
      v.dispose();
    }
    super.dispose();
  }

  Future<void> _loadChannelInfo() async {
    final doc = await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.channelId)
        .get();
    if (!doc.exists || !mounted) return;
    _applyChannelData(doc.data() as Map<String, dynamic>);
  }

  void _applyChannelData(Map<String, dynamic> data) {
    final parts = List<dynamic>.from(data['participants'] ?? const []);
    final role =
        (data['participants_data']?[_currentUserId]?['role'] ?? 'member')
            as String;
    setState(() {
      _channelAvatarUrl = data['avatar_url'] as String?;
      _channelDescription = data['description'] as String?;
      _channelLink = data['invitation_link'] as String?;
      _channelUsername = data['username'] as String?;
      _linkedGroupId = data['linked_group_id'] as String?;
      _signaturesEnabled = data['signatures_enabled'] as bool? ?? true;
      _subscriberCount = parts.length;
      _myRole = role;
    });
  }

  void _subscribeToChannel() {
    _channelSub?.cancel();
    _channelSub = FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.channelId)
        .snapshots()
        .listen((doc) {
      if (!mounted || !doc.exists) return;
      _applyChannelData(doc.data() as Map<String, dynamic>);
    });
  }

  void _listenToPinnedMessage() {
    _pinnedMessageSub?.cancel();
    _pinnedMessageSub = FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.channelId)
        .collection('pinned_messages')
        .orderBy('pinned_at', descending: true)
        .limit(1)
        .snapshots()
        .listen((snapshot) async {
      if (!mounted) return;
      if (snapshot.docs.isEmpty) {
        setState(() => _pinnedMessage = null);
        return;
      }
      final messageId =
          snapshot.docs.first.data()['message_id'] as String?;
      if (messageId == null) {
        setState(() => _pinnedMessage = null);
        return;
      }
      final msgDoc = await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.channelId)
          .collection('messages')
          .doc(messageId)
          .get();
      if (msgDoc.exists && mounted) {
        final data = msgDoc.data()!;
        data['id'] = msgDoc.id;
        setState(() => _pinnedMessage = data);
      }
    });
  }

  bool get _isPublicChannel =>
      _channelUsername != null && _channelUsername!.isNotEmpty;

  void _goToChannelInfo() {
    Navigator.pushNamed(context, '/channel_info', arguments: {
      'chatId': widget.channelId,
      'chatName': widget.channelName,
      'chatAvatar': _channelAvatarUrl,
    });
  }

  Future<void> _incrementViewCount(String messageId) async {
    if (_currentUserId == null) return;
    final key = '${_currentUserId}_$messageId';
    if (_countedViews.contains(key)) return;
    _countedViews.add(key);
    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.channelId)
          .collection('messages')
          .doc(messageId)
          .update({
        'views_count': FieldValue.increment(1),
      });
    } catch (_) {}
  }

  Future<void> _fetchUser(String uid) async {
    if (_userCache.containsKey(uid)) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      if (doc.exists) {
        final d = doc.data()!;
        _userCache[uid] = {
          'display_name': d['display_name'] ?? d['username'] ?? 'User',
          'avatar_url': d['avatar_url'],
        };
      }
    } catch (_) {}
  }

  Future<void> _sendMessage({
    String? text,
    String? mediaUrl,
    String? mediaType,
    String? fileName,
    String? fileSize,
    int? duration,
    bool viewOnce = false,
  }) async {
    if (!_isAdmin) return;
    final content = (text ?? _messageController.text).trim();
    if (content.isEmpty &&
        mediaUrl == null &&
        _selectedImage == null &&
        _selectedVideo == null &&
        _recordingPath == null) {
      return;
    }

    setState(() => _isLoading = true);

    try {
      if (_currentUserId == null) throw Exception('Not authenticated');

      String? senderName;
      String? senderAvatar;
      if (_signaturesEnabled) {
        final userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(_currentUserId)
            .get();
        final userData = userDoc.data() ?? {};
        senderName = userData['display_name'] ??
            userData['username'] ??
            userData['name'];
        senderAvatar = userData['avatar_url'];
      }

      String? uploadedUrl;
      String? finalMediaType = mediaType;
      String? finalFileName = fileName;
      String? finalFileSize = fileSize;
      int? finalDuration = duration;

      if (_selectedImage != null) {
        uploadedUrl = await CloudinaryService.uploadImage(
            _selectedImage!, 'luma/channels/${widget.channelId}');
        finalMediaType = 'image';
      } else if (_selectedVideo != null) {
        uploadedUrl = await CloudinaryService.uploadVideo(
            _selectedVideo!, 'luma/channels/${widget.channelId}');
        finalMediaType = 'video';
        finalFileName = _selectedVideo!.path.split('/').last;
      } else if (_recordingPath != null) {
        final file = File(_recordingPath!);
        uploadedUrl = await CloudinaryService.uploadAudio(
            file, 'luma/channels/${widget.channelId}');
        finalMediaType = 'audio';
        finalDuration = _recordingSeconds;
      }

      if ((_selectedImage != null ||
              _selectedVideo != null ||
              _recordingPath != null) &&
          uploadedUrl == null) {
        throw Exception('Media upload failed');
      }

      final messageRef = FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.channelId)
          .collection('messages')
          .doc();

      final scheduled = _scheduledAt;

      await messageRef.set({
        'id': messageRef.id,
        'text': content.isNotEmpty ? content : null,
        'content': content.isNotEmpty ? content : null,
        'media_url': uploadedUrl ?? mediaUrl,
        'media_type': finalMediaType,
        'file_name': finalFileName,
        'file_size': finalFileSize,
        'duration': finalDuration,
        'sender_id': _currentUserId,
        'sender_name': senderName,
        'sender_avatar': senderAvatar,
        'is_silent': _silentMode,
        'view_once': viewOnce,
        'reply_to': _replyingTo,
        'reply_to_content': _replyingToContent,
        'reply_to_sender': _replyingToSender,
        'created_at': scheduled != null
            ? Timestamp.fromDate(scheduled)
            : FieldValue.serverTimestamp(),
        'scheduled_at':
            scheduled != null ? Timestamp.fromDate(scheduled) : null,
        'is_scheduled': scheduled != null,
        'is_edited': false,
        'deleted_for_everyone': false,
        'deleted_for': [],
        'reactions': {},
        'views_count': 0,
        'comments_count': 0,
        'post_type': 'message',
      });

      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.channelId)
          .update({
        'last_message': content.isNotEmpty
            ? content
            : (finalMediaType == 'image'
                ? '📷 Image'
                : finalMediaType == 'video'
                    ? '🎥 Video'
                    : finalMediaType == 'audio'
                        ? '🎤 Voice'
                        : finalMediaType == 'sticker'
                            ? '🎨 Sticker'
                            : finalMediaType == 'gif'
                                ? '🎞️ GIF'
                                : '📎 File'),
        'last_message_at': FieldValue.serverTimestamp(),
        'last_message_type': finalMediaType ?? 'text',
      });

      _messageController.clear();
      setState(() {
        _selectedImage = null;
        _selectedVideo = null;
        _recordingPath = null;
        _replyingTo = null;
        _replyingToContent = null;
        _replyingToSender = null;
        _silentMode = false;
        _scheduledAt = null;
      });
    } catch (e) {
      _showError('Failed to send: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _editMessage(String messageId, String newContent) async {
    if (newContent.trim().isEmpty) return;
    try {
      final ref = FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.channelId)
          .collection('messages')
          .doc(messageId);
      final doc = await ref.get();
      final old = (doc.data()?['text'] ?? '').toString();
      await ref.update({
        'text': newContent.trim(),
        'content': newContent.trim(),
        'is_edited': true,
        'updated_at': FieldValue.serverTimestamp(),
        'edit_history': FieldValue.arrayUnion([
          {
            'text': old,
            'edited_at': DateTime.now().toIso8601String(),
          }
        ]),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Post edited')),
        );
      }
    } catch (e) {
      _showError('Edit failed: $e');
    }
  }

  Future<void> _deleteForEveryone(String messageId) async {
    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.channelId)
          .collection('messages')
          .doc(messageId)
          .update({
        'deleted_for_everyone': true,
        'text': 'This message was deleted',
        'content': 'This message was deleted',
        'media_url': null,
        'updated_at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      _showError('Delete failed: $e');
    }
  }

  Future<void> _deleteForMe(String messageId) async {
    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.channelId)
          .collection('messages')
          .doc(messageId)
          .update({
        'deleted_for': FieldValue.arrayUnion([_currentUserId]),
      });
    } catch (e) {
      _showError('Delete failed: $e');
    }
  }

  Future<void> _pinMessage(String messageId) async {
    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.channelId)
          .collection('pinned_messages')
          .doc(messageId)
          .set({
        'message_id': messageId,
        'pinned_at': FieldValue.serverTimestamp(),
        'pinned_by': _currentUserId,
      });
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.channelId)
          .update({'pinned_message_id': messageId});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Post pinned')),
        );
      }
    } catch (e) {
      _showError('Pin failed: $e');
    }
  }

  Future<void> _unpinMessage(String messageId) async {
    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.channelId)
          .collection('pinned_messages')
          .doc(messageId)
          .delete();
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.channelId)
          .update({'pinned_message_id': FieldValue.delete()});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Post unpinned')),
        );
      }
    } catch (e) {
      _showError('Unpin failed: $e');
    }
  }

  Future<void> _toggleReaction(String messageId, String emoji) async {
    if (_currentUserId == null) return;
    try {
      final ref = FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.channelId)
          .collection('messages')
          .doc(messageId);
      final doc = await ref.get();
      if (!doc.exists) return;
      final reactions =
          Map<String, dynamic>.from(doc.data()?['reactions'] ?? {});
      final users = List<String>.from(reactions[emoji] ?? []);
      if (users.contains(_currentUserId)) {
        users.remove(_currentUserId);
        if (users.isEmpty) {
          reactions.remove(emoji);
        } else {
          reactions[emoji] = users;
        }
      } else {
        users.add(_currentUserId!);
        reactions[emoji] = users;
      }
      await ref.update({'reactions': reactions});
    } catch (e) {
      debugPrint('Reaction error: $e');
    }
  }

  Future<void> _pickImage() async {
    final picked = await _picker.pickImage(
        source: ImageSource.gallery, imageQuality: 80);
    if (picked != null) setState(() => _selectedImage = File(picked.path));
  }

  Future<void> _pickMultiImages() async {
    final xs = await _picker.pickMultiImage(imageQuality: 85);
    if (xs.isEmpty) return;
    setState(() => _selectedImage = File(xs.first.path));
  }

  Future<void> _takePhoto() async {
    final picked = await _picker.pickImage(
        source: ImageSource.camera, imageQuality: 80);
    if (picked != null) setState(() => _selectedImage = File(picked.path));
  }

  Future<void> _pickVideo() async {
    final picked = await _picker.pickVideo(source: ImageSource.gallery);
    if (picked != null) setState(() => _selectedVideo = File(picked.path));
  }

  Future<void> _recordVideo() async {
    final picked = await _picker.pickVideo(source: ImageSource.camera);
    if (picked != null) setState(() => _selectedVideo = File(picked.path));
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform
        .pickFiles(allowMultiple: false, withData: true);
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.path == null) return;
    final uploaded = await CloudinaryService.uploadFile(
        File(file.path!), 'luma/channels/${widget.channelId}');
    if (uploaded != null) {
      await _sendMessage(
        mediaUrl: uploaded,
        mediaType: 'file',
        fileName: file.name,
        fileSize: _formatFileSize(file.size),
      );
    } else {
      _showError('File upload failed');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // VOICE RECORDING — uses native MediaRecorder
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _startRecording() async {
    final hasPermission = await _audioRecorder.hasPermission();
    if (!hasPermission) {
      _showError('Microphone permission required');
      return;
    }
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _audioRecorder.start(path);
    if (!mounted) return;
    setState(() {
      _isRecording = true;
      _isRecordingLocked = false;
      _recordingSlideOffset = 0;
      _recordingPath = path;
      _recordingSeconds = 0;
      _recordingWave.clear();
    });
    _recordingTimer?.cancel();
    _recordingTimer =
        Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      setState(() {
        _recordingWave.add(0.3 + math.Random().nextDouble() * 0.7);
        if (_recordingWave.length > 30) _recordingWave.removeAt(0);
      });
    });
    _recordingSecondsTimer?.cancel();
    _recordingSecondsTimer =
        Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || !_isRecording) {
        t.cancel();
        return;
      }
      setState(() => _recordingSeconds++);
    });
  }

  Future<void> _stopRecording({bool send = true}) async {
    _recordingTimer?.cancel();
    _recordingSecondsTimer?.cancel();

    if (!send) {
      await _audioRecorder.cancel();
      if (!mounted) return;
      setState(() {
        _isRecording = false;
        _isRecordingLocked = false;
        _recordingSlideOffset = 0;
      });
      return;
    }

    final path = await _audioRecorder.stop();
    if (!mounted) return;
    setState(() {
      _isRecording = false;
      _isRecordingLocked = false;
      _recordingSlideOffset = 0;
    });
    if (path == null) return;
    final file = File(path);
    final size = await file.length();
    if (size < 1000) {
      await file.delete();
      return;
    }
    _recordingPath = path;
    await _sendMessage(
      mediaType: 'audio',
      fileName: 'Voice message',
      fileSize: _formatFileSize(size),
      duration: _recordingSeconds,
    );
    if (mounted) setState(() => _recordingPath = null);
  }

  void _lockRecording() {
    setState(() {
      _isRecordingLocked = true;
      _recordingSlideOffset = 0;
    });
  }

  Future<void> _playAudio(String messageId, String audioUrl) async {
    try {
      if (_currentlyPlayingAudioId == messageId) {
        if (_isPlayingAudio) {
          await _audioPlayer.pause();
        } else {
          await _audioPlayer.play();
        }
      } else {
        await _audioPlayer.stop();
        await _audioPlayer.setUrl(audioUrl);
        await _audioPlayer.play();
        if (!mounted) return;
        setState(() {
          _currentlyPlayingAudioId = messageId;
          _audioPosition = Duration.zero;
        });
      }
    } catch (e) {
      _showError('Playback failed: $e');
    }
  }

  Future<void> _openFile(String url, String? fileName) async {
    try {
      final dir = await getTemporaryDirectory();
      final ext = fileName?.split('.').last ?? 'bin';
      final path = '${dir.path}/${const Uuid().v4()}.$ext';
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      final f = File(path);
      await resp.pipe(f.openWrite());
      await OpenFilex.open(path);
    } catch (e) {
      _showError('Cannot open: $e');
    }
  }

  Future<void> _loadStickers() async {
    if (_currentUserId == null || _loadingStickers) return;
    setState(() => _loadingStickers = true);
    try {
      final f = await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUserId)
          .collection('stickers')
          .orderBy('created_at', descending: true)
          .limit(200)
          .get();
      final packs = await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUserId)
          .collection('sticker_packs')
          .orderBy('created_at', descending: true)
          .get();
      if (!mounted) return;
      setState(() {
        _myStickers =
            f.docs.map((d) => {'id': d.id, ...d.data()}).toList();
        _stickerPacks =
            packs.docs.map((d) => {'id': d.id, ...d.data()}).toList();
        _favoriteStickers =
            _myStickers.where((s) => s['favorite'] == true).toList();
        _loadingStickers = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingStickers = false);
    }
  }

  Future<void> _createStickerFromGallery({bool video = false}) async {
    final XFile? picked = video
        ? await _picker.pickVideo(source: ImageSource.gallery)
        : await _picker.pickImage(
            source: ImageSource.gallery, imageQuality: 85);
    if (picked == null) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Creating sticker...')));
    try {
      final file = File(picked.path);
      final url = video
          ? await CloudinaryService.uploadVideo(
              file, 'luma/stickers/$_currentUserId')
          : await CloudinaryService.uploadImage(
              file, 'luma/stickers/$_currentUserId');
      if (url == null) throw Exception('Upload failed');
      final ref = FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUserId)
          .collection('stickers')
          .doc();
      await ref.set({
        'id': ref.id,
        'url': url,
        'sticker_type': video ? 'video' : 'static',
        'favorite': false,
        'created_at': FieldValue.serverTimestamp(),
      });
      await _loadStickers();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Sticker created')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _deleteSticker(String id) async {
    await FirebaseFirestore.instance
        .collection('users')
        .doc(_currentUserId)
        .collection('stickers')
        .doc(id)
        .delete();
    await _loadStickers();
  }

  Future<void> _toggleFavoriteSticker(Map<String, dynamic> s) async {
    final ref = FirebaseFirestore.instance
        .collection('users')
        .doc(_currentUserId)
        .collection('stickers')
        .doc(s['id']);
    await ref.update({'favorite': !(s['favorite'] == true)});
    await _loadStickers();
  }

  Future<void> _sendSticker(Map<String, dynamic> s) async {
    setState(() => _panelMode = null);
    final ref = FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.channelId)
        .collection('messages')
        .doc();
    await ref.set({
      'id': ref.id,
      'media_url': s['url'],
      'media_type': 'sticker',
      'sticker': {
        'url': s['url'],
        'sticker_type': s['sticker_type'] ?? 'static',
      },
      'sender_id': _currentUserId,
      'created_at': FieldValue.serverTimestamp(),
      'reactions': {},
      'views_count': 0,
      'deleted_for_everyone': false,
    });
  }

  Future<void> _sendGif(String url) async {
    setState(() => _panelMode = null);
    final ref = FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.channelId)
        .collection('messages')
        .doc();
    await ref.set({
      'id': ref.id,
      'media_url': url,
      'media_type': 'gif',
      'gif_url': url,
      'sender_id': _currentUserId,
      'created_at': FieldValue.serverTimestamp(),
      'reactions': {},
      'views_count': 0,
      'deleted_for_everyone': false,
    });
  }

  Future<void> _loadGifs({String? q}) async {
    if (_loadingGifs) return;
    setState(() => _loadingGifs = true);
    try {
      final query = (q ?? '').trim();
      final endpoint = query.isEmpty
          ? 'https://api.giphy.com/v1/gifs/trending?api_key=$_giphyApiKey&limit=24&rating=g'
          : 'https://api.giphy.com/v1/gifs/search?api_key=$_giphyApiKey&q=${Uri.encodeComponent(query)}&limit=24&rating=g';
      final res = await http.get(Uri.parse(endpoint));
      if (res.statusCode != 200) throw Exception('Giphy ${res.statusCode}');
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = (body['data'] as List).cast<Map<String, dynamic>>();
      final gifs = data.map((g) {
        final images = g['images'] as Map<String, dynamic>?;
        final full = images?['downsized_medium']?['url'] ??
            images?['fixed_height']?['url'] ??
            images?['original']?['url'];
        final preview = images?['fixed_width']?['url'] ??
            images?['fixed_width_small']?['url'] ??
            full;
        return {'full': full, 'preview': preview};
      }).where((g) => g['full'] != null).toList();
      if (!mounted) return;
      setState(() {
        _gifs = gifs;
        _loadingGifs = false;
        _gifsLoaded = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _gifs = [];
          _loadingGifs = false;
          _gifsLoaded = true;
        });
      }
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatTime(dynamic ts) {
    if (ts == null) return '';
    final d = ts is Timestamp ? ts.toDate() : DateTime.tryParse(ts.toString());
    if (d == null) return '';
    return DateFormat('HH:mm').format(d);
  }

  String _formatDuration(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _formatViewCount(int count) {
    if (count < 1000) return '$count';
    if (count < 1000000) {
      return '${(count / 1000).toStringAsFixed(count < 10000 ? 1 : 0)}K';
    }
    return '${(count / 1000000).toStringAsFixed(1)}M';
  }

  String _formatSubscribers(int count) {
    if (count < 1000) return '$count subscribers';
    if (count < 1000000) {
      return '${(count / 1000).toStringAsFixed(count < 10000 ? 1 : 0)}K subscribers';
    }
    return '${(count / 1000000).toStringAsFixed(1)}M subscribers';
  }

  String _formatDateHeader(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yest = today.subtract(const Duration(days: 1));
    final md = DateTime(d.year, d.month, d.day);
    if (md == today) return 'Today';
    if (md == yest) return 'Yesterday';
    return DateFormat('MMMM d').format(d);
  }

  DateTime? _parseTs(dynamic t) {
    if (t == null) return null;
    if (t is Timestamp) return t.toDate();
    if (t is String) return DateTime.tryParse(t);
    return null;
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  void _showMessageOptions(Map<String, dynamic> msg, bool isMe) {
    final isDeleted = msg['deleted_for_everyone'] == true;
    final messageId = msg['id'] as String?;
    if (messageId == null) return;
    final isPinned =
        _pinnedMessage != null && _pinnedMessage!['id'] == messageId;

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'dismiss',
      barrierColor: Colors.black.withOpacity(0.4),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (ctx, _, __) {
        return _ChannelMsgOptionsOverlay(
          message: msg,
          isMe: isMe,
          isDeleted: isDeleted,
          isPinned: isPinned,
          isAdmin: _isAdmin,
          onReact: (e) {
            Navigator.pop(ctx);
            _toggleReaction(messageId, e);
          },
          onShowReactions: () {
            Navigator.pop(ctx);
            _showReactionsDetail(msg);
          },
          onEdit: () {
            Navigator.pop(ctx);
            _showEditDialog(messageId, msg['text'] ?? msg['content'] ?? '');
          },
          onEditHistory: () {
            Navigator.pop(ctx);
            _openEditHistory(messageId);
          },
          onCopy: () {
            Navigator.pop(ctx);
            Clipboard.setData(ClipboardData(
                text: (msg['text'] ?? msg['content'] ?? '').toString()));
          },
          onReply: () {
            Navigator.pop(ctx);
            setState(() {
              _replyingTo = messageId;
              _replyingToContent =
                  msg['text'] ?? msg['content'] ?? 'Media';
              _replyingToSender = msg['sender_name'] ?? 'Channel';
            });
          },
          onForward: () {
            Navigator.pop(ctx);
            _forwardMessage(msg);
          },
          onPinToggle: () {
            Navigator.pop(ctx);
            if (isPinned) {
              _unpinMessage(messageId);
            } else {
              _pinMessage(messageId);
            }
          },
          onSave: () {
            Navigator.pop(ctx);
            _saveToSaved(msg);
          },
          onDownload: () {
            Navigator.pop(ctx);
            _downloadMedia(msg['media_url'], msg['file_name'] ?? 'file');
          },
          onSelect: () {
            Navigator.pop(ctx);
            _enterMultiSelect(messageId);
          },
          onDeleteEveryone: () {
            Navigator.pop(ctx);
            _confirmDeleteEveryone(messageId);
          },
          onDeleteMe: () {
            Navigator.pop(ctx);
            _deleteForMe(messageId);
          },
          onReport: () {
            Navigator.pop(ctx);
            _reportMessage(msg);
          },
        );
      },
    );
  }

  Future<void> _showReactionsDetail(Map<String, dynamic> msg) async {
    final reactions = Map<String, dynamic>.from(msg['reactions'] ?? {});
    if (reactions.isEmpty) return;
    final entries = reactions.entries.toList();
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF1F1F1F)
          : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        top: false,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: entries.length,
          itemBuilder: (_, i) {
            final e = entries[i];
            final users = List<String>.from(e.value);
            return ListTile(
              leading: Text(e.key, style: const TextStyle(fontSize: 26)),
              title: Text('${users.length} reaction${users.length == 1 ? '' : 's'}'),
              subtitle: Text(users.length > 3
                  ? '${users.take(3).join(', ')} +${users.length - 3} more'
                  : users.join(', ')),
            );
          },
        ),
      ),
    );
  }

  Future<void> _openEditHistory(String messageId) async {
    final doc = await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.channelId)
        .collection('messages')
        .doc(messageId)
        .get();
    if (!doc.exists || !mounted) return;
    final d = doc.data()!;
    final history = (d['edit_history'] as List?) ?? [];
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Version history'),
        content: SizedBox(
          width: 320,
          child: ListView(
            shrinkWrap: true,
            children: [
              _historyTile('Current',
                  (d['text'] ?? d['content'] ?? '').toString(),
                  highlight: true),
              for (final h in history.reversed)
                _historyTile(
                    _fmtTs(h['edited_at']), (h['text'] ?? '').toString()),
            ],
          ),
        ),
      ),
    );
  }

  String _fmtTs(dynamic ts) {
    if (ts == null) return '';
    final d =
        ts is Timestamp ? ts.toDate() : DateTime.tryParse(ts.toString());
    if (d == null) return '';
    return DateFormat('MMM d, HH:mm').format(d);
  }

  Widget _historyTile(String time, String text, {bool highlight = false}) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: highlight
            ? theme.colorScheme.primary.withOpacity(0.08)
            : theme.colorScheme.onSurface.withOpacity(0.03),
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(
            color: highlight
                ? theme.colorScheme.primary
                : theme.colorScheme.primary.withOpacity(0.4),
            width: 3,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(time,
              style: TextStyle(
                  color: highlight
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface.withOpacity(0.4),
                  fontSize: 10,
                  fontWeight:
                      highlight ? FontWeight.w600 : FontWeight.normal)),
          const SizedBox(height: 4),
          Text(text, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  Future<void> _forwardMessage(Map<String, dynamic> msg) async {
    if (_currentUserId == null) return;
    final snap = await FirebaseFirestore.instance
        .collection('chats')
        .where('participants', arrayContains: _currentUserId)
        .get();
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF1F1F1F)
          : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        top: false,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: snap.docs.length,
          itemBuilder: (_, i) {
            final c = snap.docs[i];
            if (c.id == widget.channelId) return const SizedBox.shrink();
            final d = c.data();
            final name = d['name'] ?? d['title'] ?? 'Chat';
            return ListTile(
              leading: CircleAvatar(
                backgroundColor:
                    Theme.of(context).colorScheme.primary.withOpacity(0.15),
                backgroundImage: d['avatar_url'] != null
                    ? CachedNetworkImageProvider(d['avatar_url'])
                    : null,
                child: d['avatar_url'] == null
                    ? Text(name.toString()[0].toUpperCase())
                    : null,
              ),
              title: Text(name.toString()),
              onTap: () async {
                Navigator.pop(context);
                final ref = FirebaseFirestore.instance
                    .collection('chats')
                    .doc(c.id)
                    .collection('messages')
                    .doc();
                await ref.set({
                  'id': ref.id,
                  'text': msg['text'] ?? msg['content'],
                  'content': msg['text'] ?? msg['content'],
                  'media_url': msg['media_url'],
                  'media_type': msg['media_type'] ?? 'text',
                  'file_name': msg['file_name'],
                  'duration': msg['duration'],
                  'sticker': msg['sticker'],
                  'sender_id': _currentUserId,
                  'is_forwarded': true,
                  'created_at': FieldValue.serverTimestamp(),
                  'reactions': {},
                  'deleted_for_everyone': false,
                });
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Forwarded')),
                  );
                }
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _saveToSaved(Map<String, dynamic> msg) async {
    if (_currentUserId == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUserId)
          .collection('saved')
          .add({
        'text': msg['text'] ?? msg['content'],
        'media_url': msg['media_url'],
        'media_type': msg['media_type'],
        'sticker': msg['sticker'],
        'from_chat': widget.channelName,
        'from_chat_id': widget.channelId,
        'saved_at': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved')),
        );
      }
    } catch (_) {}
  }

  Future<void> _downloadMedia(String url, String name) async {
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode != 200) throw Exception('Download failed');
      Directory dir;
      if (Platform.isAndroid) {
        dir = Directory('/storage/emulated/0/Download/Luma');
      } else {
        dir = await getApplicationDocumentsDirectory();
      }
      if (!await dir.exists()) await dir.create(recursive: true);
      final f = File('${dir.path}/$name');
      await f.writeAsBytes(res.bodyBytes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Saved to ${f.path}')));
      }
    } catch (e) {
      _showError('Download failed: $e');
    }
  }

  Future<void> _reportMessage(Map<String, dynamic> msg) async {
    if (_currentUserId == null) return;
    try {
      await FirebaseFirestore.instance.collection('reports').add({
        'reporter_id': _currentUserId,
        'channel_id': widget.channelId,
        'message_id': msg['id'],
        'message_content': msg['text'] ?? msg['content'] ?? '',
        'reason': 'channel_post',
        'created_at': FieldValue.serverTimestamp(),
        'status': 'pending',
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Report submitted')),
        );
      }
    } catch (_) {}
  }

  void _showEditDialog(String messageId, String currentContent) {
    final theme = Theme.of(context);
    _editController.text = currentContent;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Post'),
        content: TextField(
          controller: _editController,
          maxLines: null,
          decoration:
              const InputDecoration(hintText: 'Edit your post...'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _editMessage(messageId, _editController.text);
            },
            child: Text('Save',
                style: TextStyle(color: theme.colorScheme.primary)),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteEveryone(String messageId) {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete for Everyone?'),
        content: const Text(
            'This will delete the post for all subscribers.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteForEveryone(messageId);
            },
            style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _enterMultiSelect(String id) {
    setState(() {
      _multiSelectMode = true;
      _selectedMessageIds.clear();
      _selectedMessageIds.add(id);
    });
  }

  void _exitMultiSelect() {
    setState(() {
      _multiSelectMode = false;
      _selectedMessageIds.clear();
    });
  }

  void _toggleMultiSelect(String id) {
    setState(() {
      if (_selectedMessageIds.contains(id)) {
        _selectedMessageIds.remove(id);
      } else {
        _selectedMessageIds.add(id);
      }
      if (_selectedMessageIds.isEmpty) _multiSelectMode = false;
    });
  }

  void _togglePanel(String mode) {
    final wasOpen = _panelMode == mode;
    setState(() {
      if (wasOpen) {
        _panelMode = null;
      } else {
        _panelMode = mode;
        _pickerTab = mode;
        if (mode == 'gif' && !_gifsLoaded) _loadGifs();
      }
    });
    if (wasOpen) {
      _messageFocusNode.requestFocus();
    } else {
      _messageFocusNode.unfocus();
    }
  }

  Widget _buildPickerPanel(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF17212B) : Colors.white,
        border:
            Border(top: BorderSide(color: theme.dividerColor, width: 0.5)),
      ),
      child: Column(
        children: [
          Expanded(
            child: IndexedStack(
              index: _pickerTab == 'emoji'
                  ? 0
                  : _pickerTab == 'sticker'
                      ? 1
                      : 2,
              children: [
                _buildEmojiPanel(theme),
                _buildStickerPanel(theme),
                _buildGifPanel(theme),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF17212B) : Colors.white,
              border:
                  Border(top: BorderSide(color: theme.dividerColor)),
            ),
            child: Row(
              children: [
                _bottomTab(theme, 'emoji', 'Emoji'),
                _bottomTab(theme, 'gif', 'GIFs'),
                _bottomTab(theme, 'sticker', 'Stickers'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomTab(ThemeData theme, String tab, String label) {
    final active = _pickerTab == tab;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _pickerTab = tab;
            _panelMode = tab;
          });
          if (tab == 'gif' && !_gifsLoaded) _loadGifs();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: active
                    ? const Color(0xFF3390EC)
                    : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: active
                  ? const Color(0xFF3390EC)
                  : theme.colorScheme.onSurface.withOpacity(0.5),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmojiPanel(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Container(
            height: 38,
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withOpacity(0.06)
                  : Colors.black.withOpacity(0.04),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const SizedBox(width: 12),
                Icon(Icons.search,
                    size: 18,
                    color: theme.colorScheme.onSurface.withOpacity(0.4)),
                const SizedBox(width: 8),
                Text('Search',
                    style: TextStyle(
                        color: theme.colorScheme.onSurface
                            .withOpacity(0.4),
                        fontSize: 14)),
              ],
            ),
          ),
        ),
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: _emojiCategories.entries.map((e) {
              final active = e.key == _currentEmojiCategory;
              return GestureDetector(
                onTap: () =>
                    setState(() => _currentEmojiCategory = e.key),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border(
                      bottom: BorderSide(
                        color: active
                            ? const Color(0xFF3390EC)
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Text(e.value['icon'] as String,
                      style: const TextStyle(fontSize: 20)),
                ),
              );
            }).toList(),
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(10),
            gridDelegate:
                const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 8,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
            ),
            itemCount:
                (_emojiCategories[_currentEmojiCategory]!['emojis'] as List)
                    .length,
            itemBuilder: (_, i) {
              final e = (_emojiCategories[_currentEmojiCategory]!['emojis']
                  as List)[i];
              return GestureDetector(
                onTap: () {
                  _messageController.text += e as String;
                  _messageController.selection = TextSelection.collapsed(
                      offset: _messageController.text.length);
                },
                child: Center(
                  child: Text(e as String,
                      style: const TextStyle(fontSize: 24)),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildStickerPanel(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Row(
            children: [
              Text(
                _currentStickerPackId == 'fav'
                    ? 'Favorites'
                    : (_stickerPacks.firstWhere(
                            (p) => p['id'] == _currentStickerPackId,
                            orElse: () => {'name': 'Pack'})['name'] ??
                        'Pack'),
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withOpacity(0.85),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _showStickerCreatorSheet,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3390EC).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.add,
                      size: 16, color: Color(0xFF3390EC)),
                ),
              ),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          height: 36,
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withOpacity(0.06)
                : Colors.black.withOpacity(0.04),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              const SizedBox(width: 12),
              Icon(Icons.search,
                  size: 16,
                  color: theme.colorScheme.onSurface.withOpacity(0.4)),
              const SizedBox(width: 8),
              Text('Search',
                  style: TextStyle(
                      color:
                          theme.colorScheme.onSurface.withOpacity(0.4),
                      fontSize: 13)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 32,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            children: [
              _stickerPackTab(theme, 'fav', '⭐'),
              for (final p in _stickerPacks)
                _stickerPackTab(theme, p['id'],
                    (p['emoji'] ?? '📁').toString()),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: _loadingStickers
              ? const Center(
                  child: CircularProgressIndicator(
                      color: Color(0xFF3390EC), strokeWidth: 2))
              : _stickersInCurrentPack().isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _currentStickerPackId == 'fav'
                              ? 'Long-press any sticker to add to favorites'
                              : 'This pack is empty',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: theme.colorScheme.onSurface
                                  .withOpacity(0.3),
                              fontSize: 12),
                        ),
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(10),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 4,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                      ),
                      itemCount: _stickersInCurrentPack().length,
                      itemBuilder: (_, i) {
                        final s = _stickersInCurrentPack()[i];
                        return GestureDetector(
                          onTap: () => _sendSticker(s),
                          onLongPress: () =>
                              _showStickerOptions(s, true),
                          child: s['sticker_type'] == 'video'
                              ? _StickerVideoPreview(
                                  url: s['url'] as String)
                              : CachedNetworkImage(
                                  imageUrl: s['url'] as String,
                                  fit: BoxFit.contain,
                                  memCacheWidth: 200,
                                ),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Widget _stickerPackTab(ThemeData theme, String id, String label) {
    final active = _currentStickerPackId == id;
    return GestureDetector(
      onTap: () => setState(() => _currentStickerPackId = id),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active
              ? const Color(0xFF3390EC).withOpacity(0.15)
              : theme.colorScheme.onSurface.withOpacity(0.05),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label, style: const TextStyle(fontSize: 16)),
      ),
    );
  }

  List<Map<String, dynamic>> _stickersInCurrentPack() {
    if (_currentStickerPackId == 'fav') return _favoriteStickers;
    return _myStickers
        .where((s) => s['pack_id'] == _currentStickerPackId)
        .toList();
  }

  Widget _buildGifPanel(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(10),
          child: Container(
            height: 38,
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withOpacity(0.06)
                  : Colors.black.withOpacity(0.04),
              borderRadius: BorderRadius.circular(10),
            ),
            child: TextField(
              controller: _gifSearchController,
              style: TextStyle(
                  color: theme.colorScheme.onSurface, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search GIFs',
                hintStyle: TextStyle(
                    color: theme.colorScheme.onSurface.withOpacity(0.4),
                    fontSize: 14),
                prefixIcon: Icon(Icons.search,
                    size: 18,
                    color: theme.colorScheme.onSurface.withOpacity(0.4)),
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
              onSubmitted: (q) => _loadGifs(q: q),
            ),
          ),
        ),
        Expanded(
          child: _loadingGifs
              ? const Center(
                  child: CircularProgressIndicator(
                      color: Color(0xFF3390EC), strokeWidth: 2))
              : _gifs.isEmpty
                  ? Center(
                      child: Text('No GIFs found',
                          style: TextStyle(
                              color: theme.colorScheme.onSurface
                                  .withOpacity(0.3),
                              fontSize: 12)),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 6,
                        crossAxisSpacing: 6,
                        childAspectRatio: 1,
                      ),
                      itemCount: _gifs.length,
                      itemBuilder: (_, i) {
                        final g = _gifs[i];
                        return GestureDetector(
                          onTap: () => _sendGif(g['full'] as String),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: CachedNetworkImage(
                              imageUrl: g['preview'] as String,
                              fit: BoxFit.cover,
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  void _showStickerOptions(Map<String, dynamic> s, bool isMine) {
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            SizedBox(
              height: 140,
              child: Center(
                child: s['sticker_type'] == 'video'
                    ? SizedBox(
                        width: 120,
                        height: 120,
                        child:
                            _StickerVideoPreview(url: s['url'] as String))
                    : CachedNetworkImage(
                        imageUrl: s['url'] as String,
                        height: 120,
                        fit: BoxFit.contain,
                      ),
              ),
            ),
            Divider(height: 1, color: theme.dividerColor),
            ListTile(
              leading: Icon(
                  s['favorite'] == true ? Icons.star : Icons.star_border,
                  color: const Color(0xFFD4A73A)),
              title: Text(s['favorite'] == true
                  ? 'Remove from Favorites'
                  : 'Add to Favorites'),
              onTap: () {
                Navigator.pop(context);
                _toggleFavoriteSticker(s);
              },
            ),
            if (isMine)
              ListTile(
                leading: Icon(Icons.delete_outline,
                    color: theme.colorScheme.error),
                title: Text('Delete sticker',
                    style:
                        TextStyle(color: theme.colorScheme.error)),
                onTap: () {
                  Navigator.pop(context);
                  _deleteSticker(s['id']);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showStickerCreatorSheet() {
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
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Create Sticker',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.image,
                    color: Color(0xFF3390EC)),
                title: const Text('From Photo'),
                onTap: () {
                  Navigator.pop(context);
                  _createStickerFromGallery();
                },
              ),
              ListTile(
                leading: const Icon(Icons.videocam,
                    color: Color(0xFF3390EC)),
                title: const Text('From Video'),
                onTap: () {
                  Navigator.pop(context);
                  _createStickerFromGallery(video: true);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAttachmentSheet() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor:
          isDark ? const Color(0xFF17212B) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  _attachTile(theme, Icons.photo_library_outlined,
                      'Gallery', () {
                    Navigator.pop(context);
                    _showGallerySheet();
                  }),
                  _attachTile(theme, Icons.folder_outlined, 'File', () {
                    Navigator.pop(context);
                    _pickFile();
                  }),
                  _attachTile(theme, Icons.location_on_outlined,
                      'Location', () {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Location sharing coming soon')),
                    );
                  }),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  _attachTile(theme, Icons.poll_outlined, 'Poll', () {
                    Navigator.pop(context);
                    _createPoll();
                  }),
                  _attachTile(theme, Icons.person_outline, 'Contact', () {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Contact sharing coming soon')),
                    );
                  }),
                  _attachTile(theme, Icons.music_note_outlined, 'Music',
                      () {
                    Navigator.pop(context);
                    _pickFile();
                  }),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _attachTile(ThemeData theme, IconData icon, String label,
      VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: const BoxDecoration(
                  color: Color(0xFF3390EC),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: Colors.white, size: 26),
              ),
              const SizedBox(height: 8),
              Text(label,
                  style: TextStyle(
                      color: theme.colorScheme.onSurface, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  void _showGallerySheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF17212B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.6,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () {
                        Navigator.pop(context);
                        _takePhoto();
                      },
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: const BoxDecoration(
                          color: Colors.white24,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.camera_alt,
                            color: Colors.white),
                      ),
                    ),
                    const Spacer(),
                    Text('Gallery',
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.9),
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    const SizedBox(width: 44),
                  ],
                ),
              ),
              Divider(height: 1, color: Colors.white24),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(2),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 2,
                    crossAxisSpacing: 2,
                  ),
                  itemCount: 12,
                  itemBuilder: (_, i) => GestureDetector(
                    onTap: () {
                      Navigator.pop(context);
                      _pickMultiImages();
                    },
                    child: Container(
                      color: Colors.white10,
                      child: const Icon(Icons.image,
                          color: Colors.white24, size: 40),
                    ),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
                color: const Color(0xFF242F3D),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _galleryBottomBtn(Icons.photo_library, 'Gallery',
                        active: true),
                    _galleryBottomBtn(Icons.folder, 'File'),
                    _galleryBottomBtn(Icons.location_on, 'Location'),
                    _galleryBottomBtn(Icons.poll, 'Poll'),
                    _galleryBottomBtn(Icons.person, 'Contact'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _galleryBottomBtn(IconData icon, String label,
      {bool active = false}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon,
            color: active ? const Color(0xFF6FB9F3) : Colors.white70,
            size: 22),
        const SizedBox(height: 4),
        Text(label,
            style: TextStyle(
                color: active ? const Color(0xFF6FB9F3) : Colors.white70,
                fontSize: 10)),
      ],
    );
  }

  Future<void> _createPoll() async {
    final questionCtrl = TextEditingController();
    final optionCtrls = <TextEditingController>[
      TextEditingController(),
      TextEditingController(),
    ];

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          return AlertDialog(
            title: const Text('Create Poll'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: questionCtrl,
                    decoration: const InputDecoration(
                        hintText: 'Ask a question...'),
                  ),
                  const SizedBox(height: 12),
                  for (int i = 0; i < optionCtrls.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TextField(
                        controller: optionCtrls[i],
                        decoration: InputDecoration(
                            hintText: 'Option ${i + 1}'),
                      ),
                    ),
                  TextButton.icon(
                    onPressed: () {
                      setSt(() =>
                          optionCtrls.add(TextEditingController()));
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Add option'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              TextButton(
                onPressed: () async {
                  final q = questionCtrl.text.trim();
                  final opts = optionCtrls
                      .map((c) => c.text.trim())
                      .where((s) => s.isNotEmpty)
                      .toList();
                  if (q.isEmpty || opts.length < 2) return;
                  final ref = FirebaseFirestore.instance
                      .collection('chats')
                      .doc(widget.channelId)
                      .collection('messages')
                      .doc();
                  await ref.set({
                    'id': ref.id,
                    'text': q,
                    'content': q,
                    'media_type': 'poll',
                    'post_type': 'poll',
                    'poll_options': opts,
                    'poll_votes': {},
                    'sender_id': _currentUserId,
                    'created_at': FieldValue.serverTimestamp(),
                    'deleted_for_everyone': false,
                    'reactions': {},
                    'views_count': 0,
                  });
                  if (!ctx.mounted) return;
                  Navigator.pop(ctx, true);
                },
                child: const Text('Create'),
              ),
            ],
          );
        },
      ),
    );

    if (result == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Poll created')),
      );
    }
  }

  void _openSearch() {
    showSearch(
      context: context,
      delegate: _ChannelSearchDelegate(
        channelId: widget.channelId,
        channelName: widget.channelName,
      ),
    );
  }

  void _openMonoforum() {
    Navigator.pushNamed(context, '/monoforum', arguments: {
      'chatId': widget.channelId,
      'chatName': widget.channelName,
    }).catchError((_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Monoforum coming soon')),
        );
      }
    });
  }

  void _openComments(String messageId) {
    Navigator.pushNamed(context, '/post_comments', arguments: {
      'chatId': widget.channelId,
      'messageId': messageId,
      'channelName': widget.channelName,
    }).catchError((_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Comments coming soon')),
        );
      }
    });
  }

  void _openStatistics() {
    Navigator.pushNamed(context, '/channel_statistics', arguments: {
      'chatId': widget.channelId,
      'chatName': widget.channelName,
    }).catchError((_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Statistics coming soon')),
        );
      }
    });
  }

  void _pickSilentToggle() {
    setState(() => _silentMode = !_silentMode);
  }

  Future<void> _pickScheduleTime() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(hours: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (time == null) return;
    setState(() {
      _scheduledAt =
          DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  void _toggleSignatures() async {
    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.channelId)
          .update({'signatures_enabled': !_signaturesEnabled});
    } catch (_) {}
  }

  void _showChannelMoreMenu() {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: theme.brightness == Brightness.dark
          ? const Color(0xFF1F1F1F)
          : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.info_outline,
                  color: theme.colorScheme.primary),
              title: const Text('Channel info'),
              onTap: () {
                Navigator.pop(context);
                _goToChannelInfo();
              },
            ),
            if (_subscriberCount >= 500)
              ListTile(
                leading: Icon(Icons.bar_chart,
                    color: theme.colorScheme.primary),
                title: const Text('Statistics'),
                onTap: () {
                  Navigator.pop(context);
                  _openStatistics();
                },
              ),
            ListTile(
              leading:
                  Icon(Icons.link, color: theme.colorScheme.primary),
              title: const Text('Copy link'),
              onTap: () {
                Navigator.pop(context);
                final link = _channelLink ??
                    'https://t.me/${_channelUsername ?? widget.channelId}';
                Clipboard.setData(ClipboardData(text: link));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Link copied')),
                );
              },
            ),
            if (_isAdmin)
              ListTile(
                leading: Icon(
                    _signaturesEnabled
                        ? Icons.visibility
                        : Icons.visibility_off,
                    color: theme.colorScheme.primary),
                title: Text(_signaturesEnabled
                    ? 'Hide signatures'
                    : 'Show signatures'),
                onTap: () {
                  Navigator.pop(context);
                  _toggleSignatures();
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    if (bottomInset > 0) _keyboardHeight = bottomInset;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: _buildChannelHeader(theme),
      body: Column(
        children: [
          if (_pinnedMessage != null) _buildPinnedBanner(theme),
          if (_multiSelectMode) _buildMultiSelectBar(theme),

          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _messagesStream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text('Error: ${snapshot.error}'));
                }
                if (!snapshot.hasData) {
                  return Center(
                      child: CircularProgressIndicator(
                          color: theme.colorScheme.primary));
                }
                final messages = snapshot.data!.docs;
                if (messages.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.campaign_outlined,
                            size: 72,
                            color: theme.colorScheme.onSurface
                                .withOpacity(0.15)),
                        const SizedBox(height: 16),
                        Text('No posts yet',
                            style: TextStyle(
                                color: theme.colorScheme.onSurface
                                    .withOpacity(0.5),
                                fontSize: 16)),
                      ],
                    ),
                  );
                }
                return _buildPostList(theme, messages);
              },
            ),
          ),

          if (_replyingTo != null) _buildReplyBar(theme),
          if (_selectedImage != null)
            _buildMediaPreview(theme, 'Image',
                () => setState(() => _selectedImage = null))
          else if (_selectedVideo != null)
            _buildMediaPreview(theme, 'Video',
                () => setState(() => _selectedVideo = null)),

          if (_isRecording) _buildRecordingBar(theme),

          if (_panelMode != null)
            SizedBox(
              height: _keyboardHeight > 0 ? _keyboardHeight : 300,
              child: _buildPickerPanel(theme),
            ),

          _isAdmin ? _buildComposer(theme) : _buildReadOnlyBar(theme),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildChannelHeader(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    final Color headerBg = _isPublicChannel
        ? const Color(0xFF527DA3)
        : (isDark ? const Color(0xFF17212B) : const Color(0xFF6E7C8C));

    return PreferredSize(
      preferredSize: const Size.fromHeight(60),
      child: Container(
        color: headerBg,
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: 60,
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: _headerCircleBtn(
                      Icons.arrow_back, () => Navigator.pop(context)),
                ),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _goToChannelInfo,
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white24,
                          ),
                          child: _channelAvatarUrl != null &&
                                  _channelAvatarUrl!.isNotEmpty
                              ? ClipOval(
                                  child: CachedNetworkImage(
                                    imageUrl: _channelAvatarUrl!,
                                    fit: BoxFit.cover,
                                  ),
                                )
                              : const Center(
                                  child: Icon(Icons.campaign,
                                      color: Colors.white, size: 22),
                                ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      widget.channelName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  if (_isPublicChannel) ...[
                                    const SizedBox(width: 4),
                                    const Icon(Icons.verified,
                                        color: Color(0xFF6FB9F3),
                                        size: 14),
                                  ],
                                ],
                              ),
                              Text(
                                _formatSubscribers(_subscriberCount),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                _headerCircleBtn(Icons.search, _openSearch),
                _headerCircleBtn(Icons.forum_outlined, _openMonoforum),
                _headerCircleBtn(Icons.more_vert, _showChannelMoreMenu),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _headerCircleBtn(IconData icon, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: Colors.black.withOpacity(0.18),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, color: Colors.white, size: 20),
          ),
        ),
      ),
    );
  }

  Widget _buildPinnedBanner(ThemeData theme) {
    final text = _pinnedMessage!['text'] ??
        _pinnedMessage!['content'] ??
        'Pinned message';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: theme.colorScheme.primary.withOpacity(0.08),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 32,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Pinned Message',
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 13,
                    color:
                        theme.colorScheme.onSurface.withOpacity(0.85),
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => _unpinMessage(_pinnedMessage!['id']),
            child: Icon(Icons.close,
                color: theme.colorScheme.onSurface.withOpacity(0.4),
                size: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildMultiSelectBar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      color: theme.brightness == Brightness.dark
          ? const Color(0xFF1F1F1F)
          : Colors.white,
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.close,
                color: theme.colorScheme.onSurface.withOpacity(0.5)),
            onPressed: _exitMultiSelect,
          ),
          Text(
            '${_selectedMessageIds.length}',
            style: TextStyle(
                color: theme.colorScheme.primary,
                fontSize: 16,
                fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(Icons.copy, color: theme.colorScheme.primary),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied')),
              );
              _exitMultiSelect();
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete, color: Colors.red),
            onPressed: () async {
              for (final id in _selectedMessageIds) {
                await _deleteForEveryone(id);
              }
              _exitMultiSelect();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPostList(
      ThemeData theme, List<QueryDocumentSnapshot> messages) {
    return ListView.builder(
      reverse: true,
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final msg = messages[index].data() as Map<String, dynamic>;
        msg['id'] = messages[index].id;
        if (msg['sender_id'] != null &&
            !_userCache.containsKey(msg['sender_id'])) {
          _fetchUser(msg['sender_id']).then((_) {
            if (mounted) setState(() {});
          });
        }
        _incrementViewCount(messages[index].id);

        final next = index < messages.length - 1
            ? messages[index + 1].data() as Map<String, dynamic>
            : null;
        final thisDate = _parseTs(msg['created_at']);
        final nextDate = next != null ? _parseTs(next['created_at']) : null;
        final showDate = thisDate != null &&
            (nextDate == null ||
                thisDate.year != nextDate.year ||
                thisDate.month != nextDate.month ||
                thisDate.day != nextDate.day);

        final isMe = msg['sender_id'] == _currentUserId;
        final selected = _selectedMessageIds.contains(msg['id']);

        return Column(
          children: [
            if (showDate && thisDate != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: theme.brightness == Brightness.dark
                          ? const Color(0xFF2F2F2F)
                          : Colors.black.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _formatDateHeader(thisDate),
                      style: TextStyle(
                        color: theme.colorScheme.onSurface
                            .withOpacity(0.7),
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ),
            _ChannelPostBubble(
              message: msg,
              isMe: isMe,
              isAdmin: _isAdmin,
              signaturesEnabled: _signaturesEnabled,
              linkedGroupId: _linkedGroupId,
              selected: selected,
              multiSelect: _multiSelectMode,
              userCache: _userCache,
              onTap: () {
                if (_multiSelectMode) {
                  _toggleMultiSelect(msg['id']);
                }
              },
              onLongPress: () {
                if (!_multiSelectMode) _showMessageOptions(msg, isMe);
              },
              onReaction: (e) => _toggleReaction(msg['id'], e),
              onShowReactions: () => _showReactionsDetail(msg),
              onComment: () => _openComments(msg['id']),
              onShare: () => _forwardMessage(msg),
              onViewImage: _showImageViewer,
              onOpenFile: _openFile,
              onPlayAudio: _playAudio,
              playingAudioId: _currentlyPlayingAudioId,
              isPlayingAudio: _isPlayingAudio,
              audioPosition: _audioPosition,
              audioDuration: _audioDuration,
              formatTime: _formatTime,
              formatDuration: _formatDuration,
              formatViewCount: _formatViewCount,
              videoControllers: _videoControllers,
              onVideoInit: () => setState(() {}),
            ),
          ],
        );
      },
    );
  }

  Widget _buildReplyBar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: theme.brightness == Brightness.dark
          ? const Color(0xFF1F1F1F)
          : Colors.white,
      child: Row(
        children: [
          Container(
            width: 3,
            height: 36,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _replyingToSender ?? 'Unknown',
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  _replyingToContent ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color:
                        theme.colorScheme.onSurface.withOpacity(0.6),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close,
                size: 18,
                color:
                    theme.colorScheme.onSurface.withOpacity(0.5)),
            onPressed: () => setState(() {
              _replyingTo = null;
              _replyingToContent = null;
              _replyingToSender = null;
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildMediaPreview(
      ThemeData theme, String label, VoidCallback onRemove) {
    return Container(
      height: 100,
      padding: const EdgeInsets.all(8),
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurface.withOpacity(0.05),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                    color:
                        theme.colorScheme.onSurface.withOpacity(0.5)),
              ),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.error,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close,
                    size: 16, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingBar(ThemeData theme) {
    const slideThreshold = -80.0;
    final slidingToCancel = _recordingSlideOffset < slideThreshold;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.error.withOpacity(0.08),
        border: Border(
          top: BorderSide(
              color: theme.colorScheme.error.withOpacity(0.2)),
        ),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => _stopRecording(send: false),
            child: Icon(
              slidingToCancel ? Icons.delete : Icons.close,
              color: slidingToCancel
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurface.withOpacity(0.5),
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
                color: theme.colorScheme.error, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Text(
            _formatDuration(_recordingSeconds),
            style: TextStyle(
                color: theme.colorScheme.error,
                fontWeight: FontWeight.w600,
                fontSize: 14),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: slidingToCancel
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.chevron_left,
                          color: theme.colorScheme.error, size: 18),
                      Text('Release to cancel',
                          style: TextStyle(
                              color: theme.colorScheme.error,
                              fontSize: 13,
                              fontWeight: FontWeight.w500)),
                    ],
                  )
                : Row(
                    children: _recordingWave
                        .map((h) => Container(
                              margin: const EdgeInsets.symmetric(
                                  horizontal: 1),
                              width: 3,
                              height: 4 + h * 18,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.error
                                    .withOpacity(0.6),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ))
                        .toList(),
                  ),
          ),
          if (_isRecordingLocked)
            IconButton(
              icon: Icon(Icons.send, color: theme.colorScheme.primary),
              onPressed: () => _stopRecording(send: true),
            )
          else
            IconButton(
              icon: Icon(Icons.lock_outline,
                  color: theme.colorScheme.onSurface.withOpacity(0.5)),
              onPressed: _lockRecording,
            ),
        ],
      ),
    );
  }

  Widget _buildComposer(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    final hasText = _messageController.text.trim().isNotEmpty;

    return Container(
      color: isDark ? const Color(0xFF17212B) : Colors.white,
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_silentMode || _scheduledAt != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    if (_silentMode)
                      _chip(theme, Icons.notifications_off, 'Silent',
                          () => setState(() => _silentMode = false)),
                    if (_scheduledAt != null)
                      _chip(
                          theme,
                          Icons.schedule,
                          DateFormat('MMM d, HH:mm')
                              .format(_scheduledAt!),
                          () => setState(() => _scheduledAt = null)),
                  ],
                ),
              ),

            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                GestureDetector(
                  onTap: _showAttachmentSheet,
                  child: Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    child: Icon(Icons.attach_file,
                        size: 22,
                        color: theme.colorScheme.onSurface
                            .withOpacity(0.6)),
                  ),
                ),
                GestureDetector(
                  onTap: _pickSilentToggle,
                  child: Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    child: Icon(
                      _silentMode
                          ? Icons.notifications_off
                          : Icons.notifications_active_outlined,
                      size: 22,
                      color: _silentMode
                          ? const Color(0xFF3390EC)
                          : theme.colorScheme.onSurface
                              .withOpacity(0.6),
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: _pickScheduleTime,
                  child: Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.schedule,
                      size: 22,
                      color: _scheduledAt != null
                          ? const Color(0xFF3390EC)
                          : theme.colorScheme.onSurface
                              .withOpacity(0.6),
                    ),
                  ),
                ),

                GestureDetector(
                  onTap: () => _togglePanel('gif'),
                  child: Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: const Color(0xFF3390EC),
                        width: 1.5,
                      ),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'GIF',
                      style: TextStyle(
                        color: Color(0xFF3390EC),
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),

                Expanded(
                  child: Container(
                    constraints:
                        const BoxConstraints(maxHeight: 140),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF242F3D)
                          : Colors.black.withOpacity(0.04),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: TextField(
                      controller: _messageController,
                      focusNode: _messageFocusNode,
                      minLines: 1,
                      maxLines: null,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      style: TextStyle(
                        color: theme.colorScheme.onSurface,
                        fontSize: 15,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Broadcast...',
                        hintStyle: TextStyle(
                          color: theme.colorScheme.onSurface
                              .withOpacity(0.4),
                          fontSize: 15,
                        ),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                      ),
                      onTap: () {
                        if (_panelMode != null) {
                          setState(() => _panelMode = null);
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 4),

                GestureDetector(
                  onTap: () => _togglePanel('emoji'),
                  child: Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    child: Icon(
                      _panelMode == 'emoji'
                          ? Icons.keyboard
                          : Icons.emoji_emotions_outlined,
                      size: 22,
                      color: _panelMode == 'emoji'
                          ? const Color(0xFF3390EC)
                          : theme.colorScheme.onSurface
                              .withOpacity(0.6),
                    ),
                  ),
                ),

                GestureDetector(
                  onLongPressStart: hasText
                      ? null
                      : (d) {
                          _recordingDragStartX = d.globalPosition.dx;
                          _startRecording();
                        },
                  onLongPressMoveUpdate: hasText
                      ? null
                      : (d) {
                          final start = _recordingDragStartX;
                          if (start == null) return;
                          setState(() {
                            _recordingSlideOffset =
                                d.globalPosition.dx - start;
                          });
                        },
                  onLongPressEnd: hasText
                      ? null
                      : (_) {
                          final cancelled = _recordingSlideOffset < -80;
                          _recordingDragStartX = null;
                          _stopRecording(send: !cancelled);
                        },
                  onTap: _isLoading
                      ? null
                      : () {
                          if (hasText) {
                            _sendMessage();
                          }
                        },
                  child: Container(
                    width: 46,
                    height: 46,
                    decoration: const BoxDecoration(
                      color: Color(0xFF3390EC),
                      shape: BoxShape.circle,
                    ),
                    child: _isLoading
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(
                            hasText ? Icons.send : Icons.mic,
                            color: Colors.white,
                            size: 22,
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(ThemeData theme, IconData icon, String label,
      VoidCallback onRemove) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: theme.colorScheme.primary),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  color: theme.colorScheme.primary, fontSize: 11)),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onRemove,
            child: Icon(Icons.close,
                size: 12, color: theme.colorScheme.primary),
          ),
        ],
      ),
    );
  }

  Widget _buildReadOnlyBar(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 16),
      color: theme.colorScheme.onSurface.withOpacity(0.03),
      child: Center(
        child: Text(
          'Only admins can post in this channel',
          style: TextStyle(
            color: theme.colorScheme.onSurface.withOpacity(0.4),
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  void _showImageViewer(String imageUrl) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          fit: StackFit.expand,
          children: [
            PhotoView(
              imageProvider: CachedNetworkImageProvider(imageUrl),
              minScale: PhotoViewComputedScale.contained,
              maxScale: PhotoViewComputedScale.covered * 2,
            ),
            Positioned(
              top: MediaQuery.of(context).padding.top + 16,
              right: 16,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// POST BUBBLE
// ═══════════════════════════════════════════════════════════════════════════
class _ChannelPostBubble extends StatefulWidget {
  final Map<String, dynamic> message;
  final bool isMe;
  final bool isAdmin;
  final bool signaturesEnabled;
  final String? linkedGroupId;
  final bool selected;
  final bool multiSelect;
  final Map<String, Map<String, dynamic>> userCache;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final ValueChanged<String> onReaction;
  final VoidCallback onShowReactions;
  final VoidCallback onComment;
  final VoidCallback onShare;
  final void Function(String url) onViewImage;
  final void Function(String url, String? fileName) onOpenFile;
  final void Function(String id, String url) onPlayAudio;
  final String? playingAudioId;
  final bool isPlayingAudio;
  final Duration audioPosition;
  final Duration audioDuration;
  final String Function(dynamic) formatTime;
  final String Function(int) formatDuration;
  final String Function(int) formatViewCount;
  final Map<String, VideoPlayerController> videoControllers;
  final VoidCallback onVideoInit;

  const _ChannelPostBubble({
    required this.message,
    required this.isMe,
    required this.isAdmin,
    required this.signaturesEnabled,
    required this.linkedGroupId,
    required this.selected,
    required this.multiSelect,
    required this.userCache,
    required this.onTap,
    required this.onLongPress,
    required this.onReaction,
    required this.onShowReactions,
    required this.onComment,
    required this.onShare,
    required this.onViewImage,
    required this.onOpenFile,
    required this.onPlayAudio,
    required this.playingAudioId,
    required this.isPlayingAudio,
    required this.audioPosition,
    required this.audioDuration,
    required this.formatTime,
    required this.formatDuration,
    required this.formatViewCount,
    required this.videoControllers,
    required this.onVideoInit,
  });

  @override
  State<_ChannelPostBubble> createState() => _ChannelPostBubbleState();
}

class _ChannelPostBubbleState extends State<_ChannelPostBubble> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final m = widget.message;
    final isDeleted = m['deleted_for_everyone'] == true;
    final mediaType = m['media_type'] as String?;
    final mediaUrl = m['media_url'] ?? m['image_url'];
    final reactions = Map<String, dynamic>.from(m['reactions'] ?? {});
    final viewsCount = (m['views_count'] as int?) ?? 0;
    final commentCount = (m['comments_count'] as int?) ?? 0;
    final postType = m['post_type'] as String? ?? 'message';
    final text = (m['text'] ?? m['content'] ?? '').toString();

    final bubbleColor = isDark ? const Color(0xFF182533) : Colors.white;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: GestureDetector(
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.88,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: bubbleColor,
                    borderRadius: BorderRadius.circular(12),
                    border: widget.selected
                        ? Border.all(
                            color: theme.colorScheme.primary, width: 2)
                        : null,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black
                            .withOpacity(isDark ? 0.2 : 0.05),
                        blurRadius: 2,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (m['is_silent'] == true)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.notifications_off,
                                  size: 11,
                                  color: theme.colorScheme.primary),
                              const SizedBox(width: 4),
                              Text('Silent',
                                  style: TextStyle(
                                      color: theme.colorScheme.primary,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      if (m['is_scheduled'] == true)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.schedule,
                                  size: 11,
                                  color: theme.colorScheme.primary),
                              const SizedBox(width: 4),
                              Text('Scheduled',
                                  style: TextStyle(
                                      color: theme.colorScheme.primary,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),

                      if (m['reply_to'] != null)
                        Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary
                                .withOpacity(0.08),
                            borderRadius: BorderRadius.circular(8),
                            border: Border(
                              left: BorderSide(
                                color: theme.colorScheme.primary,
                                width: 3,
                              ),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Text(
                                m['reply_to_sender'] ?? 'Unknown',
                                style: TextStyle(
                                  color: theme.colorScheme.primary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                m['reply_to_content'] ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.onSurface
                                      .withOpacity(0.6),
                                ),
                              ),
                            ],
                          ),
                        ),

                      if (isDeleted)
                        Text(
                          'This message was deleted',
                          style: TextStyle(
                            color: theme.colorScheme.onSurface
                                .withOpacity(0.4),
                            fontStyle: FontStyle.italic,
                          ),
                        )
                      else if (postType == 'poll')
                        _buildPoll(theme)
                      else if (mediaType == 'sticker' &&
                          m['sticker'] != null)
                        _buildSticker(m['sticker'])
                      else if (mediaType == 'gif' && mediaUrl != null)
                        _buildGif(mediaUrl)
                      else if (mediaType == 'image' && mediaUrl != null)
                        _buildImage(mediaUrl)
                      else if (mediaType == 'video' && mediaUrl != null)
                        _buildVideo(mediaUrl)
                      else if (mediaType == 'audio' && mediaUrl != null)
                        _buildVoice(theme, mediaUrl)
                      else if (mediaType == 'file')
                        _buildFile(theme)
                      else if (text.isNotEmpty)
                        RichText(
                          text: TextSpan(
                            children: _Linkify.parse(text),
                            style: TextStyle(
                              color: theme.colorScheme.onSurface,
                              fontSize: 15,
                              height: 1.4,
                            ),
                          ),
                        ),

                      if (reactions.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: GestureDetector(
                            onTap: widget.onShowReactions,
                            child: Wrap(
                              spacing: 4,
                              children: reactions.entries.map((entry) {
                                final emoji = entry.key;
                                final count =
                                    (entry.value as List).length;
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primary
                                        .withOpacity(0.1),
                                    borderRadius:
                                        BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    '$emoji ${count > 1 ? count : ''}',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                Padding(
                  padding:
                      const EdgeInsets.only(top: 4, left: 4, right: 4),
                  child: Row(
                    children: [
                      Icon(Icons.remove_red_eye_outlined,
                          size: 14,
                          color: theme.colorScheme.onSurface
                              .withOpacity(0.5)),
                      const SizedBox(width: 3),
                      Text(
                        widget.formatViewCount(viewsCount),
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface
                              .withOpacity(0.5),
                        ),
                      ),
                      if (widget.linkedGroupId != null) ...[
                        const SizedBox(width: 14),
                        GestureDetector(
                          onTap: widget.onComment,
                          child: Row(
                            children: [
                              Icon(Icons.mode_comment_outlined,
                                  size: 14,
                                  color: theme.colorScheme.onSurface
                                      .withOpacity(0.5)),
                              const SizedBox(width: 3),
                              Text(
                                commentCount > 0
                                    ? '$commentCount'
                                    : 'Discuss',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.onSurface
                                      .withOpacity(0.5),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const Spacer(),
                      GestureDetector(
                        onTap: widget.onShare,
                        child: Icon(Icons.share_outlined,
                            size: 14,
                            color: theme.colorScheme.onSurface
                                .withOpacity(0.5)),
                      ),
                    ],
                  ),
                ),

                Padding(
                  padding:
                      const EdgeInsets.only(top: 2, left: 4, right: 4),
                  child: Row(
                    children: [
                      Text(
                        widget.formatTime(m['created_at']),
                        style: TextStyle(
                          fontSize: 11,
                          color:
                              theme.colorScheme.onSurface.withOpacity(0.5),
                        ),
                      ),
                      const Spacer(),
                      if (widget.signaturesEnabled &&
                          m['sender_name'] != null) ...[
                        Text(
                          m['sender_name'] as String,
                          style: TextStyle(
                            color: theme.colorScheme.primary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 6),
                        if (m['sender_avatar'] != null)
                          CircleAvatar(
                            radius: 10,
                            backgroundImage: NetworkImage(
                                m['sender_avatar'] as String),
                            onBackgroundImageError: (_, __) {},
                          )
                        else
                          CircleAvatar(
                            radius: 10,
                            backgroundColor: theme.colorScheme.primary
                                .withOpacity(0.2),
                            child: Text(
                              (m['sender_name'] as String)[0]
                                  .toUpperCase(),
                              style: TextStyle(
                                color: theme.colorScheme.primary,
                                fontSize: 10,
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSticker(Map<String, dynamic> sticker) {
    final type = sticker['sticker_type'] ?? 'static';
    if (type == 'video') {
      return SizedBox(
        width: 140,
        height: 140,
        child: _StickerVideoPreview(url: sticker['url'] as String),
      );
    }
    return CachedNetworkImage(
      imageUrl: sticker['url'] as String,
      width: 140,
      height: 140,
      fit: BoxFit.contain,
    );
  }

  Widget _buildGif(String url) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(maxWidth: 260, maxHeight: 320),
        child: CachedNetworkImage(imageUrl: url, fit: BoxFit.cover),
      ),
    );
  }

  Widget _buildImage(String url) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: GestureDetector(
        onTap: () => widget.onViewImage(url),
        child: CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          placeholder: (_, __) => Container(
            height: 200,
            color: Colors.black.withOpacity(0.05),
            child: const Center(
              child: CircularProgressIndicator(
                  color: Color(0xFF3390EC), strokeWidth: 2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVideo(String url) {
    final controller = widget.videoControllers.putIfAbsent(url, () {
      final c = VideoPlayerController.networkUrl(Uri.parse(url));
      c.initialize().then((_) => widget.onVideoInit());
      return c;
    });
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 260,
        height: 180,
        color: Colors.black,
        child: controller.value.isInitialized
            ? Stack(
                fit: StackFit.expand,
                children: [
                  VideoPlayer(controller),
                  Center(
                    child: IconButton(
                      icon: Icon(
                        controller.value.isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_fill,
                        color: Colors.white,
                        size: 56,
                      ),
                      onPressed: () {
                        if (controller.value.isPlaying) {
                          controller.pause();
                        } else {
                          controller.play();
                        }
                        setState(() {});
                      },
                    ),
                  ),
                ],
              )
            : const Center(
                child: CircularProgressIndicator(
                    color: Color(0xFF3390EC), strokeWidth: 2),
              ),
      ),
    );
  }

  Widget _buildVoice(ThemeData theme, String url) {
    final isCurrent = widget.playingAudioId == mId;
    final total = isCurrent && widget.audioDuration != Duration.zero
        ? widget.audioDuration
        : Duration(seconds: (widget.message['duration'] as int?) ?? 0);
    final progress = total.inMilliseconds > 0
        ? widget.audioPosition.inMilliseconds / total.inMilliseconds
        : 0.0;
    return Container(
      width: 240,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => widget.onPlayAudio(mId, url),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                isCurrent && widget.isPlayingAudio
                    ? Icons.pause
                    : Icons.play_arrow,
                color: theme.colorScheme.primary,
                size: 22,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress.clamp(0.0, 1.0),
                    minHeight: 3,
                    backgroundColor:
                        theme.colorScheme.onSurface.withOpacity(0.1),
                    valueColor: AlwaysStoppedAnimation(
                        theme.colorScheme.primary),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isCurrent
                      ? '${widget.formatDuration(widget.audioPosition.inSeconds)} / ${widget.formatDuration(total.inSeconds)}'
                      : widget.formatDuration(total.inSeconds),
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String get mId => (widget.message['id'] ?? '').toString();

  Widget _buildFile(ThemeData theme) {
    final fileName = widget.message['file_name'] as String? ??
        widget.message['text'] ??
        'File';
    final fileSize = widget.message['file_size'] as String?;
    final url = widget.message['media_url'] as String?;
    return GestureDetector(
      onTap: url != null
          ? () => widget.onOpenFile(url, fileName)
          : null,
      child: Container(
        width: 240,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.insert_drive_file,
                color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fileName,
                    style: TextStyle(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (fileSize != null)
                    Text(
                      fileSize,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurface
                            .withOpacity(0.5),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPoll(ThemeData theme) {
    final options = List<dynamic>.from(widget.message['poll_options'] ?? []);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.message['text'] ?? widget.message['content'] ?? 'Poll',
          style: TextStyle(
            color: theme.colorScheme.onSurface,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        for (final o in options)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurface.withOpacity(0.05),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(o.toString(),
                  style: TextStyle(
                      color: theme.colorScheme.onSurface,
                      fontSize: 13)),
            ),
          ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// MESSAGE OPTIONS OVERLAY
// ═══════════════════════════════════════════════════════════════════════════
class _ChannelMsgOptionsOverlay extends StatelessWidget {
  final Map<String, dynamic> message;
  final bool isMe;
  final bool isDeleted;
  final bool isPinned;
  final bool isAdmin;
  final void Function(String emoji) onReact;
  final VoidCallback onShowReactions;
  final VoidCallback onEdit;
  final VoidCallback onEditHistory;
  final VoidCallback onCopy;
  final VoidCallback onReply;
  final VoidCallback onForward;
  final VoidCallback onPinToggle;
  final VoidCallback onSave;
  final VoidCallback onDownload;
  final VoidCallback onSelect;
  final VoidCallback onDeleteEveryone;
  final VoidCallback onDeleteMe;
  final VoidCallback onReport;

  const _ChannelMsgOptionsOverlay({
    required this.message,
    required this.isMe,
    required this.isDeleted,
    required this.isPinned,
    required this.isAdmin,
    required this.onReact,
    required this.onShowReactions,
    required this.onEdit,
    required this.onEditHistory,
    required this.onCopy,
    required this.onReply,
    required this.onForward,
    required this.onPinToggle,
    required this.onSave,
    required this.onDownload,
    required this.onSelect,
    required this.onDeleteEveryone,
    required this.onDeleteMe,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    const bg = Color(0xFF17212B);
    final isEdited = message['is_edited'] == true;
    final hasMedia = message['media_url'] != null;

    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(color: Colors.black.withOpacity(0.4)),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            top: size.height * 0.22,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!isDeleted)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 8),
                      decoration: BoxDecoration(
                        color: bg,
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: Row(
                        mainAxisAlignment:
                            MainAxisAlignment.spaceEvenly,
                        children: [
                          for (final e in [
                            '👍',
                            '❤️',
                            '🔥',
                            '😂',
                            '😮',
                            '🎉'
                          ])
                            GestureDetector(
                              onTap: () => onReact(e),
                              child: Text(e,
                                  style:
                                      const TextStyle(fontSize: 26)),
                            ),
                          GestureDetector(
                            onTap: onShowReactions,
                            child: Container(
                              width: 34,
                              height: 34,
                              decoration: const BoxDecoration(
                                color: Colors.white24,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                  Icons.keyboard_arrow_down,
                                  color: Colors.white70,
                                  size: 20),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: bg,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isEdited)
                          _tile(Icons.access_time,
                              'edited at ${_fmtEditTime()}', onEditHistory),
                        if (isAdmin)
                          _tile(Icons.edit_outlined, 'Edit', onEdit),
                        _tile(Icons.reply, 'Reply', onReply),
                        if (!isDeleted)
                          _tile(Icons.content_copy, 'Copy', onCopy),
                        if (!isDeleted)
                          _tile(Icons.forward, 'Forward', onForward),
                        _tile(
                          isPinned
                              ? Icons.push_pin
                              : Icons.push_pin_outlined,
                          isPinned ? 'Unpin' : 'Pin',
                          onPinToggle,
                        ),
                        _tile(Icons.bookmark_outline, 'Save', onSave),
                        if (hasMedia)
                          _tile(Icons.download_outlined,
                              'Save to Downloads', onDownload),
                        _tile(Icons.check_circle_outline, 'Select',
                            onSelect),
                        if (!isMe)
                          _tile(Icons.report_outlined, 'Report',
                              onReport,
                              color: Colors.orangeAccent),
                        if (isAdmin)
                          _tile(Icons.delete_forever_outlined,
                              'Delete for Everyone',
                              onDeleteEveryone,
                              color: Colors.redAccent),
                        _tile(Icons.delete_outline, 'Delete for me',
                            onDeleteMe,
                            color: Colors.redAccent),
                      ],
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

  String _fmtEditTime() {
    final t = message['updated_at'];
    if (t is Timestamp) {
      final d = t.toDate();
      return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }
    return '';
  }

  Widget _tile(IconData icon, String label, VoidCallback onTap,
      {Color color = Colors.white}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: color.withOpacity(0.75), size: 22),
            const SizedBox(width: 20),
            Text(label,
                style: TextStyle(color: color, fontSize: 15)),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// STICKER VIDEO PREVIEW
// ═══════════════════════════════════════════════════════════════════════════
class _StickerVideoPreview extends StatefulWidget {
  final String url;
  const _StickerVideoPreview({required this.url});

  @override
  State<_StickerVideoPreview> createState() => _StickerVideoPreviewState();
}

class _StickerVideoPreviewState extends State<_StickerVideoPreview> {
  late VideoPlayerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..setLooping(true)
      ..setVolume(0)
      ..initialize().then((_) {
        if (mounted) {
          setState(() {});
          _controller.play();
        }
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _controller.value.isInitialized
        ? AspectRatio(
            aspectRatio: _controller.value.aspectRatio,
            child: VideoPlayer(_controller),
          )
        : const Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Color(0xFF3390EC)),
            ),
          );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// LINKIFY
// ═══════════════════════════════════════════════════════════════════════════
class _Linkify {
  static final _boldR = RegExp(r'\*\*([^*]+)\*\*');
  static final _strikeR = RegExp(r'~~([^~]+)~~');
  static final _underlineR = RegExp(r'__([^_]+)__');
  static final _codeR = RegExp(r'`([^`]+)`');
  static final _urlR = RegExp(r'(https?://[^\s<]+)');
  static final _mentionR = RegExp(r'(^|\s)@([a-zA-Z0-9_]{2,30})');

  static List<InlineSpan> parse(String text) {
    final spans = <InlineSpan>[];
    final buf = StringBuffer();

    void flush() {
      if (buf.isEmpty) return;
      spans.add(TextSpan(text: buf.toString()));
      buf.clear();
    }

    final patterns = <_MdPat>[
      _MdPat(_codeR, (m) => _code(m.group(1)!)),
      _MdPat(_underlineR, (m) => _underline(m.group(1)!)),
      _MdPat(_boldR, (m) => _bold(m.group(1)!)),
      _MdPat(_strikeR, (m) => _strike(m.group(1)!)),
      _MdPat(_urlR, (m) => _link(m.group(0)!)),
      _MdPat(_mentionR, (m) => _mention(m.group(2)!)),
    ];

    var i = 0;
    while (i < text.length) {
      _MdPat? matched;
      RegExpMatch? mm;
      for (final p in patterns) {
        final sub = text.substring(i);
        final m = p.re.firstMatch(sub);
        if (m != null && m.start == 0) {
          matched = p;
          mm = m;
          break;
        }
      }
      if (matched != null && mm != null) {
        flush();
        spans.add(matched.build(mm));
        i += mm.end;
      } else {
        buf.write(text[i]);
        i++;
      }
    }
    flush();
    return spans;
  }

  static InlineSpan _code(String s) => WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: const Color(0xFF3390EC).withOpacity(0.15),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(s,
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 13)),
        ),
      );

  static InlineSpan _underline(String s) => TextSpan(
        text: s,
        style: const TextStyle(decoration: TextDecoration.underline),
      );

  static InlineSpan _bold(String s) => TextSpan(
        text: s,
        style: const TextStyle(fontWeight: FontWeight.w700),
      );

  static InlineSpan _strike(String s) => TextSpan(
        text: s,
        style: const TextStyle(decoration: TextDecoration.lineThrough),
      );

  static InlineSpan _link(String url) => TextSpan(
        text: url,
        style: const TextStyle(
          color: Color(0xFF3390EC),
          decoration: TextDecoration.underline,
        ),
        recognizer: TapGestureRecognizer()
          ..onTap = () => launchUrl(Uri.parse(url),
              mode: LaunchMode.externalApplication),
      );

  static InlineSpan _mention(String username) => TextSpan(
        text: '@$username',
        style: const TextStyle(
          color: Color(0xFF3390EC),
          fontWeight: FontWeight.w600,
        ),
      );
}

class _MdPat {
  final RegExp re;
  final InlineSpan Function(RegExpMatch) build;
  _MdPat(this.re, this.build);
}

// ═══════════════════════════════════════════════════════════════════════════
// SEARCH DELEGATE
// ═══════════════════════════════════════════════════════════════════════════
class _ChannelSearchDelegate extends SearchDelegate<String?> {
  final String channelId;
  final String channelName;
  _ChannelSearchDelegate({
    required this.channelId,
    required this.channelName,
  });

  @override
  List<Widget> buildActions(BuildContext context) => [
        IconButton(
          icon: const Icon(Icons.clear),
          onPressed: () => query = '',
        ),
      ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => close(context, null),
      );

  @override
  Widget buildResults(BuildContext context) => _build(context);

  @override
  Widget buildSuggestions(BuildContext context) => _build(context);

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    if (query.trim().isEmpty) {
      return Center(
        child: Text('Search in $channelName',
            style: TextStyle(
                color: theme.colorScheme.onSurface.withOpacity(0.4))),
      );
    }
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('chats')
          .doc(channelId)
          .collection('messages')
          .orderBy('created_at', descending: true)
          .limit(200)
          .snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final q = query.toLowerCase();
        final results = snap.data!.docs.where((d) {
          final data = d.data() as Map<String, dynamic>;
          final text = (data['text'] ?? data['content'] ?? '')
              .toString()
              .toLowerCase();
          return text.contains(q);
        }).toList();
        if (results.isEmpty) {
          return Center(
            child: Text('No results',
                style: TextStyle(
                    color:
                        theme.colorScheme.onSurface.withOpacity(0.4))),
          );
        }
        return ListView.builder(
          itemCount: results.length,
          itemBuilder: (_, i) {
            final d = results[i].data() as Map<String, dynamic>;
            final t = (d['text'] ?? d['content'] ?? '').toString();
            return ListTile(
              title: Text(t.length > 80 ? '${t.substring(0, 80)}…' : t),
              subtitle: Text(
                d['created_at'] != null
                    ? DateFormat('MMM d, HH:mm').format(
                        (d['created_at'] as Timestamp).toDate())
                    : '',
              ),
            );
          },
        );
      },
    );
  }
}
