import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_view/photo_view.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../providers/settings_provider.dart';
import '../../services/call_service.dart';
import '../../services/cloudinary_service.dart';
import '../../services/invitation_service.dart';
import '../calls/call_screen.dart';

// ═══════════════════════════════════════════════════════════════════════════
// MAIN SCREEN
// ═══════════════════════════════════════════════════════════════════════════
class ChatScreen extends StatefulWidget {
  final String? chatId;
  final String? chatName;
  final String? chatAvatar;
  final bool isGroup;
  final bool isChannel;

  const ChatScreen({
    super.key,
    this.chatId,
    this.chatName,
    this.chatAvatar,
    this.isGroup = false,
    this.isChannel = false,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final _messageController = TextEditingController();
  final _editController = TextEditingController();
  final _searchController = TextEditingController();
  final _gifSearchController = TextEditingController();
  final _scrollController = ScrollController();
  final _messageFocusNode = FocusNode();

  final AudioPlayer _audioPlayer = AudioPlayer();
  final Record _audioRecorder = Record();
  final ImagePicker _picker = ImagePicker();

  String? _chatId;
  String? _chatName;
  String? _chatAvatar;
  bool _isGroup = false;
  bool _isChannel = false;
  String? _currentUserId;
  String? _otherUserId;
  String? _otherUserNickname;
  bool _otherUserOnline = false;
  DateTime? _otherUserLastSeen;
  bool _otherUserTyping = false;
  Timer? _otherTypingHideTimer;

  bool _otherProfilePhotoVisible = true;
  bool _otherLastSeenVisible = true;
  bool _otherVoiceVideoCallsVisible = true;
  StreamSubscription? _otherSettingsSubscription;

  List<Map<String, dynamic>> _messages = [];
  StreamSubscription? _messageSubscription;
  StreamSubscription? _chatSubscription;
  StreamSubscription? _typingSubscription;
  StreamSubscription? _statusSubscription;
  StreamSubscription<Position>? _liveSub;
  Timer? _liveTimer;
  final _blockUnsub = <StreamSubscription>[];
  bool _isLoading = true;
  bool _initialized = false;
  DateTime? _clearedAt;

  String? _wallpaperUrl;
  StreamSubscription? _wallpaperSub;

  final Map<String, Map<String, dynamic>> _userCache = {};
  final Set<String> _pendingUserFetches = {};

  bool _isBlocked = false;
  bool _iBlockedThem = false;
  bool _theyBlockedMe = false;

  String? _replyingTo;
  String? _replyingToContent;
  String? _replyingToSender;
  String? _editingMessageId;
  String? _selectedMessageId;
  bool _multiSelectMode = false;
  final Set<String> _selectedMessageIds = {};

  // ═══════════════════════════════════════════════════════════════════════
  // TELEGRAM INPUT BAR STATE
  // ═══════════════════════════════════════════════════════════════════════
  /// null = keyboard mode, otherwise 'emoji' / 'sticker' / 'gif'
  String? _panelMode;
  String _pickerTab = 'emoji';
  double _keyboardHeight = 300;

  bool _showScrollDown = false;

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

  // ═══════════════════════════════════════════════════════════════════════
  // VOICE RECORDING — Telegram hold-to-record with slide-cancel
  // ═══════════════════════════════════════════════════════════════════════
  bool _isRecording = false;
  bool _isRecordingLocked = false;
  double _recordingSlideOffset = 0;
  double? _recordingDragStartX;
  Timer? _recordingTimer;
  Timer? _recordingSecondsTimer;
  int _recordingSeconds = 0;
  String? _recordingPath;
  final List<double> _recordingWave = [];

  String? _currentlyPlayingAudioId;
  Duration _audioDuration = Duration.zero;
  Duration _audioPosition = Duration.zero;

  final Map<String, VideoPlayerController> _videoControllers = {};

  int _selfDestructSeconds = 0;
  Map<String, dynamic>? _chatSettings;
  String? _myRole = 'member';
  bool _canSend = true;
  bool _canSendFiles = true;
  bool _isAnnouncementsOnly = false;
  String? _creatorEmail;

  bool _isSearching = false;
  List<Map<String, dynamic>> _searchResults = [];
  int _currentSearchIndex = -1;

  List<Map<String, dynamic>> _pinnedMessages = [];
  String? _pinnedMessageId;

  Timer? _onlineHeartbeat;
  Timer? _typingTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAudioPlayer();
    _messageController.addListener(_onTextChanged);
    _scrollController.addListener(_onScroll);
    _messageFocusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (_messageFocusNode.hasFocus && _panelMode != null) {
      setState(() => _panelMode = null);
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    final cur = _scrollController.position.pixels;
    final show = (max - cur) > 200;
    if (show != _showScrollDown) setState(() => _showScrollDown = show);
  }

  void _onTextChanged() {
    // Only rebuild the input bar (via ValueListenableBuilder) and trigger typing
    _startTyping();
  }

  void _initAudioPlayer() {
    _audioPlayer.durationStream.listen((d) {
      if (mounted && d != null) setState(() => _audioDuration = d);
    });
    _audioPlayer.positionStream.listen((p) {
      if (mounted) setState(() => _audioPosition = p);
    });
    _audioPlayer.playerStateStream.listen((state) {
      if (!mounted) return;
      if (state.processingState == ProcessingState.completed) {
        setState(() {
          _currentlyPlayingAudioId = null;
          _audioPosition = Duration.zero;
        });
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;

    final args =
        ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    if (args != null) {
      _chatId = args['chatId'] as String?;
      _chatName = args['chatName'] as String?;
      _chatAvatar = args['chatAvatar'] as String?;
      _isGroup = args['isGroup'] as bool? ?? false;
      _isChannel = args['isChannel'] as bool? ?? false;
    }

    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    _currentUserId = auth.user?.uid ?? auth.mockUserId;

    if (_chatId == null) {
      setState(() => _isLoading = false);
      return;
    }

    _loadChatInfoAndStart();
    _loadStickers();
    _setOnlineStatus();
    _loadWallpaper();
  }

  // ═══════════════════════════════════════════════════════════════════════
  // WALLPAPER
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _loadWallpaper() async {
    if (_currentUserId == null) return;
    _wallpaperSub?.cancel();

    _wallpaperSub = FirebaseFirestore.instance
        .collection('user_settings')
        .doc(_currentUserId)
        .snapshots()
        .listen((doc) {
      if (!mounted) return;
      final d = doc.data() ?? {};
      final wallpapers =
          (d['chat_wallpapers'] as Map<String, dynamic>?) ?? {};
      final perChat = _chatId != null ? wallpapers[_chatId] : null;
      final defaultWall = d['default_wallpaper'];
      setState(() {
        _wallpaperUrl = (perChat ?? defaultWall) as String?;
      });
    });
  }

  // ═══════════════════════════════════════════════════════════════════════
  // CHAT INFO + SUBSCRIPTIONS
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _loadChatInfoAndStart() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('chats')
          .doc(_chatId)
          .get();
      if (doc.exists) {
        _applyChatInfo(doc.data() as Map<String, dynamic>);
      }
    } catch (_) {}

    _subscribeToChat();
    _loadMessages();
    _subscribeToMessages();
    _loadPinnedMessages();

    if (!_isGroup && !_isChannel) {
      _initDirectFeatures();
    }
  }

  void _applyChatInfo(Map<String, dynamic> data) {
    final clearedMap = data['cleared_at'] as Map<String, dynamic>?;
    final clearedTs = _currentUserId != null
        ? (clearedMap?[_currentUserId] as Timestamp?)
        : null;
    _clearedAt = clearedTs?.toDate();

    _creatorEmail = data['created_by_email'] as String?;
    _chatSettings = data['settings'] as Map<String, dynamic>?;
    _myRole =
        (data['participants_data']?[_currentUserId]?['role'] ?? 'member')
            as String;

    final isAdmin = _myRole == 'owner' ||
        _myRole == 'admin' ||
        _myRole == 'creator';
    _canSend = !(_chatSettings?['chat_disabled'] == true && !isAdmin);
    _canSendFiles =
        !(_chatSettings?['file_sharing_disabled'] == true && !isAdmin);
    _isAnnouncementsOnly =
        _chatSettings?['announcements_only'] == true && !isAdmin;
    _selfDestructSeconds = (data['self_destruct_seconds'] ?? 0) as int;
    _pinnedMessageId = data['pinned_message_id'] as String?;

    if (!_isGroup && !_isChannel) {
      final parts = List<String>.from(data['participants'] ?? []);
      _otherUserId = parts.firstWhere(
        (id) => id != _currentUserId,
        orElse: () => '',
      );
      if (_otherUserId!.isEmpty) _otherUserId = null;
    }
  }

  void _subscribeToChat() {
    _chatSubscription = FirebaseFirestore.instance
        .collection('chats')
        .doc(_chatId)
        .snapshots()
        .listen((doc) {
      if (!doc.exists || !mounted) return;
      final data = doc.data() as Map<String, dynamic>;
      setState(() => _applyChatInfo(data));
      _loadPinnedMessages();
    });
  }

  Future<void> _initDirectFeatures() async {
    if (_otherUserId == null) return;
    await _checkBlockStatus();
    _subscribeBlockStatus();
    _subscribeOtherUserStatus();
    _subscribeOtherUserSettings();
    _subscribeTyping();
    _loadNickname();
  }

  void _subscribeOtherUserSettings() {
    if (_otherUserId == null) return;
    _otherSettingsSubscription?.cancel();
    _otherSettingsSubscription = FirebaseFirestore.instance
        .collection('user_settings')
        .doc(_otherUserId)
        .snapshots()
        .listen((doc) {
      if (!mounted) return;
      final d = doc.data() ?? {};
      setState(() {
        _otherProfilePhotoVisible =
            d['profile_photo_visible'] as bool? ?? true;
        _otherLastSeenVisible =
            d['last_seen_visible'] as bool? ?? true;
        _otherVoiceVideoCallsVisible =
            d['voice_video_calls_visible'] as bool? ?? true;
      });
    });
  }

  Future<void> _loadNickname() async {
    if (_otherUserId == null || _currentUserId == null) return;
    try {
      final d = await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUserId)
          .collection('nicknames')
          .doc(_otherUserId)
          .get();
      if (d.exists && mounted) {
        setState(() => _otherUserNickname = d.data()?['nickname']);
      }
    } catch (_) {}
  }

  Future<void> _checkBlockStatus() async {
    if (_otherUserId == null) return;
    try {
      final myDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUserId)
          .get();
      final myBlocked =
          List<String>.from(myDoc.data()?['blocked_users'] ?? []);
      final theirDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(_otherUserId)
          .get();
      final theirBlocked =
          List<String>.from(theirDoc.data()?['blocked_users'] ?? []);
      if (!mounted) return;
      setState(() {
        _iBlockedThem = myBlocked.contains(_otherUserId);
        _theyBlockedMe = theirBlocked.contains(_currentUserId);
        _isBlocked = _iBlockedThem || _theyBlockedMe;
      });
    } catch (_) {}
  }

  void _subscribeBlockStatus() {
    if (_otherUserId == null) return;
    _blockUnsub.add(
      FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUserId)
          .snapshots()
          .listen((snap) async {
        if (!mounted) return;
        final blocked =
            List<String>.from(snap.data()?['blocked_users'] ?? []);
        final theirDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(_otherUserId)
            .get();
        if (!mounted) return;
        final theirBlocked =
            List<String>.from(theirDoc.data()?['blocked_users'] ?? []);
        setState(() {
          _iBlockedThem = blocked.contains(_otherUserId);
          _theyBlockedMe = theirBlocked.contains(_currentUserId);
          _isBlocked = _iBlockedThem || _theyBlockedMe;
        });
      }),
    );
  }

  void _subscribeOtherUserStatus() {
    if (_otherUserId == null) return;
    _statusSubscription?.cancel();
    _statusSubscription = FirebaseFirestore.instance
        .collection('users')
        .doc(_otherUserId)
        .snapshots()
        .listen((doc) {
      if (!mounted || !doc.exists) return;
      final d = doc.data() as Map<String, dynamic>;
      final online = d['is_online'] == true;
      final lastSeen = d['last_seen'] as Timestamp?;
      if (!mounted) return;
      setState(() {
        _otherUserOnline = online;
        _otherUserLastSeen = lastSeen?.toDate();
      });
    });
  }

  void _subscribeTyping() {
    if (_otherUserId == null) return;
    _typingSubscription?.cancel();
    _typingSubscription = FirebaseFirestore.instance
        .collection('chats')
        .doc(_chatId)
        .collection('typing')
        .doc(_otherUserId)
        .snapshots()
        .listen((doc) {
      if (!mounted) return;
      final isTyping =
          doc.exists && (doc.data()?['is_typing'] as bool? ?? false);
      setState(() => _otherUserTyping = isTyping);
      _otherTypingHideTimer?.cancel();
      if (isTyping) {
        _otherTypingHideTimer = Timer(const Duration(seconds: 13), () {
          if (mounted) setState(() => _otherUserTyping = false);
        });
      }
    });
  }

  void _startTyping() {
    if (_chatId == null || _currentUserId == null || _isBlocked) return;
    if (_messageController.text.trim().isEmpty) return;
    FirebaseFirestore.instance
        .collection('chats')
        .doc(_chatId)
        .collection('typing')
        .doc(_currentUserId)
        .set({
      'timestamp': FieldValue.serverTimestamp(),
      'is_typing': true,
    }, SetOptions(merge: true));
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 3), _stopTyping);
  }

  void _stopTyping() {
    if (_chatId == null || _currentUserId == null) return;
    _typingTimer?.cancel();
    FirebaseFirestore.instance
        .collection('chats')
        .doc(_chatId)
        .collection('typing')
        .doc(_currentUserId)
        .delete()
        .catchError((_) {});
  }

  Future<void> _setOnlineStatus() async {
    if (_currentUserId == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUserId)
          .update({
        'is_online': true,
        'last_seen': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
    _onlineHeartbeat?.cancel();
    _onlineHeartbeat = Timer.periodic(const Duration(seconds: 30), (_) async {
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(_currentUserId)
            .update({'last_seen': FieldValue.serverTimestamp()});
      } catch (_) {}
    });
  }

  Future<void> _setOfflineStatus() async {
    _onlineHeartbeat?.cancel();
    if (_currentUserId == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUserId)
          .update({
        'is_online': false,
        'last_seen': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _setOnlineStatus();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _setOfflineStatus();
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // LOAD MESSAGES
  // ═══════════════════════════════════════════════════════════════════════
  List<Map<String, dynamic>> _filterDocs(
      Iterable<QueryDocumentSnapshot> docs) {
    final loaded = <Map<String, dynamic>>[];
    for (final doc in docs) {
      final d = doc.data() as Map<String, dynamic>;
      if (d['deleted_for_everyone'] == true) continue;
      final df = List<String>.from(d['deleted_for'] ?? []);
      if (_currentUserId != null && df.contains(_currentUserId)) continue;
      final destruct = d['self_destruct_seconds'] as int?;
      if (destruct != null && destruct > 0 && d['created_at'] != null) {
        final ct = (d['created_at'] as Timestamp).toDate();
        if (DateTime.now().difference(ct).inSeconds > destruct) continue;
      }
      if (_clearedAt != null && d['created_at'] != null) {
        final ct = (d['created_at'] as Timestamp).toDate();
        if (!ct.isAfter(_clearedAt!)) continue;
      }
      loaded.add({'id': doc.id, ...d});
    }
    return loaded;
  }

  Set<String> _senderIdsOf(List<Map<String, dynamic>> list) {
    final ids = <String>{};
    for (final m in list) {
      final sid = m['sender_id'];
      if (sid is String) ids.add(sid);
    }
    return ids;
  }

  Future<void> _loadMessages() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('chats')
          .doc(_chatId)
          .collection('messages')
          .orderBy('created_at', descending: true)
          .limit(100)
          .get();

      final loaded = _filterDocs(snap.docs);
      await _fetchMissingUsers(_senderIdsOf(loaded));
      if (!mounted) return;
      setState(() {
        _messages = loaded;
        _isLoading = false;
      });
      _scrollToBottom(force: true);
      _markAsRead();
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _subscribeToMessages() {
    _messageSubscription?.cancel();
    _messageSubscription = FirebaseFirestore.instance
        .collection('chats')
        .doc(_chatId)
        .collection('messages')
        .orderBy('created_at', descending: true)
        .limit(100)
        .snapshots()
        .listen((snap) async {
      final loaded = _filterDocs(snap.docs);
      await _fetchMissingUsers(_senderIdsOf(loaded));
      if (!mounted) return;
      setState(() {
        _messages = loaded;
        _isLoading = false;
      });
      _scrollToBottom();
      _markAsRead();
    });
  }

  Future<void> _fetchMissingUsers(Set<String> ids) async {
    final missing = ids
        .where((id) =>
            !_userCache.containsKey(id) &&
            !_pendingUserFetches.contains(id))
        .toList();
    if (missing.isEmpty) return;
    _pendingUserFetches.addAll(missing);
    final docs = await Future.wait(missing.map(
        (id) => FirebaseFirestore.instance.collection('users').doc(id).get()));
    _pendingUserFetches.removeAll(missing);
    for (final d in docs) {
      if (d.exists) {
        final u = d.data()!;
        _userCache[d.id] = {
          'username': u['username'] ?? u['display_name'] ?? 'Unknown',
          'display_name': u['display_name'] ?? u['username'] ?? 'Unknown',
          'avatar_url': u['avatar_url'],
          'email': u['email'],
          'is_verified': _isVerifiedEmail(u['email']),
        };
      }
    }
  }

  bool _isVerifiedEmail(dynamic email) {
    if (email == null) return false;
    final e = email.toString().toLowerCase().trim();
    if (e.endsWith('@bot.aurachat.app')) return false;
    return e.endsWith('@gmail.com') || e.endsWith('@aurachat.app');
  }

  Future<void> _markAsRead() async {
    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_chatId)
          .update({
        'unread_counts.$_currentUserId': 0,
        'last_read_at.$_currentUserId': FieldValue.serverTimestamp(),
      });
      final unread = await FirebaseFirestore.instance
          .collection('chats')
          .doc(_chatId)
          .collection('messages')
          .where('is_read', isEqualTo: false)
          .limit(500)
          .get();
      if (unread.docs.isEmpty) return;
      final batch = FirebaseFirestore.instance.batch();
      var n = 0;
      for (final doc in unread.docs) {
        if (doc.data()['sender_id'] != _currentUserId) {
          batch.update(doc.reference, {'is_read': true});
          n++;
        }
      }
      if (n > 0) await batch.commit();
    } catch (_) {}
  }

  void _scrollToBottom({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      final cur = _scrollController.position.pixels;
      if (force || (max - cur) < 300) {
        _scrollController.jumpTo(max);
      }
    });
  }

  Future<void> _loadPinnedMessages() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('chats')
          .doc(_chatId)
          .collection('pinned_messages')
          .orderBy('pinned_at', descending: true)
          .limit(3)
          .get();
      final pinned = snap.docs
          .map((d) => {'id': d.id, ...d.data()})
          .where((p) {
        final hidden = List<String>.from(p['hidden_for'] ?? []);
        return !hidden.contains(_currentUserId);
      }).toList();
      if (!mounted) return;
      setState(() => _pinnedMessages = pinned);
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════════════════════════
  // SEND
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _sendTextMessage() async {
    if (_isBlocked || !_canSend || _isAnnouncementsOnly) return;
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    _messageController.clear();
    _stopTyping();
    await _sendMessage(type: 'text', content: text);
    if (_EffectBurst.isTrigger(text)) {
      if (mounted) _EffectBurst.fire(context, text);
    }
  }

  Future<void> _sendMessage({
    required String type,
    required String content,
    String? mediaUrl,
    String? fileName,
    String? fileSize,
    int? duration,
    Map<String, dynamic>? sticker,
    Map<String, dynamic>? location,
    Map<String, dynamic>? contact,
    Map<String, dynamic>? linkPreview,
    List<Map<String, dynamic>>? images,
    String? gifUrl,
    bool viewOnce = false,
  }) async {
    if (_currentUserId == null || _chatId == null) return;

    final messageId = const Uuid().v4();
    final now = DateTime.now().toIso8601String();

    final serverMessage = <String, dynamic>{
      'id': messageId,
      'chat_id': _chatId,
      'sender_id': _currentUserId,
      'text': content,
      'content': content,
      'type': type,
      'media_type': type,
      'media_url': mediaUrl,
      'file_name': fileName,
      'file_size': fileSize,
      'duration': duration,
      'sticker': sticker,
      'images': images,
      'gif_url': gifUrl,
      'location_lat': location?['lat'],
      'location_lng': location?['lng'],
      'location_label': location?['label'],
      'location_live': location?['live'] ?? false,
      'contact': contact,
      'link_preview': linkPreview,
      'view_once': viewOnce,
      'reply_to': _replyingTo,
      'reply_to_content': _replyingToContent,
      'reply_to_sender': _replyingToSender,
      'self_destruct_seconds':
          _selfDestructSeconds > 0 ? _selfDestructSeconds : null,
      'created_at': FieldValue.serverTimestamp(),
      'is_read': false,
      'is_edited': false,
      'deleted_for_everyone': false,
      'deleted_for': [],
      'reactions': {},
    };

    setState(() {
      _messages.insert(
        0,
        {...serverMessage, 'created_at': now, 'created_at_local': now},
      );
      _replyingTo = null;
      _replyingToContent = null;
      _replyingToSender = null;
    });
    _scrollToBottom(force: true);

    try {
      final ref = FirebaseFirestore.instance
          .collection('chats')
          .doc(_chatId)
          .collection('messages')
          .doc(messageId);
      await ref.set(serverMessage);

      final upd = <String, dynamic>{
        'last_message': _lastMessageLabel(type, content),
        'last_message_at': FieldValue.serverTimestamp(),
      };
      if (_otherUserId != null) {
        upd['unread_counts.$_otherUserId'] = FieldValue.increment(1);
      }
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_chatId)
          .update(upd);

      if (_selfDestructSeconds > 0) {
        Timer(Duration(seconds: _selfDestructSeconds), () {
          FirebaseFirestore.instance
              .collection('chats')
              .doc(_chatId)
              .collection('messages')
              .doc(messageId)
              .update({
            'deleted_for_everyone': true,
            'text': 'This message was deleted',
            'content': 'This message was deleted',
            'media_url': null,
          }).catchError((_) {});
        });
      }

      // Non-blocking link preview fetch
      if (type == 'text' && linkPreview == null) {
        final url = _detectFirstUrl(content);
        if (url != null &&
            !_InviteLinkDetector.isInvite(url) &&
            !_AuraShortLink.isShortLink(url)) {
          _fetchAndAttachLinkPreview(ref, url);
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _messages.removeWhere((m) => m['id'] == messageId));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _fetchAndAttachLinkPreview(
      DocumentReference ref, String url) async {
    try {
      final preview = await _fetchLinkPreview(url);
      if (preview == null) return;
      await ref.update({'link_preview': preview});
    } catch (_) {}
  }

  String _lastMessageLabel(String type, String content) {
    switch (type) {
      case 'image':
        return '📷 Photo';
      case 'video':
        return '🎥 Video';
      case 'audio':
        return '🎤 Voice message';
      case 'file':
        return '📎 File';
      case 'sticker':
        return '🎨 Sticker';
      case 'gif':
        return '🎞️ GIF';
      case 'location':
        return '📍 Location';
      case 'contact':
        return '👤 Contact';
      default:
        return content;
    }
  }

  String? _detectFirstUrl(String text) {
    final m = RegExp(r'(https?://[^\s]+)').firstMatch(text);
    return m?.group(1);
  }

  Future<Map<String, dynamic>?> _fetchLinkPreview(String url) async {
    try {
      final r = await http.get(Uri.parse(
          'https://api.microlink.io/?url=${Uri.encodeComponent(url)}'));
      if (r.statusCode != 200) return null;
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      if (body['status'] != 'success') return null;
      final d = body['data'] as Map<String, dynamic>;
      return {
        'title': d['title'] ?? '',
        'description': d['description'] ?? '',
        'image': (d['image']?['url']) ?? '',
        'domain': d['publisher'] ??
            (d['url'] != null ? Uri.parse(d['url'] as String).host : ''),
        'url': d['url'] ?? url,
      };
    } catch (_) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // STICKERS
  // ═══════════════════════════════════════════════════════════════════════
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
    if (_isBlocked || !_canSend || _isAnnouncementsOnly) return;
    setState(() => _panelMode = null);
    await _sendMessage(
      type: 'sticker',
      content: '🎨 Sticker',
      sticker: {
        'url': s['url'],
        'sticker_type': s['sticker_type'] ?? 'static',
      },
      mediaUrl: s['url'],
    );
  }

  Future<void> _sendGif(String url) async {
    setState(() => _panelMode = null);
    await _sendMessage(
        type: 'gif', content: '🎞️ GIF', gifUrl: url, mediaUrl: url);
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

  // ═══════════════════════════════════════════════════════════════════════
  // VOICE RECORDING — Telegram hold-to-record with slide-cancel
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _startRecordingTelegram() async {
    try {
      final has = await _audioRecorder.hasPermission();
      if (!has) return;
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';

      await _audioRecorder.start(
      path,
        encoder: AudioEncoder.aacLc,
      );
        
        
      

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
    } catch (e) {
      debugPrint('Start recording failed: $e');
    }
  }

  Future<void> _stopRecordingTelegram({bool send = true}) async {
    try {
      _recordingTimer?.cancel();
      _recordingSecondsTimer?.cancel();
      final path = await _audioRecorder.stop();
      if (!mounted) return;
      setState(() {
        _isRecording = false;
        _isRecordingLocked = false;
        _recordingSlideOffset = 0;
      });

      if (!send || path == null) {
        if (path != null) {
          final f = File(path);
          if (await f.exists()) await f.delete();
        }
        return;
      }

      final file = File(path);
      final size = await file.length();
      if (size < 1000) {
        await file.delete();
        return;
      }

      await _uploadAndSendMedia(
        file: file,
        type: 'audio',
        fileName: 'Voice message',
        fileSize: _formatFileSize(size),
        duration: _recordingSeconds,
      );
    } catch (_) {}
  }

  void _lockRecording() {
    setState(() {
      _isRecordingLocked = true;
      _recordingSlideOffset = 0;
    });
  }

  // ═══════════════════════════════════════════════════════════════════════
  // MEDIA PICKERS
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _pickImage() async {
    if (!_canSendFiles) return;
    final x = await _picker.pickImage(
        source: ImageSource.gallery, imageQuality: 90);
    if (x == null) return;
    await _uploadAndSendMedia(
      file: File(x.path),
      type: 'image',
      fileName: 'Photo',
    );
  }

  Future<void> _pickMultipleImages() async {
    if (!_canSendFiles) return;
    final xs = await _picker.pickMultiImage(imageQuality: 85);
    if (xs.isEmpty) return;
    if (xs.length == 1) {
      await _uploadAndSendMedia(
          file: File(xs.first.path), type: 'image', fileName: 'Photo');
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Row(children: [
        SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(width: 12),
        Text('Uploading...'),
      ]),
      duration: Duration(seconds: 60),
    ));
    try {
      final uploaded = <Map<String, dynamic>>[];
      for (final x in xs) {
        final url = await CloudinaryService.uploadImage(
            File(x.path), 'luma/chats/$_chatId');
        if (url != null) uploaded.add({'url': url});
      }
      if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
      if (uploaded.isEmpty) return;
      if (uploaded.length == 1) {
        await _sendMessage(
            type: 'image',
            content: 'Photo',
            mediaUrl: uploaded.first['url'],
            fileName: 'Photo');
      } else {
        await _sendMessage(
          type: 'image',
          content: 'Album',
          mediaUrl: uploaded.first['url'],
          images: uploaded,
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
    }
  }

  Future<void> _takePhoto() async {
    if (!_canSendFiles) return;
    final x = await _picker.pickImage(source: ImageSource.camera);
    if (x == null) return;
    await _uploadAndSendMedia(
      file: File(x.path),
      type: 'image',
      fileName: 'Photo',
    );
  }

  Future<void> _pickVideo() async {
    if (!_canSendFiles) return;
    final x = await _picker.pickVideo(source: ImageSource.gallery);
    if (x == null) return;
    await _uploadAndSendMedia(
      file: File(x.path),
      type: 'video',
      fileName: 'Video',
    );
  }

  Future<void> _recordVideo() async {
    if (!_canSendFiles) return;
    final x = await _picker.pickVideo(source: ImageSource.camera);
    if (x == null) return;
    await _uploadAndSendMedia(
      file: File(x.path),
      type: 'video',
      fileName: 'Video',
    );
  }

  Future<void> _pickFile() async {
    if (!_canSendFiles) return;
    final res = await FilePicker.platform.pickFiles(allowMultiple: false);
    if (res == null || res.files.isEmpty) return;
    final f = res.files.first;
    if (f.path == null) return;
    await _uploadAndSendMedia(
      file: File(f.path!),
      type: 'file',
      fileName: f.name,
      fileSize: _formatFileSize(f.size),
    );
  }

  Future<void> _uploadAndSendMedia({
    required File file,
    required String type,
    String? fileName,
    String? fileSize,
    int? duration,
    bool viewOnce = false,
  }) async {
    if (_currentUserId == null || _chatId == null) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Row(children: [
        SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(width: 12),
        Text('Uploading...'),
      ]),
      duration: Duration(seconds: 60),
    ));
    try {
      String? url;
      if (type == 'image') {
        url =
            await CloudinaryService.uploadImage(file, 'luma/chats/$_chatId');
      } else if (type == 'video') {
        url =
            await CloudinaryService.uploadVideo(file, 'luma/chats/$_chatId');
      } else if (type == 'audio') {
        url =
            await CloudinaryService.uploadAudio(file, 'luma/chats/$_chatId');
      } else {
        url =
            await CloudinaryService.uploadFile(file, 'luma/chats/$_chatId');
      }
      if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
      if (url == null) throw Exception('Upload failed');
      await _sendMessage(
        type: type,
        content: fileName ?? type,
        mediaUrl: url,
        fileName: fileName,
        fileSize: fileSize,
        duration: duration,
        viewOnce: viewOnce,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // AUDIO PLAYBACK + MEDIA VIEWERS
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _playVoice(String id, String url) async {
    try {
      if (_currentlyPlayingAudioId == id) {
        if (_audioPlayer.playing) {
          await _audioPlayer.pause();
        } else {
          await _audioPlayer.play();
        }
        return;
      }
      await _audioPlayer.stop();
      await _audioPlayer.setUrl(url);
      setState(() => _currentlyPlayingAudioId = id);
      await _audioPlayer.play();
    } catch (_) {}
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
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Cannot open: $e')));
      }
    }
  }

  void _openImageViewer(String url) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          fit: StackFit.expand,
          children: [
            PhotoView(
              imageProvider: CachedNetworkImageProvider(url),
              minScale: PhotoViewComputedScale.contained,
              maxScale: PhotoViewComputedScale.covered * 2,
            ),
            Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              right: 12,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openViewOnce(String id, String url, {required bool isVideo}) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ViewOnceViewer(
        url: url,
        isVideo: isVideo,
        onExpired: () async {
          if (mounted) Navigator.pop(context);
          try {
            await FirebaseFirestore.instance
                .collection('chats')
                .doc(_chatId)
                .collection('messages')
                .doc(id)
                .update({
              'deleted_for_everyone': true,
              'text': 'This message was deleted',
              'content': 'This message was deleted',
              'media_url': null,
            });
          } catch (_) {}
        },
      ),
    );
  }

  Future<void> _openLocationMap(double lat, double lng) async {
    final uri = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════════════════════════
  // LOCATION
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _shareLocation() async {
    Navigator.pop(context);
    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        await Geolocator.requestPermission();
      }
      final pos = await Geolocator.getCurrentPosition();
      String label = 'Shared location';
      try {
        final r = await http.get(Uri.parse(
            'https://nominatim.openstreetmap.org/reverse?format=json&lat=${pos.latitude}&lon=${pos.longitude}&zoom=14'));
        if (r.statusCode == 200) {
          final d = jsonDecode(r.body);
          if (d['display_name'] != null) {
            label =
                (d['display_name'] as String).split(',').take(3).join(', ');
          }
        }
      } catch (_) {}
      await _sendMessage(
        type: 'location',
        content: '📍 Location',
        location: {
          'lat': pos.latitude,
          'lng': pos.longitude,
          'label': label,
          'live': false,
        },
      );
    } catch (_) {}
  }

  Future<void> _startLiveLocation() async {
    Navigator.pop(context);
    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        await Geolocator.requestPermission();
      }

      await _liveSub?.cancel();
      _liveTimer?.cancel();
      _liveSub = null;
      _liveTimer = null;

      final first = await Geolocator.getCurrentPosition();
      final msgId = const Uuid().v4();
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_chatId)
          .collection('messages')
          .doc(msgId)
          .set({
        'id': msgId,
        'sender_id': _currentUserId,
        'type': 'location',
        'media_type': 'location',
        'location_live': true,
        'location_lat': first.latitude,
        'location_lng': first.longitude,
        'location_label': 'Live location',
        'created_at': FieldValue.serverTimestamp(),
        'is_read': false,
        'is_edited': false,
        'deleted_for_everyone': false,
        'deleted_for': [],
        'reactions': {},
      });
      _liveSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
        ),
      ).listen((p) async {
        try {
          await FirebaseFirestore.instance
              .collection('chats')
              .doc(_chatId)
              .collection('messages')
              .doc(msgId)
              .update({
            'location_lat': p.latitude,
            'location_lng': p.longitude,
          });
        } catch (_) {}
      });
      _liveTimer = Timer(const Duration(minutes: 15), () async {
        await _liveSub?.cancel();
        _liveSub = null;
        await FirebaseFirestore.instance
            .collection('chats')
            .doc(_chatId)
            .collection('messages')
            .doc(msgId)
            .update({
          'location_live': false,
          'location_label': 'Live location ended',
        });
      });
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════════════════════════
  // CONTACT
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _openShareContactSheet() async {
    Navigator.pop(context);
    if (_currentUserId == null) return;
    final theme = Theme.of(context);
    final snap = await FirebaseFirestore.instance
        .collection('chats')
        .where('participants', arrayContains: _currentUserId)
        .get();
    final contacts = <Map<String, dynamic>>[];
    for (final doc in snap.docs) {
      final c = doc.data();
      if ((c['type'] ?? 'direct') != 'direct') continue;
      final parts = List<String>.from(c['participants'] ?? []);
      final otherId =
          parts.firstWhere((id) => id != _currentUserId, orElse: () => '');
      if (otherId.isEmpty) continue;
      if (!_userCache.containsKey(otherId)) {
        await _fetchMissingUsers({otherId});
      }
      final u = _userCache[otherId];
      if (u != null) contacts.add({'uid': otherId, ...u});
    }
    if (!mounted) return;
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
        child: contacts.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No contacts found'),
              )
            : ListView.builder(
                shrinkWrap: true,
                itemCount: contacts.length,
                itemBuilder: (_, i) {
                  final c = contacts[i];
                  final name =
                      c['display_name'] ?? c['username'] ?? 'User';
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor:
                          theme.colorScheme.primary.withOpacity(0.15),
                      backgroundImage: c['avatar_url'] != null
                          ? CachedNetworkImageProvider(c['avatar_url'])
                          : null,
                      child: c['avatar_url'] == null
                          ? Text(name.toString()[0].toUpperCase())
                          : null,
                    ),
                    title: Text(name.toString()),
                    onTap: () {
                      Navigator.pop(context);
                      _sendMessage(
                        type: 'contact',
                        content: '👤 Contact',
                        contact: {
                          'uid': c['uid'],
                          'username': c['username'],
                          'display_name': name,
                          'avatar_url': c['avatar_url'],
                        },
                      );
                    },
                  );
                },
              ),
      ),
    );
  }

  Future<void> _pickViewOnce() async {
    Navigator.pop(context);
    final theme = Theme.of(context);
    final picker = ImagePicker();
    final choice = await showModalBottomSheet<String>(
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
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              decoration: BoxDecoration(
                color: theme.dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: Icon(Icons.image, color: theme.colorScheme.primary),
              title: const Text('Pick photo'),
              onTap: () => Navigator.pop(context, 'photo'),
            ),
            ListTile(
              leading:
                  Icon(Icons.videocam, color: theme.colorScheme.primary),
              title: const Text('Pick video'),
              onTap: () => Navigator.pop(context, 'video'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null) return;
    final x = choice == 'photo'
        ? await picker.pickImage(source: ImageSource.gallery)
        : await picker.pickVideo(source: ImageSource.gallery);
    if (x == null) return;
    await _uploadAndSendMedia(
      file: File(x.path),
      type: choice == 'photo' ? 'image' : 'video',
      fileName: choice == 'photo' ? 'Photo' : 'Video',
      viewOnce: true,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // MESSAGE OPTIONS — Telegram style with horizontal reaction row + vertical menu
  // ═══════════════════════════════════════════════════════════════════════
  void _showMessageOptions(Map<String, dynamic> m) {
    final canForward = Provider.of<SettingsProvider>(context, listen: false)
        .forwardedMessages;
    final isMe = m['sender_id'] == _currentUserId;
    final isDeleted = m['deleted_for_everyone'] == true;
    final isText = (m['media_type'] ?? 'text') == 'text';
    final isEdited = m['is_edited'] == true;
    _selectedMessageId = m['id'];

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'dismiss',
      barrierColor: Colors.black.withOpacity(0.4),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (ctx, _, __) {
        return _MessageOptionsOverlay(
          message: m,
          isMe: isMe,
          isDeleted: isDeleted,
          isText: isText,
          isEdited: isEdited,
          canForward: canForward,
          onReact: (e) {
            Navigator.pop(ctx);
            _quickReact(m['id'], e);
          },
          onEdit: () {
            Navigator.pop(ctx);
            _openEditDialog(m);
          },
          onEditHistory: () {
            Navigator.pop(ctx);
            _openEditHistory(m['id']);
          },
          onCopy: () {
            Navigator.pop(ctx);
            Clipboard.setData(
                ClipboardData(text: (m['text'] ?? '').toString()));
          },
          onReply: () {
            Navigator.pop(ctx);
            _setReply(m);
          },
          onForward: () {
            Navigator.pop(ctx);
            _forwardMessage(m);
          },
          onPin: () {
            Navigator.pop(ctx);
            _pinMessage(m['id']);
          },
          onSave: () {
            Navigator.pop(ctx);
            _saveMessage(m);
          },
          onDownload: () {
            Navigator.pop(ctx);
            _downloadMedia(m['media_url'], m['file_name'] ?? 'file');
          },
          onSelect: () {
            Navigator.pop(ctx);
            _enterMultiSelect(m['id']);
          },
          onReport: () {
            Navigator.pop(ctx);
            _openReportDialog(m);
          },
          onDeleteEveryone: () {
            Navigator.pop(ctx);
            _confirmDelete(m['id']);
          },
          onDeleteMe: () {
            Navigator.pop(ctx);
            _deleteForMe(m['id']);
          },
        );
      },
    );
  }

  Widget _sheetTile(IconData i, String label, VoidCallback onTap,
      {Color? color}) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.onSurface;
    return ListTile(
      dense: true,
      leading: Icon(i,
          size: 22,
          color: color ?? theme.colorScheme.onSurface.withOpacity(0.75)),
      title: Text(label, style: TextStyle(color: c, fontSize: 15)),
      onTap: onTap,
    );
  }

  Future<void> _quickReact(String id, String emoji) async {
    if (_currentUserId == null) return;
    final ref = FirebaseFirestore.instance
        .collection('chats')
        .doc(_chatId)
        .collection('messages')
        .doc(id);
    final doc = await ref.get();
    if (!doc.exists) return;
    final r = Map<String, dynamic>.from(doc.data()?['reactions'] ?? {});
    final users = List<String>.from(r[emoji] ?? []);
    if (users.contains(_currentUserId)) {
      users.remove(_currentUserId);
    } else {
      users.add(_currentUserId!);
    }
    if (users.isEmpty) {
      r.remove(emoji);
    } else {
      r[emoji] = users;
    }
    await ref.update({'reactions': r});
  }

  void _setReply(Map<String, dynamic> m) {
    setState(() {
      _replyingTo = m['id'];
      _replyingToContent =
          (m['text'] ?? m['content'] ?? m['media_type'] ?? 'Media').toString();
      final u = _userCache[m['sender_id']];
      _replyingToSender =
          (u?['display_name'] ?? u?['username'] ?? 'Unknown').toString();
    });
  }

  void _openEditDialog(Map<String, dynamic> m) {
    final theme = Theme.of(context);
    _editController.text = (m['text'] ?? m['content'] ?? '').toString();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Edit message'),
        content: TextField(
          controller: _editController,
          maxLines: null,
          decoration: const InputDecoration(hintText: 'New text...'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final id = m['id'];
              final t = _editController.text.trim();
              Navigator.pop(context);
              if (t.isEmpty) return;
              final ref = FirebaseFirestore.instance
                  .collection('chats')
                  .doc(_chatId)
                  .collection('messages')
                  .doc(id);
              final doc = await ref.get();
              final old = (doc.data()?['text'] ?? '').toString();
              await ref.update({
                'text': t,
                'content': t,
                'is_edited': true,
                'updated_at': FieldValue.serverTimestamp(),
                'edit_history': FieldValue.arrayUnion([
                  {
                    'text': old,
                    'edited_at': DateTime.now().toIso8601String(),
                  }
                ]),
              });
            },
            child: Text('Save',
                style: TextStyle(color: theme.colorScheme.primary)),
          ),
        ],
      ),
    );
  }

  Future<void> _openEditHistory(String msgId) async {
    final theme = Theme.of(context);
    final doc = await FirebaseFirestore.instance
        .collection('chats')
        .doc(_chatId)
        .collection('messages')
        .doc(msgId)
        .get();
    if (!doc.exists) return;
    final d = doc.data()!;
    final history = (d['edit_history'] as List?) ?? [];
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Version history'),
        content: SizedBox(
          width: 320,
          child: ListView(
            shrinkWrap: true,
            children: [
              _histTile(theme, 'Current',
                  (d['text'] ?? d['content'] ?? '').toString(),
                  highlight: true),
              for (final h in history.reversed)
                _histTile(theme, _fmtTs(h['edited_at']),
                    (h['text'] ?? '').toString()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _histTile(ThemeData theme, String time, String text,
      {bool highlight = false}) {
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

  String _fmtTs(dynamic ts) {
    if (ts == null) return '';
    final d =
        ts is Timestamp ? ts.toDate() : DateTime.tryParse(ts.toString());
    if (d == null) return '';
    return DateFormat('MMM d, HH:mm').format(d);
  }

  void _confirmDelete(String id) {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete for everyone?'),
        content:
            const Text('This will delete the message for all participants.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await FirebaseFirestore.instance
                  .collection('chats')
                  .doc(_chatId)
                  .collection('messages')
                  .doc(id)
                  .update({
                'deleted_for_everyone': true,
                'text': 'This message was deleted',
                'content': 'This message was deleted',
                'media_url': null,
              });
            },
            style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteForMe(String id) async {
    await FirebaseFirestore.instance
        .collection('chats')
        .doc(_chatId)
        .collection('messages')
        .doc(id)
        .update({
      'deleted_for': FieldValue.arrayUnion([_currentUserId]),
    });
  }

  Future<void> _pinMessage(String id) async {
    await FirebaseFirestore.instance
        .collection('chats')
        .doc(_chatId)
        .collection('pinned_messages')
        .doc(id)
        .set({
      'message_id': id,
      'pinned_at': FieldValue.serverTimestamp(),
      'pinned_by': _currentUserId,
      'scope': 'both',
      'hidden_for': [],
    });
    await FirebaseFirestore.instance
        .collection('chats')
        .doc(_chatId)
        .update({'pinned_message_id': id});
    await _loadPinnedMessages();
  }

  Future<void> _unpinMessage(String id) async {
    await FirebaseFirestore.instance
        .collection('chats')
        .doc(_chatId)
        .collection('pinned_messages')
        .doc(id)
        .delete();
    await FirebaseFirestore.instance
        .collection('chats')
        .doc(_chatId)
        .update({'pinned_message_id': FieldValue.delete()});
    await _loadPinnedMessages();
  }

  Future<void> _saveMessage(Map<String, dynamic> m) async {
    await FirebaseFirestore.instance
        .collection('users')
        .doc(_currentUserId)
        .collection('saved')
        .add({
      'text': m['text'],
      'media_url': m['media_url'],
      'media_type': m['media_type'],
      'sticker': m['sticker'],
      'contact': m['contact'],
      'location_lat': m['location_lat'],
      'location_lng': m['location_lng'],
      'location_label': m['location_label'],
      'from_sender': _userCache[m['sender_id']]?['display_name'],
      'from_chat': _chatName,
      'from_chat_id': _chatId,
      'original_msg_id': m['id'],
      'saved_at': FieldValue.serverTimestamp(),
    });
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Saved')));
    }
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
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _forwardMessage(Map<String, dynamic> m) async {
    final theme = Theme.of(context);
    final snap = await FirebaseFirestore.instance
        .collection('chats')
        .where('participants', arrayContains: _currentUserId)
        .get();
    if (!mounted) return;
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
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: snap.docs.length,
          itemBuilder: (_, i) {
            final c = snap.docs[i];
            if (c.id == _chatId) return const SizedBox.shrink();
            final d = c.data();
            final name = d['name'] ?? d['title'] ?? 'Chat';
            return ListTile(
              leading: CircleAvatar(
                backgroundColor:
                    theme.colorScheme.primary.withOpacity(0.15),
                backgroundImage: d['avatar_url'] != null
                    ? CachedNetworkImageProvider(d['avatar_url'])
                    : null,
                child: d['avatar_url'] == null
                    ? Text(name.toString()[0].toUpperCase())
                    : null,
              ),
              title: Text(name.toString()),
              onTap: () {
                Navigator.pop(context);
                _performForward(m, c.id);
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _performForward(
      Map<String, dynamic> m, String targetChatId) async {
    final ref = FirebaseFirestore.instance
        .collection('chats')
        .doc(targetChatId)
        .collection('messages')
        .doc();
    await ref.set({
      'id': ref.id,
      'text': m['text'],
      'content': m['text'],
      'media_url': m['media_url'],
      'media_type': m['media_type'] ?? 'text',
      'file_name': m['file_name'],
      'file_size': m['file_size'],
      'duration': m['duration'],
      'sticker': m['sticker'],
      'contact': m['contact'],
      'location_lat': m['location_lat'],
      'location_lng': m['location_lng'],
      'location_label': m['location_label'],
      'sender_id': _currentUserId,
      'is_forwarded': true,
      'created_at': FieldValue.serverTimestamp(),
      'is_read': false,
      'is_edited': false,
      'deleted_for_everyone': false,
      'deleted_for': [],
      'reactions': {},
    });
    await FirebaseFirestore.instance
        .collection('chats')
        .doc(targetChatId)
        .update({
      'last_message': '📤 Forwarded',
      'last_message_at': FieldValue.serverTimestamp(),
    });
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Forwarded')));
    }
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

  Future<void> _blockUser() async {
    if (_otherUserId == null || _currentUserId == null) return;
    await FirebaseFirestore.instance
        .collection('users')
        .doc(_currentUserId)
        .update({
      'blocked_users': FieldValue.arrayUnion([_otherUserId]),
    });
    if (mounted) setState(() => _iBlockedThem = true);
  }

  Future<void> _unblockUser() async {
    if (_otherUserId == null || _currentUserId == null) return;
    await FirebaseFirestore.instance
        .collection('users')
        .doc(_currentUserId)
        .update({
      'blocked_users': FieldValue.arrayRemove([_otherUserId]),
    });
    if (mounted) setState(() => _iBlockedThem = false);
  }

  void _openNicknameDialog() {
    final theme = Theme.of(context);
    final ctrl = TextEditingController(text: _otherUserNickname ?? '');
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Nickname'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(hintText: 'Enter nickname...'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              final v = ctrl.text.trim();
              Navigator.pop(context);
              if (_otherUserId == null) return;
              if (v.isEmpty) {
                await FirebaseFirestore.instance
                    .collection('users')
                    .doc(_currentUserId)
                    .collection('nicknames')
                    .doc(_otherUserId)
                    .delete()
                    .catchError((_) {});
                if (mounted) setState(() => _otherUserNickname = null);
              } else {
                await FirebaseFirestore.instance
                    .collection('users')
                    .doc(_currentUserId)
                    .collection('nicknames')
                    .doc(_otherUserId)
                    .set({
                  'nickname': v,
                  'updated_at': FieldValue.serverTimestamp(),
                });
                if (mounted) setState(() => _otherUserNickname = v);
              }
            },
            child: Text('Save',
                style: TextStyle(color: theme.colorScheme.primary)),
          ),
        ],
      ),
    );
  }

  Future<void> _openReportDialog(Map<String, dynamic> m) async {
    final theme = Theme.of(context);
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Report message'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Why are you reporting this?',
                style: TextStyle(
                    color:
                        theme.colorScheme.onSurface.withOpacity(0.6),
                    fontSize: 13)),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              maxLines: 3,
              decoration:
                  const InputDecoration(hintText: 'Add details (optional)...'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Report',
                  style: TextStyle(color: Color(0xFFE0954A)))),
        ],
      ),
    );
    if (ok == true) {
      try {
        await FirebaseFirestore.instance.collection('reports').add({
          'reporter_id': _currentUserId,
          'reported_user_id': m['sender_id'],
          'chat_id': _chatId,
          'message_id': m['id'],
          'message_content': m['text'] ?? m['content'] ?? '',
          'media_type': m['media_type'] ?? 'text',
          'media_url': m['media_url'],
          'details': ctrl.text.trim(),
          'created_at': FieldValue.serverTimestamp(),
          'status': 'pending',
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Report submitted')));
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Failed to submit')));
        }
      }
    }
  }

  Future<void> _startCall(bool video) async {
    if (!_isGroup && _isBlocked) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Unblock to call')));
      return;
    }
    if (!_isGroup && !_isChannel && !_otherVoiceVideoCallsVisible) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This user does not accept calls'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    if (_otherUserId == null && !_isGroup) return;
    final channel = CallService.generateChannelName();
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CallScreen.active(
          channelName: channel,
          isVideoCall: video,
          targetUserId: _otherUserId ?? _chatId ?? 'unknown',
          targetUserName: _chatName ?? 'Unknown',
        ),
      ),
    );
  }

  @override
  void dispose() {
    _onlineHeartbeat?.cancel();
    _recordingSecondsTimer?.cancel();
    _messageController.removeListener(_onTextChanged);
    _scrollController.removeListener(_onScroll);
    _messageFocusNode.removeListener(_onFocusChange);
    WidgetsBinding.instance.removeObserver(this);
    _messageController.dispose();
    _editController.dispose();
    _searchController.dispose();
    _gifSearchController.dispose();
    _scrollController.dispose();
    _messageFocusNode.dispose();
    _audioPlayer.dispose();
    _audioRecorder.dispose();
    _messageSubscription?.cancel();
    _chatSubscription?.cancel();
    _typingSubscription?.cancel();
    _statusSubscription?.cancel();
    _otherSettingsSubscription?.cancel();
    _wallpaperSub?.cancel();
    _liveSub?.cancel();
    _liveTimer?.cancel();
    for (final s in _blockUnsub) {
      s.cancel();
    }
    _otherTypingHideTimer?.cancel();
    _typingTimer?.cancel();
    _recordingTimer?.cancel();
    for (final v in _videoControllers.values) {
      v.dispose();
    }
    final uid = _currentUserId;
    if (uid != null) {
      FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .update({
        'is_online': false,
        'last_seen': FieldValue.serverTimestamp(),
      }).catchError((_) {});
      if (_chatId != null) {
        FirebaseFirestore.instance
            .collection('chats')
            .doc(_chatId)
            .collection('typing')
            .doc(uid)
            .delete()
            .catchError((_) {});
      }
    }
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    if (bottomInset > 0) _keyboardHeight = bottomInset;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: _isSearching ? _buildSearchAppBar(theme) : _buildHeader(theme),
      body: Stack(
        children: [
          Positioned.fill(child: _WallpaperLayer(url: _wallpaperUrl)),

          Column(
            children: [
              if (_pinnedMessages.isNotEmpty) _buildPinnedBanner(theme),
              if (_isBlocked) _buildBlockedBanner(theme),
              if (!_canSend || _isAnnouncementsOnly)
                _buildAdminBanner(theme),
              Expanded(
                child: _isLoading
                    ? Center(
                        child: CircularProgressIndicator(
                            color: theme.colorScheme.primary))
                    : _messages.isEmpty
                        ? const _EmptyState()
                        : _buildMessageList(theme),
              ),
              if (_otherUserTyping && !_isGroup && !_isBlocked)
                _buildTypingIndicator(theme),
              if (_replyingTo != null) _buildReplyBar(theme),
              if (_multiSelectMode) _buildMultiSelectBar(theme),
              if (_isRecording) _buildRecordingBar(theme),
              if (_panelMode != null)
                SizedBox(
                  height: _keyboardHeight > 0 ? _keyboardHeight : 300,
                  child: _buildPickerPanel(theme),
                ),
              _buildInputBar(theme),
            ],
          ),

          if (_showScrollDown)
            Positioned(
              bottom: 100,
              right: 16,
              child: GestureDetector(
                onTap: () {
                  _scrollController.animateTo(
                    _scrollController.position.maxScrollExtent,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOut,
                  );
                },
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: theme.brightness == Brightness.dark
                        ? const Color(0xFF1F1F1F)
                        : Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: theme.dividerColor),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 6),
                    ],
                  ),
                  child: Icon(Icons.keyboard_arrow_down,
                      color: theme.colorScheme.onSurface, size: 22),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // HEADER — Telegram-style: circular back, avatar+name+timer, phone, 3-dot
  // ═══════════════════════════════════════════════════════════════════════
  PreferredSizeWidget _buildHeader(ThemeData theme) {
    final displayName = _otherUserNickname ?? _chatName ?? 'Chat';
    final verified = _userCache[_otherUserId]?['is_verified'] == true;
    final isDark = theme.brightness == Brightness.dark;
    final headerBg =
        isDark ? const Color(0xFF17212B) : const Color(0xFF527DA3);

    String status;
    Color statusColor;
    if (_isGroup || _isChannel) {
      status = 'Tap for info';
      statusColor = Colors.white70;
    } else if (_isBlocked) {
      status = _iBlockedThem ? 'You blocked this user' : 'Blocked';
      statusColor = Colors.redAccent.shade100;
    } else if (_otherUserTyping) {
      status = 'typing...';
      statusColor = const Color(0xFF8ECAFB);
    } else if (_otherUserOnline && _otherLastSeenVisible) {
      status = 'online';
      statusColor = const Color(0xFF8ECAFB);
    } else if (_otherUserLastSeen != null && _otherLastSeenVisible) {
      status = 'last seen ${_timeAgo(_otherUserLastSeen!)}';
      statusColor = Colors.white70;
    } else if (_isGroup || _isChannel) {
      status = 'Tap for info';
      statusColor = Colors.white70;
    } else {
      status = 'last seen recently';
      statusColor = Colors.white70;
    }

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
                // Back circle
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: _headerCircle(
                    theme,
                    icon: Icons.arrow_back,
                    onTap: () => Navigator.pop(context),
                  ),
                ),

                // Avatar + Title
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (_isGroup || _isChannel) {
                        Navigator.pushNamed(context, '/group_info',
                            arguments: {
                              'chatId': _chatId,
                              'chatName': _chatName,
                              'chatAvatar': _chatAvatar,
                              'isChannel': _isChannel,
                            });
                        return;
                      }
                      if (_otherUserId != null) {
                        Navigator.pushNamed(context, '/public_profile',
                            arguments: {
                              'userId': _otherUserId,
                              'username': displayName,
                              'avatar_url': _chatAvatar,
                            });
                      }
                    },
                    child: Row(
                      children: [
                        Stack(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white24,
                              ),
                              child: (_chatAvatar != null &&
                                      _chatAvatar!.isNotEmpty &&
                                      (_isGroup ||
                                          _isChannel ||
                                          _otherProfilePhotoVisible))
                                  ? ClipOval(
                                      child: CachedNetworkImage(
                                        imageUrl: _chatAvatar!,
                                        fit: BoxFit.cover,
                                      ),
                                    )
                                  : Center(
                                      child: Text(
                                        displayName.isNotEmpty
                                            ? displayName[0].toUpperCase()
                                            : '?',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 16,
                                        ),
                                      ),
                                    ),
                            ),
                            if (_otherUserOnline &&
                                !_isGroup &&
                                _otherLastSeenVisible)
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF4CAF50),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: headerBg, width: 2),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  if (verified) ...[
                                    const SizedBox(width: 4),
                                    const Icon(
                                      Icons.verified,
                                      color: Color(0xFF6FB9F3),
                                      size: 14,
                                    ),
                                  ],
                                ],
                              ),
                              Text(
                                status,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: statusColor,
                                  fontSize: 12.5,
                                  fontStyle: _otherUserTyping
                                      ? FontStyle.italic
                                      : FontStyle.normal,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Voice call
                _headerCircle(
                  theme,
                  icon: Icons.call,
                  onTap: () => _startCall(false),
                ),
                // 3-dot
                _headerCircle(
                  theme,
                  icon: Icons.more_vert,
                  onTap: _showMoreMenu,
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _headerCircle(
    ThemeData theme, {
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
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
    );
  }

  PreferredSizeWidget _buildSearchAppBar(ThemeData theme) {
    return AppBar(
      backgroundColor: theme.brightness == Brightness.dark
          ? const Color(0xFF17212B)
          : const Color(0xFF527DA3),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: Colors.white),
        onPressed: () => setState(() {
          _isSearching = false;
          _searchResults.clear();
          _searchController.clear();
        }),
      ),
      title: TextField(
        controller: _searchController,
        autofocus: true,
        style: const TextStyle(color: Colors.white),
        decoration: const InputDecoration(
          hintText: 'Search messages',
          hintStyle: TextStyle(color: Colors.white70),
          border: InputBorder.none,
        ),
        onChanged: (q) {
          final lower = q.toLowerCase();
          setState(() {
            _searchResults = _messages
                .where((m) => (m['text'] ?? '')
                    .toString()
                    .toLowerCase()
                    .contains(lower))
                .toList();
            _currentSearchIndex = _searchResults.isEmpty ? -1 : 0;
          });
        },
      ),
    );
  }

  void _showMoreMenu() {
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
              if (!_isGroup && _otherUserId != null)
                _sheetTile(Icons.person_outline, 'View Profile', () {
                  Navigator.pop(context);
                  Navigator.pushNamed(context, '/public_profile',
                      arguments: {
                        'userId': _otherUserId,
                        'username': _chatName,
                        'avatar_url': _chatAvatar,
                      });
                }),
              if (!_isGroup && _otherUserId != null)
                _sheetTile(Icons.tag, 'Set Nickname', () {
                  Navigator.pop(context);
                  _openNicknameDialog();
                }),
              if (_isGroup || _isChannel)
                _sheetTile(Icons.info_outline, 'Group Info', () {
                  Navigator.pop(context);
                  Navigator.pushNamed(context, '/group_info', arguments: {
                    'chatId': _chatId,
                    'chatName': _chatName,
                    'chatAvatar': _chatAvatar,
                    'isChannel': _isChannel,
                  });
                }),
              _sheetTile(Icons.bookmark_outline, 'Saved Messages', () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/saved_messages');
              }),
              _sheetTile(Icons.image_outlined, 'Create Sticker', () {
                Navigator.pop(context);
                _createStickerFromGallery();
              }),
              _sheetTile(
                _iBlockedThem ? Icons.lock_open : Icons.block,
                _iBlockedThem ? 'Unblock Contact' : 'Block Contact',
                () {
                  Navigator.pop(context);
                  if (_iBlockedThem) {
                    _unblockUser();
                  } else {
                    _blockUser();
                  }
                },
                color: theme.colorScheme.error,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // BANNERS
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildPinnedBanner(ThemeData theme) {
    return GestureDetector(
      onTap: () {
        final first = _pinnedMessages.first;
        final idx = _messages
            .indexWhere((m) => m['id'] == first['message_id']);
        if (idx >= 0 && _scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent - (idx * 80.0),
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeInOut,
          );
        }
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        color: theme.colorScheme.primary.withOpacity(0.08),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (int i = 0; i < _pinnedMessages.length; i++) ...[
              if (i > 0) Divider(color: theme.dividerColor, height: 10),
              Builder(builder: (context) {
                final p = _pinnedMessages[i];
                final msg = _messages.firstWhere(
                  (m) => m['id'] == p['message_id'],
                  orElse: () => {},
                );
                return Row(
                  children: [
                    Icon(Icons.push_pin,
                        size: 14, color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (_userCache[msg['sender_id']]
                                        ?['display_name'] ??
                                    'Pinned')
                                .toString(),
                            style: TextStyle(
                              color: theme.colorScheme.primary,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            (msg['text'] ?? msg['media_type'] ?? 'Message')
                                .toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: theme.colorScheme.onSurface
                                  .withOpacity(0.75),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close,
                          size: 16,
                          color: theme.colorScheme.onSurface
                              .withOpacity(0.4)),
                      onPressed: () => _unpinMessage(p['message_id']),
                    ),
                  ],
                );
              }),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBlockedBanner(ThemeData theme) {
    return GestureDetector(
      onTap: () {
        if (_iBlockedThem) _unblockUser();
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
        color: theme.colorScheme.error.withOpacity(0.1),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.block, size: 14, color: theme.colorScheme.error),
            const SizedBox(width: 8),
            Text(
              _iBlockedThem
                  ? 'You blocked this person. Tap to unblock.'
                  : 'This user blocked you.',
              style:
                  TextStyle(color: theme.colorScheme.error, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdminBanner(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      color: const Color(0xFFE0954A).withOpacity(0.15),
      child: Row(
        children: [
          const Icon(Icons.lock_outline,
              size: 14, color: Color(0xFFE0954A)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _isAnnouncementsOnly
                  ? 'Announcements only — only admins can send'
                  : 'Chat disabled by admin',
              style: const TextStyle(
                  color: Color(0xFFE0954A), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // MESSAGE LIST
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildMessageList(ThemeData theme) {
    final list = _messages.reversed.toList();
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      itemCount: list.length,
      itemBuilder: (context, index) {
        final m = list[index];
        final prev = index > 0 ? list[index - 1] : null;
        final showDate = _shouldShowDate(m, prev);
        final isMine = m['sender_id'] == _currentUserId;
        final selected = _selectedMessageIds.contains(m['id']);
        final grouped = prev != null &&
            prev['sender_id'] == m['sender_id'] &&
            !_shouldShowDate(m, prev);

        return Column(
          children: [
            if (showDate) _dateDivider(theme, m['created_at']),
            _MessageBubble(
              message: m,
              isMine: isMine,
              showAvatar: _isGroup && !isMine,
              grouped: grouped,
              selected: selected,
              multiSelect: _multiSelectMode,
              userCache: _userCache,
              onTap: () {
                if (_multiSelectMode) {
                  _toggleMultiSelect(m['id']);
                } else if (m['view_once'] == true &&
                    m['media_url'] != null &&
                    !isMine) {
                  _openViewOnce(
                    m['id'],
                    m['media_url'],
                    isVideo: m['media_type'] == 'video',
                  );
                } else if (m['media_type'] == 'image' &&
                    m['media_url'] != null) {
                  _openImageViewer(m['media_url']);
                }
              },
              onLongPress: () {
                if (!_multiSelectMode) _showMessageOptions(m);
              },
              onDoubleTap: () => _quickReact(m['id'], '❤️'),
              onReply: () => _setReply(m),
              playingAudioId: _currentlyPlayingAudioId,
              audioPosition: _audioPosition,
              audioDuration: _audioDuration,
              onPlayAudio: (id, url) => _playVoice(id, url),
              onOpenImage: _openImageViewer,
              onOpenFile: _openFile,
              onOpenLocation: _openLocationMap,
              videoControllers: _videoControllers,
              onVideoInit: () => setState(() {}),
              onOpenProfile: (uid, name, avatar) {
                Navigator.pushNamed(context, '/public_profile', arguments: {
                  'userId': uid,
                  'username': name,
                  'avatar_url': avatar,
                });
              },
            ),
          ],
        );
      },
    );
  }

  bool _shouldShowDate(Map<String, dynamic> m, Map<String, dynamic>? prev) {
    if (prev == null) return true;
    final a = _parseTs(m['created_at']);
    final b = _parseTs(prev['created_at']);
    if (a == null || b == null) return false;
    return a.year != b.year || a.month != b.month || a.day != b.day;
  }

  DateTime? _parseTs(dynamic t) {
    if (t == null) return null;
    if (t is Timestamp) return t.toDate();
    if (t is String) return DateTime.tryParse(t);
    return null;
  }

  Widget _dateDivider(ThemeData theme, dynamic ts) {
    final d = _parseTs(ts);
    if (d == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: theme.brightness == Brightness.dark
                ? const Color(0xFF2F2F2F)
                : Colors.black.withOpacity(0.06),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            _formatDate(d),
            style: TextStyle(
                color: theme.colorScheme.onSurface.withOpacity(0.7),
                fontSize: 11),
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yest = today.subtract(const Duration(days: 1));
    final md = DateTime(d.year, d.month, d.day);
    if (md == today) return 'Today';
    if (md == yest) return 'Yesterday';
    return DateFormat('MMM d').format(d);
  }

  String _timeAgo(DateTime d) {
    final diff = DateTime.now().difference(d);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return DateFormat('MMM d, HH:mm').format(d);
  }

  Widget _buildTypingIndicator(ThemeData theme) {
    final u = _otherUserId != null ? _userCache[_otherUserId] : null;
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 6),
      child: Row(
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
            backgroundImage: u?['avatar_url'] != null
                ? CachedNetworkImageProvider(u!['avatar_url'])
                : null,
            child: u?['avatar_url'] == null
                ? Text(
                    (u?['display_name'] ?? 'U').toString()[0].toUpperCase(),
                    style: const TextStyle(fontSize: 10),
                  )
                : null,
          ),
          const SizedBox(width: 8),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: theme.brightness == Brightness.dark
                  ? const Color(0xFF1F1F1F)
                  : Colors.white,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomRight: Radius.circular(16),
                bottomLeft: Radius.circular(4),
              ),
            ),
            child: Row(
              children: [
                for (var i = 0; i < 3; i++)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReplyBar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: theme.brightness == Brightness.dark
            ? const Color(0xFF1F1F1F)
            : Colors.white,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
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
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Replying to ${_replyingToSender ?? ''}',
                    style: TextStyle(
                        color: theme.colorScheme.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
                Text(
                  _replyingToContent ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color:
                          theme.colorScheme.onSurface.withOpacity(0.55),
                      fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close,
                size: 18,
                color: theme.colorScheme.onSurface.withOpacity(0.5)),
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

  Widget _buildMultiSelectBar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.brightness == Brightness.dark
            ? const Color(0xFF1F1F1F)
            : Colors.white,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
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
              final text = _messages
                  .where((m) => _selectedMessageIds.contains(m['id']))
                  .map((m) => (m['text'] ?? '').toString())
                  .join('\n\n');
              Clipboard.setData(ClipboardData(text: text));
              _exitMultiSelect();
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete, color: Colors.red),
            onPressed: () async {
              for (final id in _selectedMessageIds) {
                await FirebaseFirestore.instance
                    .collection('chats')
                    .doc(_chatId)
                    .collection('messages')
                    .doc(id)
                    .update({
                  'deleted_for_everyone': true,
                  'text': 'This message was deleted',
                  'content': 'This message was deleted',
                  'media_url': null,
                });
              }
              _exitMultiSelect();
            },
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // TELEGRAM VOICE RECORDING BAR
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildRecordingBar(ThemeData theme) {
    const slideThreshold = -80.0;
    final slidingToCancel = _recordingSlideOffset < slideThreshold;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.error.withOpacity(0.08),
        border: Border(
            top: BorderSide(color: theme.colorScheme.error.withOpacity(0.2))),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => _stopRecordingTelegram(send: false),
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
            _fmtDuration(_recordingSeconds),
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
              onPressed: () => _stopRecordingTelegram(send: true),
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

  // ═══════════════════════════════════════════════════════════════════════
  // TELEGRAM INPUT BAR
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildInputBar(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    final disabled = !_canSend ||
        _isAnnouncementsOnly ||
        (_isBlocked && !_isGroup);
    final bg = isDark ? const Color(0xFF17212B) : const Color(0xFFF0F0F0);

    return Container(
      color: bg,
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // GIF chip
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: GestureDetector(
                onTap: disabled
                    ? null
                    : () {
                        setState(() {
                          _panelMode = _panelMode == 'gif' ? null : 'gif';
                          _pickerTab = 'gif';
                        });
                        if (_panelMode == 'gif') {
                          _messageFocusNode.unfocus();
                          if (!_gifsLoaded) _loadGifs();
                        } else {
                          _messageFocusNode.requestFocus();
                        }
                      },
                child: Container(
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
            ),

            // Message field
            Expanded(
              child: Container(
                constraints: const BoxConstraints(maxHeight: 140),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF242F3D) : Colors.white,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _messageController,
                  builder: (_, val, __) {
                    return TextField(
                      controller: _messageController,
                      focusNode: _messageFocusNode,
                      enabled: !disabled,
                      minLines: 1,
                      maxLines: null,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      style: TextStyle(
                        color: theme.colorScheme.onSurface,
                        fontSize: 15,
                      ),
                      decoration: InputDecoration(
                        hintText: disabled
                            ? 'Only admins can send'
                            : 'Message',
                        hintStyle: TextStyle(
                          color:
                              theme.colorScheme.onSurface.withOpacity(0.4),
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
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: 6),

            // Attach
            GestureDetector(
              onTap: disabled ? null : () => _showAttachmentSheet(context),
              child: Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                child: Icon(
                  Icons.attach_file,
                  size: 24,
                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
            ),

            // Send/Mic
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _messageController,
              builder: (_, val, __) {
                final hasText = val.text.trim().isNotEmpty;
                return GestureDetector(
                  onLongPressStart:
                      (disabled || hasText) ? null : (d) {
                    _recordingDragStartX = d.globalPosition.dx;
                    _startRecordingTelegram();
                  },
                  onLongPressMoveUpdate:
                      (disabled || hasText) ? null : (d) {
                    final start = _recordingDragStartX;
                    if (start == null) return;
                    setState(() {
                      _recordingSlideOffset =
                          d.globalPosition.dx - start;
                    });
                  },
                  onLongPressEnd: (disabled || hasText) ? null : (_) {
                    final cancelled = _recordingSlideOffset < -80;
                    _recordingDragStartX = null;
                    _stopRecordingTelegram(send: !cancelled);
                  },
                  onTap: (hasText && !disabled) ? _sendTextMessage : null,
                  child: Container(
                    width: 46,
                    height: 46,
                    decoration: const BoxDecoration(
                      color: Color(0xFF3390EC),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      hasText ? Icons.send : Icons.mic,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // PICKER PANEL — Telegram style with bottom tabs
  // ═══════════════════════════════════════════════════════════════════════
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
          // Bottom tab bar
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

  // ── Emoji panel ───────────────────────────────────────────────────────
  Widget _buildEmojiPanel(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    return Column(
      children: [
        // Search bar + favorites row (decorative for now)
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

        // Category row
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
                  _messageController.selection =
                      TextSelection.collapsed(
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

  // ── Sticker panel ─────────────────────────────────────────────────────
  Widget _buildStickerPanel(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    return Column(
      children: [
        // Header
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
                onTap: () => _showStickerCreatorSheet(),
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

        // Search (decorative)
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

        // Pack tabs
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
                  ? _stickerEmpty(
                      theme,
                      _currentStickerPackId == 'fav'
                          ? 'Long-press any sticker to add to favorites'
                          : 'This pack is empty')
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
                          onLongPress: () => _showStickerOptions(s, true),
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: s['sticker_type'] == 'video'
                                ? _StickerVideoPreview(
                                    url: s['url'] as String)
                                : CachedNetworkImage(
                                    imageUrl: s['url'] as String,
                                    fit: BoxFit.contain,
                                    memCacheWidth: 200,
                                  ),
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
        child: Text(label,
            style: const TextStyle(fontSize: 16)),
      ),
    );
  }

  List<Map<String, dynamic>> _stickersInCurrentPack() {
    if (_currentStickerPackId == 'fav') return _favoriteStickers;
    return _myStickers
        .where((s) => s['pack_id'] == _currentStickerPackId)
        .toList();
  }

  Widget _stickerEmpty(ThemeData theme, String msg) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          msg,
          textAlign: TextAlign.center,
          style: TextStyle(
              color: theme.colorScheme.onSurface.withOpacity(0.3),
              fontSize: 12),
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
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: theme.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
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

  // ── Sticker long-press options (matches image 3) ──────────────────────
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
            // Sticker preview
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
            _sheetTile(
              s['favorite'] == true ? Icons.star : Icons.star_border,
              s['favorite'] == true
                  ? 'Remove from Favorites'
                  : 'Add to Favorites',
              () {
                Navigator.pop(context);
                _toggleFavoriteSticker(s);
              },
              color: const Color(0xFFD4A73A),
            ),
            _sheetTile(Icons.copy, 'Copy', () {
              Navigator.pop(context);
              Clipboard.setData(ClipboardData(text: s['url'] as String));
            }),
            _sheetTile(Icons.share, 'Share', () {
              Navigator.pop(context);
            }),
            if (isMine)
              _sheetTile(Icons.delete_outline, 'Delete sticker', () {
                Navigator.pop(context);
                _deleteSticker(s['id']);
              }, color: theme.colorScheme.error),
          ],
        ),
      ),
    );
  }

  // ── GIF panel ─────────────────────────────────────────────────────────
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
                  ? _stickerEmpty(theme, 'No GIFs found')
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

  // ═══════════════════════════════════════════════════════════════════════
  // TELEGRAM ATTACHMENT SHEET — Gallery / File / Location / Article / Contact / Music
  // Matches image 1 (grid of 3x2 with camera overlay on Gallery)
  // ═══════════════════════════════════════════════════════════════════════
  void _showAttachmentSheet(BuildContext context) {
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
              // Grid row 1 — Gallery + File + Location
              Row(
                children: [
                  _attachTile(theme, Icons.photo_library_outlined,
                      'Gallery', onTap: () {
                    Navigator.pop(context);
                    _showGalleryPicker();
                  }),
                  _attachTile(theme, Icons.folder_outlined, 'File',
                      onTap: () {
                    Navigator.pop(context);
                    _pickFile();
                  }),
                  _attachTile(theme, Icons.location_on_outlined,
                      'Location', onTap: () {
                    Navigator.pop(context);
                    _showLocationSheet();
                  }),
                ],
              ),
              const SizedBox(height: 4),
              // Grid row 2 — Article + Contact + Music
              Row(
                children: [
                  _attachTile(theme, Icons.article_outlined, 'Article',
                      onTap: () {
                    Navigator.pop(context);
                  }),
                  _attachTile(theme, Icons.person_outline, 'Contact',
                      onTap: () {
                    Navigator.pop(context);
                    _openShareContactSheet();
                  }),
                  _attachTile(theme, Icons.music_note_outlined, 'Music',
                      onTap: () {
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
      {required VoidCallback onTap}) {
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
                      color: theme.colorScheme.onSurface,
                      fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  // ── Gallery picker — shows recent media grid (image 1) ────────────────
  void _showGalleryPicker() {
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
              // Header with camera button
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
                      _pickMultipleImages();
                    },
                    child: Container(
                      color: Colors.white10,
                      child: const Icon(Icons.image,
                          color: Colors.white24, size: 40),
                    ),
                  ),
                ),
              ),
              // Bottom action bar
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
                color: const Color(0xFF242F3D),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _galleryBottomBtn(Icons.photo_library,
                        'Gallery', active: true),
                    _galleryBottomBtn(Icons.folder, 'File'),
                    _galleryBottomBtn(Icons.location_on, 'Location'),
                    _galleryBottomBtn(Icons.article, 'Article'),
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

  void _showLocationSheet() {
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
            ListTile(
              leading:
                  Icon(Icons.my_location, color: theme.colorScheme.primary),
              title: const Text('Send current location'),
              onTap: () => _shareLocation(),
            ),
            ListTile(
              leading: Icon(Icons.location_searching,
                  color: theme.colorScheme.primary),
              title: const Text('Share live location'),
              subtitle: const Text('15 minutes'),
              onTap: () => _startLiveLocation(),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // HELPERS
  // ═══════════════════════════════════════════════════════════════════════
  String _fmtDuration(int s) {
    final m = (s ~/ 60).toString().padLeft(2, '0');
    final sec = (s % 60).toString().padLeft(2, '0');
    return '$m:$sec';
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// MESSAGE OPTIONS OVERLAY — matches image 2 (horizontal reactions + vertical menu)
// ═══════════════════════════════════════════════════════════════════════════
class _MessageOptionsOverlay extends StatelessWidget {
  final Map<String, dynamic> message;
  final bool isMe;
  final bool isDeleted;
  final bool isText;
  final bool isEdited;
  final bool canForward;
  final void Function(String emoji) onReact;
  final VoidCallback onEdit;
  final VoidCallback onEditHistory;
  final VoidCallback onCopy;
  final VoidCallback onReply;
  final VoidCallback onForward;
  final VoidCallback onPin;
  final VoidCallback onSave;
  final VoidCallback onDownload;
  final VoidCallback onSelect;
  final VoidCallback onReport;
  final VoidCallback onDeleteEveryone;
  final VoidCallback onDeleteMe;

  const _MessageOptionsOverlay({
    required this.message,
    required this.isMe,
    required this.isDeleted,
    required this.isText,
    required this.isEdited,
    required this.canForward,
    required this.onReact,
    required this.onEdit,
    required this.onEditHistory,
    required this.onCopy,
    required this.onReply,
    required this.onForward,
    required this.onPin,
    required this.onSave,
    required this.onDownload,
    required this.onSelect,
    required this.onReport,
    required this.onDeleteEveryone,
    required this.onDeleteMe,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final bg = const Color(0xFF17212B);

    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          // Dim background
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(color: Colors.black.withOpacity(0.4)),
            ),
          ),

          // Floating reaction row + menu near center
          Positioned(
            left: 16,
            right: 16,
            top: size.height * 0.28,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Reaction row
                if (!isDeleted)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 8),
                    decoration: BoxDecoration(
                      color: bg,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        for (final e
                            in const ['👍', '❤️', '😂', '😍', '😢', '👆', '😁'])
                          GestureDetector(
                            onTap: () => onReact(e),
                            child: Text(e,
                                style: const TextStyle(fontSize: 26)),
                          ),
                        Container(
                          width: 34,
                          height: 34,
                          decoration: const BoxDecoration(
                            color: Colors.white24,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.keyboard_arrow_down,
                              color: Colors.white70, size: 20),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),

                // Vertical menu
                Container(
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isEdited && !isDeleted)
                        _tile(Icons.access_time, 'edited at ${_timeOf(message)}',
                            onEditHistory),
                      _tile(Icons.reply, 'Reply', onReply),
                      if (isText && !isDeleted)
                        _tile(Icons.copy, 'Copy', onCopy),
                      _tile(Icons.label_outline, 'Add to GIFs', () {}),
                      if (message['media_url'] != null)
                        _tile(Icons.download_outlined,
                            'Save to Downloads', onDownload),
                      _tile(Icons.share, 'Share', () {}),
                      if (canForward)
                        _tile(Icons.forward, 'Forward', onForward),
                      _tile(Icons.push_pin_outlined, 'Pin', onPin),
                      if (isMe && isText && !isDeleted)
                        _tile(Icons.edit_outlined, 'Edit', onEdit),
                      _tile(Icons.delete_outline, 'Delete', () {
                        if (isMe) {
                          onDeleteEveryone();
                        } else {
                          onDeleteMe();
                        }
                      }),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _timeOf(Map<String, dynamic> m) {
    final t = m['updated_at'];
    if (t is Timestamp) {
      final d = t.toDate();
      return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }
    return '';
  }

  Widget _tile(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: Colors.white70, size: 22),
            const SizedBox(width: 20),
            Text(label,
                style: const TextStyle(color: Colors.white, fontSize: 15)),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// WALLPAPER LAYER
// ═══════════════════════════════════════════════════════════════════════════
class _WallpaperLayer extends StatelessWidget {
  final String? url;
  const _WallpaperLayer({this.url});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (url == null || url!.isEmpty) {
      return Container(
        color: theme.brightness == Brightness.dark
            ? const Color(0xFF0E1621)
            : const Color(0xFFE7EBF0),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        CachedNetworkImage(
          imageUrl: url!,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => Container(
            color: theme.brightness == Brightness.dark
                ? const Color(0xFF0E1621)
                : const Color(0xFFE7EBF0),
          ),
        ),
        Container(
          color: Colors.black.withOpacity(
              theme.brightness == Brightness.dark ? 0.35 : 0.1),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// EMPTY STATE
// ═══════════════════════════════════════════════════════════════════════════
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chat_bubble_outline,
              size: 80,
              color: theme.colorScheme.onSurface.withOpacity(0.1)),
          const SizedBox(height: 16),
          Text('No messages yet',
              style: TextStyle(
                  color:
                      theme.colorScheme.onSurface.withOpacity(0.4))),
        ],
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
// INVITE / SLUG DETECTORS
// ═══════════════════════════════════════════════════════════════════════════
class _InviteLinkDetector {
  static final _re = RegExp(
    r'https?://([a-z0-9-]+\.web\.app)/join/([A-Za-z0-9_-]{2,60})',
    caseSensitive: false,
  );
  static String? detect(String text) {
    if (text.isEmpty) return null;
    final m = _re.firstMatch(text);
    return m?.group(2);
  }

  static bool isInvite(String url) => _re.hasMatch(url);
}

class _AuraShortLink {
  static final _re = RegExp(
    r'https?://[a-z0-9-]+\.web\.app/(?!join/)([A-Za-z0-9_-]{2,60})/?$',
    caseSensitive: false,
  );
  static String? detect(String text) {
    if (text.isEmpty) return null;
    final m = _re.firstMatch(text.trim());
    return m?.group(1);
  }

  static bool isShortLink(String url) => _re.hasMatch(url.trim());
}

class _InviteCard extends StatefulWidget {
  final String code;
  final VoidCallback onJoined;
  const _InviteCard({required this.code, required this.onJoined});

  @override
  State<_InviteCard> createState() => _InviteCardState();
}

class _InviteCardState extends State<_InviteCard> {
  Map<String, dynamic>? _info;
  String? _inviteDocId;
  bool _loading = true;
  bool _joining = false;
  bool _already = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final q = await FirebaseFirestore.instance
          .collection('invitations')
          .where('code', isEqualTo: widget.code)
          .where('is_active', isEqualTo: true)
          .limit(1)
          .get();
      if (q.docs.isEmpty) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      _inviteDocId = q.docs.first.id;
      final inv = q.docs.first.data();
      final chatId = inv['chat_id'] as String?;
      if (chatId == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final chat = await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatId)
          .get();
      if (!chat.exists) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final d = chat.data()!;
      final auth = Provider.of<LumaAuthProvider>(context, listen: false);
      final uid = auth.user?.uid ?? auth.mockUserId;
      final parts = List<String>.from(d['participants'] ?? []);
      if (!mounted) return;
      setState(() {
        _info = {
          'chat_id': chatId,
          'name': d['name'] ?? 'Chat',
          'avatar_url': d['avatar_url'],
          'type': d['type'] ?? 'group',
          'member_count': parts.length,
        };
        _already = uid != null && parts.contains(uid);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _join() async {
    if (_info == null) return;
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    final uid = auth.user?.uid ?? auth.mockUserId;
    final name = auth.displayName ?? auth.userName ?? 'User';
    if (uid == null) return;
    setState(() => _joining = true);
    final res = await InvitationService.joinWithInvitation(
      invitationId: _inviteDocId ?? widget.code,
      userId: uid,
      userName: name,
    );
    if (!mounted) return;
    setState(() => _joining = false);
    if (res['success'] == true) {
      widget.onJoined();
      Navigator.pushNamed(context, '/chat', arguments: {
        'chatId': res['chat_id'] ?? _info!['chat_id'],
        'chatName': res['chat_name'] ?? _info!['name'],
        'isGroup': (res['chat_type'] ?? 'group') == 'group',
        'isChannel': (res['chat_type'] ?? 'group') == 'channel',
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return Container(
        margin: const EdgeInsets.only(top: 8),
        width: 260,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.onSurface.withOpacity(0.04),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(children: [
          SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: theme.colorScheme.primary)),
          const SizedBox(width: 10),
          Text('Loading invite...',
              style: TextStyle(
                  color: theme.colorScheme.onSurface.withOpacity(0.55),
                  fontSize: 12)),
        ]),
      );
    }
    if (_info == null) {
      return Container(
        margin: const EdgeInsets.only(top: 8),
        width: 240,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.error.withOpacity(0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: theme.colorScheme.error.withOpacity(0.2)),
        ),
        child: Row(children: [
          Icon(Icons.link_off, color: theme.colorScheme.error, size: 16),
          const SizedBox(width: 8),
          Text('Invalid or expired link',
              style:
                  TextStyle(color: theme.colorScheme.error, fontSize: 12)),
        ]),
      );
    }
    final name = (_info!['name'] ?? 'Chat').toString();
    final avatar = _info!['avatar_url'] as String?;
    final type = (_info!['type'] ?? 'group').toString();
    final members = _info!['member_count'] ?? 0;

    return GestureDetector(
      onTap: _already ? null : _join,
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        width: 260,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withOpacity(0.1),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: theme.colorScheme.primary.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.primary.withOpacity(0.2),
              ),
              child: avatar != null && avatar.isNotEmpty
                  ? ClipOval(
                      child: CachedNetworkImage(
                          imageUrl: avatar, fit: BoxFit.cover))
                  : Center(
                      child: Text(
                        name.isNotEmpty ? name[0].toUpperCase() : '?',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 20),
                      ),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    Icon(
                        type == 'channel' ? Icons.campaign : Icons.group,
                        size: 12,
                        color: theme.colorScheme.primary),
                    const SizedBox(width: 4),
                    Text(
                      type == 'channel' ? 'CHANNEL' : 'GROUP',
                      style: TextStyle(
                          color: theme.colorScheme.primary,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.6),
                    ),
                  ]),
                  const SizedBox(height: 2),
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    '$members member${members == 1 ? '' : 's'}',
                    style: TextStyle(
                        color: theme.colorScheme.onSurface
                            .withOpacity(0.5),
                        fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            _joining
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.primary))
                : Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: _already
                          ? theme.colorScheme.onSurface.withOpacity(0.1)
                          : theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      _already ? 'Open' : 'Join',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SLUG CARD
// ═══════════════════════════════════════════════════════════════════════════
class _SlugCard extends StatefulWidget {
  final String slug;
  final VoidCallback onMessage;
  const _SlugCard({required this.slug, required this.onMessage});

  @override
  State<_SlugCard> createState() => _SlugCardState();
}

class _SlugCardState extends State<_SlugCard> {
  Map<String, dynamic>? _info;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    try {
      final sd = await FirebaseFirestore.instance
          .collection('slugs')
          .doc(widget.slug)
          .get();
      if (!sd.exists) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final d = sd.data()!;
      final type = d['type'] as String?;
      if (type == 'group' || type == 'channel') {
        final cd = await FirebaseFirestore.instance
            .collection('chats')
            .doc(d['chat_id'])
            .get();
        if (!cd.exists) {
          if (mounted) setState(() => _loading = false);
          return;
        }
        final c = cd.data()!;
        final parts = List<String>.from(c['participants'] ?? []);
        final auth = Provider.of<LumaAuthProvider>(context, listen: false);
        final uid = auth.user?.uid ?? auth.mockUserId;
        if (!mounted) return;
        setState(() {
          _info = {
            'kind': type,
            'id': d['chat_id'],
            'name': c['name'] ?? 'Chat',
            'avatar': c['avatar_url'],
            'members': parts.length,
            'already': uid != null && parts.contains(uid),
          };
          _loading = false;
        });
      } else if (type == 'user') {
        final ud = await FirebaseFirestore.instance
            .collection('users')
            .doc(d['user_id'])
            .get();
        if (!ud.exists) {
          if (mounted) setState(() => _loading = false);
          return;
        }
        final u = ud.data()!;
        if (!mounted) return;
        setState(() {
          _info = {
            'kind': 'user',
            'id': d['user_id'],
            'name': u['display_name'] ?? u['username'] ?? 'User',
            'username': u['username'],
            'avatar': u['avatar_url'],
            'verified':
                (u['email'] ?? '').toString().endsWith('@gmail.com'),
          };
          _loading = false;
        });
      } else {
        if (mounted) setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _joinGroup() async {
    if (_info == null || _info!['kind'] == 'user') return;
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    final uid = auth.user?.uid ?? auth.mockUserId;
    if (uid == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_info!['id'])
          .update({
        'participants': FieldValue.arrayUnion([uid]),
        'unread_counts.$uid': 0,
        'last_message_at': FieldValue.serverTimestamp(),
      });
      if (!mounted) return;
      Navigator.pushNamed(context, '/chat', arguments: {
        'chatId': _info!['id'],
        'chatName': _info!['name'],
        'isGroup': _info!['kind'] == 'group',
        'isChannel': _info!['kind'] == 'channel',
      });
    } catch (_) {}
  }

  Future<void> _openDirect() async {
    if (_info == null || _info!['kind'] != 'user') return;
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    final uid = auth.user?.uid ?? auth.mockUserId;
    if (uid == null) return;
    final snap = await FirebaseFirestore.instance
        .collection('chats')
        .where('participants', arrayContains: uid)
        .where('type', isEqualTo: 'direct')
        .get();
    for (final d in snap.docs) {
      if ((d.data()['participants'] as List).contains(_info!['id'])) {
        if (!mounted) return;
        Navigator.pushNamed(context, '/chat', arguments: {
          'chatId': d.id,
          'chatName': _info!['name'],
        });
        return;
      }
    }
    final ref = FirebaseFirestore.instance.collection('chats').doc();
    await ref.set({
      'id': ref.id,
      'type': 'direct',
      'participants': [uid, _info!['id']],
      'unread_counts': {uid: 0, _info!['id']: 0},
      'last_message': '',
      'last_message_at': FieldValue.serverTimestamp(),
      'created_at': FieldValue.serverTimestamp(),
    });
    if (!mounted) return;
    Navigator.pushNamed(context, '/chat', arguments: {
      'chatId': ref.id,
      'chatName': _info!['name'],
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return Container(
        margin: const EdgeInsets.only(top: 8),
        width: 260,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.onSurface.withOpacity(0.04),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(children: [
          SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: theme.colorScheme.primary)),
          const SizedBox(width: 10),
          Text('Loading...',
              style: TextStyle(
                  color: theme.colorScheme.onSurface.withOpacity(0.55),
                  fontSize: 12)),
        ]),
      );
    }
    if (_info == null) return const SizedBox.shrink();

    final isUser = _info!['kind'] == 'user';
    final already = _info!['already'] == true;
    final name = (_info!['name'] ?? '').toString();
    final avatar = _info!['avatar'] as String?;
    final verified = _info!['verified'] == true;

    return GestureDetector(
      onTap: isUser
          ? _openDirect
          : (already
              ? () => Navigator.pushNamed(context, '/chat', arguments: {
                    'chatId': _info!['id'],
                    'chatName': name,
                  })
              : _joinGroup),
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        width: 280,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withOpacity(0.1),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: theme.colorScheme.primary.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.primary.withOpacity(0.2),
              ),
              child: avatar != null && avatar.isNotEmpty
                  ? ClipOval(
                      child: CachedNetworkImage(
                          imageUrl: avatar, fit: BoxFit.cover))
                  : Center(
                      child: Text(
                        name.isNotEmpty ? name[0].toUpperCase() : '?',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 20),
                      ),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    Icon(
                        isUser
                            ? Icons.person
                            : _info!['kind'] == 'channel'
                                ? Icons.campaign
                                : Icons.group,
                        size: 12,
                        color: theme.colorScheme.primary),
                    const SizedBox(width: 4),
                    Text(
                      isUser
                          ? 'USER'
                          : _info!['kind'] == 'channel'
                              ? 'CHANNEL'
                              : 'GROUP',
                      style: TextStyle(
                          color: theme.colorScheme.primary,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.6),
                    ),
                  ]),
                  const SizedBox(height: 2),
                  Row(children: [
                    Flexible(
                      child: Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                    ),
                    if (verified) ...[
                      const SizedBox(width: 4),
                      const Icon(Icons.verified,
                          color: Color(0xFF3390EC), size: 12),
                    ],
                  ]),
                  Text(
                    isUser
                        ? '@${_info!['username']}'
                        : '${_info!['members']} member${_info!['members'] == 1 ? '' : 's'}',
                    style: TextStyle(
                        color: theme.colorScheme.onSurface
                            .withOpacity(0.5),
                        fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: already || isUser
                    ? theme.colorScheme.onSurface.withOpacity(0.1)
                    : theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                isUser ? 'Message' : (already ? 'Open' : 'Join'),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// LINK PREVIEW BUBBLE
// ═══════════════════════════════════════════════════════════════════════════
class _LinkPreviewBubble extends StatelessWidget {
  final Map<String, dynamic> preview;
  final VoidCallback onTap;
  const _LinkPreviewBubble({required this.preview, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final image = preview['image'] as String?;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(top: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border(
              left: BorderSide(
                  color: theme.colorScheme.primary, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (image != null && image.isNotEmpty)
              ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(8)),
                child: CachedNetworkImage(
                  imageUrl: image,
                  height: 140,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if ((preview['domain'] ?? '').toString().isNotEmpty)
                    Text(
                      (preview['domain']).toString().toUpperCase(),
                      style: TextStyle(
                          color: theme.colorScheme.primary,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5),
                    ),
                  if ((preview['title'] ?? '').toString().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        (preview['title']).toString(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  if ((preview['description'] ?? '')
                      .toString()
                      .isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        (preview['description']).toString(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: theme.colorScheme.onSurface
                                .withOpacity(0.55),
                            fontSize: 12),
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
}

// ═══════════════════════════════════════════════════════════════════════════
// VIEW ONCE VIEWER
// ═══════════════════════════════════════════════════════════════════════════
class _ViewOnceViewer extends StatefulWidget {
  final String url;
  final bool isVideo;
  final VoidCallback onExpired;
  const _ViewOnceViewer({
    required this.url,
    required this.isVideo,
    required this.onExpired,
  });

  @override
  State<_ViewOnceViewer> createState() => _ViewOnceViewerState();
}

class _ViewOnceViewerState extends State<_ViewOnceViewer> {
  int _remaining = 5;
  Timer? _t;
  VideoPlayerController? _vc;

  @override
  void initState() {
    super.initState();
    if (widget.isVideo) {
      _vc = VideoPlayerController.networkUrl(Uri.parse(widget.url))
        ..initialize().then((_) {
          if (mounted) {
            setState(() {});
            _vc!.play();
          }
        });
    }
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _remaining--);
      if (_remaining <= 0) {
        _t?.cancel();
        widget.onExpired();
      }
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    _vc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: EdgeInsets.zero,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: widget.isVideo
                ? (_vc?.value.isInitialized == true
                    ? AspectRatio(
                        aspectRatio: _vc!.value.aspectRatio,
                        child: VideoPlayer(_vc!))
                    : const CircularProgressIndicator(
                        color: Color(0xFF3390EC)))
                : PhotoView(
                    imageProvider: CachedNetworkImageProvider(widget.url),
                    minScale: PhotoViewComputedScale.contained,
                    maxScale: PhotoViewComputedScale.covered * 2,
                  ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            left: 12,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.9),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('$_remaining',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 14)),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            right: 12,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () {
                _t?.cancel();
                Navigator.pop(context);
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// EFFECT BURST (confetti on emoji)
// ═══════════════════════════════════════════════════════════════════════════
class _EffectBurst {
  static const _styleMap = <String, String>{
    '🎉': 'confetti',
    '🎊': 'confetti',
    '❤️': 'hearts',
    '💖': 'hearts',
    '💗': 'hearts',
    '🎆': 'fireworks',
    '🎇': 'fireworks',
    '💥': 'explosion',
    '💣': 'explosion',
    '✨': 'sparkles',
    '🌟': 'sparkles',
    '⭐': 'sparkles',
  };
  static bool isTrigger(String s) => _styleMap.containsKey(s.trim());

  static void fire(BuildContext context, String emoji) {
    final style = _styleMap[emoji.trim()] ?? 'confetti';
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) =>
          _EffectLayer(style: style, onDone: () => entry.remove()),
    );
    overlay.insert(entry);
  }
}

class _EffectLayer extends StatefulWidget {
  final String style;
  final VoidCallback onDone;
  const _EffectLayer({required this.style, required this.onDone});

  @override
  State<_EffectLayer> createState() => _EffectLayerState();
}

class _EffectLayerState extends State<_EffectLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(seconds: 3));
  late final List<_Particle> _particles;

  @override
  void initState() {
    super.initState();
    final rnd = math.Random();
    final palette = {
          'confetti': ['🎉', '🎊', '🎈', '✨', '🎁'],
          'hearts': ['❤️', '💖', '💗', '💓', '💕', '💘', '🧡'],
          'fireworks': ['🎆', '🎇', '✨', '💫', '🌟'],
          'explosion': ['💥', '💣'],
          'sparkles': ['✨', '🌟', '⭐', '💫'],
        }[widget.style] ??
        ['✨'];
    final count = {
          'confetti': 40,
          'hearts': 30,
          'fireworks': 24,
          'explosion': 6,
          'sparkles': 30,
        }[widget.style] ??
        24;
    _particles = List.generate(count, (_) {
      return _Particle(
        emoji: palette[rnd.nextInt(palette.length)],
        dx: rnd.nextDouble(),
        angle: rnd.nextDouble() * math.pi * 2,
        dist: 100 + rnd.nextDouble() * 160,
        size: 28 + rnd.nextDouble() * 24,
        delay: rnd.nextDouble() * 0.3,
      );
    });
    _c.forward().whenComplete(widget.onDone);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          return Stack(
            children: _particles.map((p) {
              final t =
                  ((_c.value - p.delay) / (1 - p.delay)).clamp(0.0, 1.0);
              double x;
              double y;
              if (widget.style == 'hearts') {
                x = p.dx * size.width;
                y = size.height - (size.height + 60) * t;
              } else if (widget.style == 'fireworks' ||
                  widget.style == 'explosion') {
                x = size.width / 2 + math.cos(p.angle) * p.dist * t;
                y = size.height / 2 + math.sin(p.angle) * p.dist * t;
              } else if (widget.style == 'sparkles') {
                x = p.dx * size.width;
                y = (0.2 + p.dx * 0.6) * size.height;
              } else {
                x = p.dx * size.width;
                y = (size.height + 60) * t - 60;
              }
              return Positioned(
                left: x,
                top: y,
                child: Opacity(
                  opacity: (1 - t).clamp(0.0, 1.0),
                  child: Transform.rotate(
                    angle: t * 4 * math.pi,
                    child: Transform.scale(
                      scale: 0.6 + 0.6 * t,
                      child:
                          Text(p.emoji, style: TextStyle(fontSize: p.size)),
                    ),
                  ),
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }
}

class _Particle {
  final String emoji;
  final double dx;
  final double angle;
  final double dist;
  final double size;
  final double delay;
  _Particle({
    required this.emoji,
    required this.dx,
    required this.angle,
    required this.dist,
    required this.size,
    required this.delay,
  });
}

// ═══════════════════════════════════════════════════════════════════════════
// BIG EMOJI
// ═══════════════════════════════════════════════════════════════════════════
class _EmojiOnly extends StatefulWidget {
  final String emoji;
  const _EmojiOnly({required this.emoji});

  @override
  State<_EmojiOnly> createState() => _EmojiOnlyState();
}

class _EmojiOnlyState extends State<_EmojiOnly>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(seconds: 2))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final t = _c.value;
        final scale = 1 + 0.1 * math.sin(t * math.pi * 2);
        return Transform.scale(
          scale: scale,
          child: Text(widget.emoji, style: const TextStyle(fontSize: 72)),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// MESSAGE BUBBLE — Telegram style with tail
// ═══════════════════════════════════════════════════════════════════════════
class _MessageBubble extends StatefulWidget {
  final Map<String, dynamic> message;
  final bool isMine;
  final bool showAvatar;
  final bool grouped;
  final bool selected;
  final bool multiSelect;
  final Map<String, Map<String, dynamic>> userCache;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDoubleTap;
  final VoidCallback onReply;
  final String? playingAudioId;
  final Duration audioPosition;
  final Duration audioDuration;
  final void Function(String id, String url) onPlayAudio;
  final void Function(String url) onOpenImage;
  final void Function(String url, String? fileName) onOpenFile;
  final void Function(double lat, double lng) onOpenLocation;
  final Map<String, VideoPlayerController> videoControllers;
  final VoidCallback onVideoInit;
  final void Function(String uid, String name, String? avatar) onOpenProfile;

  const _MessageBubble({
    required this.message,
    required this.isMine,
    required this.showAvatar,
    required this.grouped,
    required this.selected,
    required this.multiSelect,
    required this.userCache,
    required this.onTap,
    required this.onLongPress,
    required this.onDoubleTap,
    required this.onReply,
    required this.playingAudioId,
    required this.audioPosition,
    required this.audioDuration,
    required this.onPlayAudio,
    required this.onOpenImage,
    required this.onOpenFile,
    required this.onOpenLocation,
    required this.videoControllers,
    required this.onVideoInit,
    required this.onOpenProfile,
  });

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  double _dragOffset = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = widget.message;
    final isMine = widget.isMine;
    final type = message['media_type'] ?? 'text';
    final isDeleted = message['deleted_for_everyone'] == true;
    final isSticker = type == 'sticker';
    final text = (message['text'] ?? message['content'] ?? '').toString();
    final mediaUrl = message['media_url'] as String?;
    final sticker = message['sticker'] as Map<String, dynamic>?;
    final reactions = Map<String, dynamic>.from(message['reactions'] ?? {});
    final images = message['images'] as List?;
    final hasAlbum = images != null && images.length > 1;
    final singleEmoji = !hasAlbum && _isSingleEmoji(text);
    final linkPreview = message['link_preview'] as Map<String, dynamic>?;
    final inviteCode = _InviteLinkDetector.detect(text);
    final slug = inviteCode == null ? _AuraShortLink.detect(text) : null;
    final isViewOnce = message['view_once'] == true;

    final isDark = theme.brightness == Brightness.dark;
    final mineBubble =
        isDark ? const Color(0xFF2B5278) : const Color(0xFFEFFDDE);
    final otherBubble =
        isDark ? const Color(0xFF182533) : Colors.white;
    final mineText = isDark ? Colors.white : Colors.black;
    final otherText = isDark ? Colors.white : Colors.black;

    final borderRadius = BorderRadius.only(
      topLeft: const Radius.circular(14),
      topRight: const Radius.circular(14),
      bottomLeft: Radius.circular(isMine ? 14 : 4),
      bottomRight: Radius.circular(isMine ? 4 : 14),
    );

    return Padding(
      padding: EdgeInsets.only(
        bottom: reactions.isNotEmpty ? 18 : (widget.grouped ? 2 : 8),
        top: widget.grouped ? 2 : 4,
        left: isMine ? 40 : 0,
        right: isMine ? 0 : 40,
      ),
      child: Row(
        mainAxisAlignment:
            isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMine && widget.showAvatar) _messageAvatar(theme),
          if (!isMine && !widget.showAvatar && !widget.grouped)
            const SizedBox(width: 32),
          Flexible(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                GestureDetector(
                  onTap: widget.onTap,
                  onLongPress: widget.onLongPress,
                  onDoubleTap: widget.onDoubleTap,
                  onHorizontalDragUpdate: (d) {
                    setState(() {
                      _dragOffset += d.delta.dx * (isMine ? -1 : 1);
                      _dragOffset = _dragOffset.clamp(0, 80);
                    });
                  },
                  onHorizontalDragEnd: (_) {
                    if (_dragOffset > 40) widget.onReply();
                    setState(() => _dragOffset = 0);
                  },
                  onHorizontalDragCancel: () {
                    setState(() => _dragOffset = 0);
                  },
                  child: Transform.translate(
                    offset: Offset(isMine ? -_dragOffset : _dragOffset, 0),
                    child: Container(
                      padding: isSticker
                          ? EdgeInsets.zero
                          : (singleEmoji
                              ? EdgeInsets.zero
                              : (type == 'text'
                                  ? const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 6)
                                  : const EdgeInsets.all(4))),
                      decoration: BoxDecoration(
                        color: isSticker || singleEmoji
                            ? Colors.transparent
                            : (isMine ? mineBubble : otherBubble),
                        borderRadius: borderRadius,
                        boxShadow: (isMine || otherBubble == Colors.white)
                            ? [
                                BoxShadow(
                                  color: Colors.black
                                      .withOpacity(isDark ? 0.2 : 0.05),
                                  blurRadius: 2,
                                  offset: const Offset(0, 1),
                                ),
                              ]
                            : null,
                        border: widget.selected
                            ? Border.all(
                                color: theme.colorScheme.primary, width: 2)
                            : null,
                      ),
                      constraints: BoxConstraints(
                        maxWidth:
                            MediaQuery.of(context).size.width * 0.78,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (message['is_forwarded'] == true)
                            Padding(
                              padding: const EdgeInsets.only(
                                  bottom: 4, left: 4, right: 4, top: 2),
                              child: Row(
                                children: [
                                  Icon(Icons.forward,
                                      size: 11,
                                      color: theme.colorScheme.primary),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Forwarded',
                                    style: TextStyle(
                                      color: theme.colorScheme.primary,
                                      fontSize: 10,
                                      fontStyle: FontStyle.italic,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (message['reply_to'] != null)
                            Container(
                              margin: const EdgeInsets.only(
                                  bottom: 6, left: 4, right: 4, top: 4),
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: (isMine ? mineBubble : otherBubble)
                                    .withOpacity(0.5),
                                borderRadius: BorderRadius.circular(8),
                                border: Border(
                                  left: BorderSide(
                                      color: theme.colorScheme.primary,
                                      width: 3),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    (message['reply_to_sender'] ?? 'Unknown')
                                        .toString(),
                                    style: TextStyle(
                                        color: theme.colorScheme.primary,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    (message['reply_to_content'] ?? '')
                                        .toString(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: (isMine ? mineText : otherText)
                                            .withOpacity(0.7),
                                        fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          if (isDeleted)
                            Padding(
                              padding: const EdgeInsets.all(4),
                              child: Text(
                                'This message was deleted',
                                style: TextStyle(
                                    color: (isMine ? mineText : otherText)
                                        .withOpacity(0.5),
                                    fontStyle: FontStyle.italic,
                                    fontSize: 13),
                              ),
                            )
                          else if (isSticker)
                            _stickerBubble(sticker)
                          else if (singleEmoji)
                            _EmojiOnly(emoji: text.trim())
                          else if (hasAlbum)
                            _albumBubble(images)
                          else if (type == 'image' && mediaUrl != null)
                            _imageBubble(mediaUrl, isViewOnce: isViewOnce)
                          else if (type == 'video' && mediaUrl != null)
                            _videoBubble(mediaUrl, isViewOnce: isViewOnce)
                          else if (type == 'audio' && mediaUrl != null)
                            _audioBubble(mediaUrl, isMine: isMine)
                          else if (type == 'gif' && mediaUrl != null)
                            _gifBubble(mediaUrl)
                          else if (type == 'file' && mediaUrl != null)
                            _fileBubble(mediaUrl)
                          else if (type == 'location')
                            _locationBubble(theme)
                          else if (type == 'contact')
                            _contactBubble(theme)
                          else
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                RichText(
                                  text: TextSpan(
                                    children: _Linkify.parse(
                                      text,
                                      isMine: isMine,
                                      onOpenUrl: (url) => launchUrl(
                                          Uri.parse(url),
                                          mode: LaunchMode
                                              .externalApplication),
                                      onMention: (_) {},
                                    ),
                                  ),
                                ),
                                if (inviteCode != null)
                                  _InviteCard(
                                      code: inviteCode,
                                      onJoined: () {}),
                                if (slug != null)
                                  _SlugCard(
                                      slug: slug, onMessage: () {}),
                                if (linkPreview != null &&
                                    linkPreview.isNotEmpty)
                                  _LinkPreviewBubble(
                                    preview: linkPreview,
                                    onTap: () {
                                      final u =
                                          linkPreview['url'] as String?;
                                      if (u != null) {
                                        launchUrl(Uri.parse(u),
                                            mode: LaunchMode
                                                .externalApplication);
                                      }
                                    },
                                  ),
                              ],
                            ),
                          if (!isSticker && !singleEmoji) ...[
                            const SizedBox(height: 2),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                if (message['is_edited'] == true)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: Text(
                                      'edited',
                                      style: TextStyle(
                                          fontSize: 10,
                                          fontStyle: FontStyle.italic,
                                          color:
                                              (isMine ? mineText : otherText)
                                                  .withOpacity(0.55)),
                                    ),
                                  ),
                                Text(
                                  _fmtTime(message['created_at']),
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: (isMine ? mineText : otherText)
                                        .withOpacity(0.55),
                                  ),
                                ),
                                if (isMine) ...[
                                  const SizedBox(width: 4),
                                  Icon(
                                    message['is_read'] == true
                                        ? Icons.done_all
                                        : Icons.done,
                                    size: 14,
                                    color: message['is_read'] == true
                                        ? const Color(0xFF4FC3F7)
                                        : mineText.withOpacity(0.55),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                if (reactions.isNotEmpty)
                  Positioned(
                    bottom: -14,
                    right: isMine ? null : 8,
                    left: isMine ? 8 : null,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                        color: theme.brightness == Brightness.dark
                            ? const Color(0xFF1F1F1F)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border:
                            Border.all(color: theme.dividerColor),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: reactions.entries.take(5).map((e) {
                          final cnt = (e.value as List).length;
                          return Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 2),
                            child: Text(
                              '${e.key}${cnt > 1 ? ' $cnt' : ''}',
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
        ],
      ),
    );
  }

  Widget _messageAvatar(ThemeData theme) {
    final u = widget.userCache[widget.message['sender_id']];
    final name = (u?['display_name'] ?? 'U').toString();
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: () => widget.onOpenProfile(
          widget.message['sender_id'],
          name,
          u?['avatar_url'],
        ),
        child: CircleAvatar(
          radius: 16,
          backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
          backgroundImage: u?['avatar_url'] != null
              ? CachedNetworkImageProvider(u!['avatar_url'])
              : null,
          child: u?['avatar_url'] == null
              ? Text(name[0].toUpperCase(),
                  style: TextStyle(
                      color: theme.colorScheme.primary, fontSize: 12))
              : null,
        ),
      ),
    );
  }

  Widget _stickerBubble(Map<String, dynamic>? sticker) {
    if (sticker == null) return const SizedBox.shrink();
    final url = sticker['url'] as String;
    final type = sticker['sticker_type'] ?? 'static';
    return SizedBox(
      width: 160,
      height: 160,
      child: type == 'video'
          ? _StickerVideoPreview(url: url)
          : CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.contain,
              memCacheWidth: 400,
            ),
    );
  }

  Widget _imageBubble(String url, {required bool isViewOnce}) {
    return Stack(
      children: [
        GestureDetector(
          onTap: () => widget.onOpenImage(url),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(maxWidth: 260, maxHeight: 320),
              child: CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(
                  width: 200,
                  height: 200,
                  color: Colors.black.withOpacity(0.05),
                  child: const Center(
                    child: CircularProgressIndicator(
                        color: Color(0xFF3390EC), strokeWidth: 2),
                  ),
                ),
                errorWidget: (_, __, ___) => Container(
                  width: 200,
                  height: 200,
                  color: Colors.black.withOpacity(0.05),
                  child: const Icon(Icons.broken_image, size: 32),
                ),
              ),
            ),
          ),
        ),
        if (isViewOnce)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.local_fire_department,
                      size: 11, color: Colors.orange),
                  SizedBox(width: 4),
                  Text('View once',
                      style: TextStyle(color: Colors.white, fontSize: 10)),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _albumBubble(List images) {
    final n = images.length;
    final cls = n == 2 ? 2 : n == 3 ? 3 : n == 4 ? 4 : 5;
    return GestureDetector(
      onTap: () => widget.onOpenImage(
          (images[0] is Map ? images[0]['url'] : images[0]).toString()),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 300,
          height: cls == 3 ? 200 : cls == 2 ? 150 : 200,
          child: _albumLayout(images, cls),
        ),
      ),
    );
  }

  Widget _albumLayout(List images, int cls) {
    String urlOf(dynamic i) => (i is Map ? i['url'] : i).toString();
    final max = math.min(images.length, cls);
    if (cls == 2) {
      return Row(children: [
        Expanded(child: _albImg(urlOf(images[0]))),
        const SizedBox(width: 2),
        Expanded(child: _albImg(urlOf(images[1]))),
      ]);
    }
    if (cls == 3) {
      return Row(children: [
        Expanded(flex: 2, child: _albImg(urlOf(images[0]))),
        const SizedBox(width: 2),
        Expanded(
          child: Column(children: [
            Expanded(child: _albImg(urlOf(images[1]))),
            const SizedBox(height: 2),
            Expanded(child: _albImg(urlOf(images[2]))),
          ]),
        ),
      ]);
    }
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2, mainAxisSpacing: 2, crossAxisSpacing: 2),
      itemCount: max,
      itemBuilder: (_, i) {
        final showMore = i == 4 && images.length > 5;
        return Stack(
          fit: StackFit.expand,
          children: [
            _albImg(urlOf(images[i])),
            if (showMore)
              Container(
                color: Colors.black54,
                alignment: Alignment.center,
                child: Text('+${images.length - 5}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700)),
              ),
          ],
        );
      },
    );
  }

  Widget _albImg(String url) => CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        memCacheWidth: 400,
      );

  Widget _videoBubble(String url, {required bool isViewOnce}) {
    final controller = widget.videoControllers.putIfAbsent(url, () {
      final c = VideoPlayerController.networkUrl(Uri.parse(url));
      c.initialize().then((_) => widget.onVideoInit());
      return c;
    });
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: 240,
            height: 180,
            color: Colors.black,
            child: controller.value.isInitialized
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      VideoPlayer(controller),
                      const Center(
                        child: Icon(Icons.play_circle_fill,
                            color: Colors.white, size: 50),
                      ),
                    ],
                  )
                : const Center(
                    child: CircularProgressIndicator(
                        color: Color(0xFF3390EC), strokeWidth: 2),
                  ),
          ),
        ),
        if (isViewOnce)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.local_fire_department,
                      size: 11, color: Colors.orange),
                  SizedBox(width: 4),
                  Text('View once',
                      style: TextStyle(color: Colors.white, fontSize: 10)),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _audioBubble(String url, {required bool isMine}) {
    final theme = Theme.of(context);
    final isCurrent = widget.playingAudioId == widget.message['id'];
    final position = isCurrent ? widget.audioPosition : Duration.zero;
    final total = isCurrent && widget.audioDuration != Duration.zero
        ? widget.audioDuration
        : Duration(seconds: (widget.message['duration'] ?? 0) as int);
    final progress = total.inMilliseconds > 0
        ? position.inMilliseconds / total.inMilliseconds
        : 0.0;
    final textColor = theme.brightness == Brightness.dark
        ? Colors.white
        : (isMine ? Colors.black : theme.colorScheme.onSurface);
    return Container(
      width: 220,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => widget.onPlayAudio(widget.message['id'], url),
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                isCurrent && position > Duration.zero
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
                    backgroundColor: textColor.withOpacity(0.1),
                    valueColor: AlwaysStoppedAnimation(
                      theme.colorScheme.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _fmtDur(isCurrent ? position : total),
                  style: TextStyle(
                    color: textColor.withOpacity(0.6),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _gifBubble(String url) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260, maxHeight: 320),
        child: CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          placeholder: (_, __) => Container(
            width: 200,
            height: 200,
            color: Colors.black.withOpacity(0.05),
          ),
        ),
      ),
    );
  }

  Widget _fileBubble(String url) {
    final theme = Theme.of(context);
    final name = (widget.message['file_name'] ?? 'File').toString();
    final size = (widget.message['file_size'] ?? '').toString();
    return GestureDetector(
      onTap: () => widget.onOpenFile(url, name),
      child: Container(
        width: 220,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withOpacity(0.06),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.insert_drive_file,
                  color: theme.colorScheme.primary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w500)),
                  if (size.isNotEmpty)
                    Text(size,
                        style: TextStyle(
                            color: theme.colorScheme.onSurface
                                .withOpacity(0.4),
                            fontSize: 10)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _locationBubble(ThemeData theme) {
    final lat = (widget.message['location_lat'] ?? 0).toDouble();
    final lng = (widget.message['location_lng'] ?? 0).toDouble();
    final label =
        (widget.message['location_label'] ?? 'Shared location').toString();
    final isLive = widget.message['location_live'] == true;
    return GestureDetector(
      onTap: () => widget.onOpenLocation(lat, lng),
      child: Container(
        width: 220,
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: theme.colorScheme.primary.withOpacity(0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 100,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.15),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Center(
                child: Icon(
                    isLive ? Icons.my_location : Icons.location_on,
                    color: isLive
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                    size: 36),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  Icon(Icons.place,
                      size: 14,
                      color: isLive
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _contactBubble(ThemeData theme) {
    final c = Map<String, dynamic>.from(widget.message['contact'] ?? {});
    final name = (c['display_name'] ?? c['username'] ?? 'Contact').toString();
    final username = (c['username'] ?? 'user').toString();
    final avatar = c['avatar_url'] as String?;
    return GestureDetector(
      onTap: () => widget.onOpenProfile(
        (c['uid'] ?? '').toString(),
        name,
        avatar,
      ),
      child: Container(
        width: 220,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: theme.colorScheme.primary.withOpacity(0.2)),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor:
                  theme.colorScheme.primary.withOpacity(0.2),
              backgroundImage:
                  avatar != null ? CachedNetworkImageProvider(avatar) : null,
              child: avatar == null
                  ? Text(name[0].toUpperCase(),
                      style: TextStyle(color: theme.colorScheme.primary))
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  Text('@$username',
                      style: TextStyle(
                          color: theme.colorScheme.onSurface
                              .withOpacity(0.55),
                          fontSize: 11)),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                color: theme.colorScheme.onSurface.withOpacity(0.4),
                size: 18),
          ],
        ),
      ),
    );
  }

  bool _isSingleEmoji(String s) {
    final t = s.trim();
    if (t.isEmpty) return false;
    if (t.contains(' ') || t.contains('\n') || t.contains('\t')) return false;
    final runes = t.runes.toList();
    if (runes.isEmpty) return false;
    if (runes.length > 4) return false;
    final c = runes.first;
    return (c >= 0x1F300 && c <= 0x1FAFF) ||
        (c >= 0x2600 && c <= 0x27BF) ||
        (c >= 0x1F1E6 && c <= 0x1F1FF);
  }

  String _fmtTime(dynamic ts) {
    final d = _parse(ts);
    if (d == null) return '';
    return DateFormat('HH:mm').format(d);
  }

  String _fmtDur(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  DateTime? _parse(dynamic t) {
    if (t == null) return null;
    if (t is Timestamp) return t.toDate();
    if (t is String) return DateTime.tryParse(t);
    return null;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// LINKIFY / MARKDOWN
// ═══════════════════════════════════════════════════════════════════════════
class _Linkify {
  static final _codeBlockR = RegExp(r'```([^`]+)```');
  static final _inlineCodeR = RegExp(r'`([^`]+)`');
  static final _spoilerR = RegExp(r'\|\|([^|]+)\|\|');
  static final _underlineR = RegExp(r'__([^_]+)__');
  static final _boldR = RegExp(r'\*\*([^*]+)\*\*');
  static final _strikeR = RegExp(r'~~([^~]+)~~');
  static final _mdLinkR =
      RegExp(r'\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)');
  static final _urlR = RegExp(r'(https?://[^\s<]+)');
  static final _mentionR = RegExp(r'(^|\s)@([a-zA-Z0-9_]{2,30})');

  static List<InlineSpan> parse(
    String text, {
    required bool isMine,
    required void Function(String url) onOpenUrl,
    required void Function(String username) onMention,
  }) {
    final spans = <InlineSpan>[];
    final buf = StringBuffer();

    void flush() {
      if (buf.isEmpty) return;
      spans.add(TextSpan(
        text: buf.toString(),
        style: const TextStyle(fontSize: 14.5, height: 1.3),
      ));
      buf.clear();
    }

    void addSpan(InlineSpan s) {
      flush();
      spans.add(s);
    }

    final patterns = <_MdPattern>[
      _MdPattern(_codeBlockR, (m) => _code(m.group(1)!)),
      _MdPattern(_inlineCodeR, (m) => _code(m.group(1)!)),
      _MdPattern(_spoilerR, (m) => _spoiler(m.group(1)!)),
      _MdPattern(_underlineR, (m) => _underline(m.group(1)!)),
      _MdPattern(_boldR, (m) => _bold(m.group(1)!)),
      _MdPattern(_strikeR, (m) => _strike(m.group(1)!)),
      _MdPattern(
          _mdLinkR, (m) => _link(m.group(1)!, m.group(2)!, onOpenUrl)),
      _MdPattern(_urlR, (m) => _link(m.group(0)!, m.group(0)!, onOpenUrl)),
      _MdPattern(_mentionR,
          (m) => _mention(m.group(2)!, onMention)),
    ];

    var i = 0;
    while (i < text.length) {
      _MdPattern? matched;
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
        addSpan(matched.build(mm));
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

  static InlineSpan _spoiler(String s) => WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: _SpoilerSpan(text: s),
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

  static InlineSpan _link(
      String label, String url, void Function(String) onOpenUrl) {
    return TextSpan(
      text: label,
      style: const TextStyle(
        color: Color(0xFF3390EC),
        decoration: TextDecoration.underline,
      ),
      recognizer: TapGestureRecognizer()..onTap = () => onOpenUrl(url),
    );
  }

  static InlineSpan _mention(String username, void Function(String) onMention) {
    return TextSpan(
      text: '@$username',
      style: const TextStyle(
        color: Color(0xFF3390EC),
        fontWeight: FontWeight.w600,
      ),
      recognizer: TapGestureRecognizer()..onTap = () => onMention(username),
    );
  }
}

class _MdPattern {
  final RegExp re;
  final InlineSpan Function(RegExpMatch) build;
  _MdPattern(this.re, this.build);
}

class _SpoilerSpan extends StatefulWidget {
  final String text;
  const _SpoilerSpan({required this.text});

  @override
  State<_SpoilerSpan> createState() => _SpoilerSpanState();
}

class _SpoilerSpanState extends State<_SpoilerSpan> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => _revealed = !_revealed),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(
          color: const Color(0xFF3390EC)
              .withOpacity(_revealed ? 0.12 : 0.35),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          widget.text,
          style: TextStyle(
            color: _revealed ? null : Colors.transparent,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}
