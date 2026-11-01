import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../services/api_config.dart';
import '../../services/cloudinary_service.dart';

// ═══════════════════════════════════════════════════════════════════════════
// CONFIG: field names in your Firestore `users` documents.
// Change these if your fields are named differently.
// ═══════════════════════════════════════════════════════════════════════════
const String _kUserPhoneField = 'phone_number';
const String _kUserNameField = 'display_name';
const String _kUserAvatarField = 'avatar_url';
const String _kUserOnlineField = 'is_online';

String _fmtDur(int s) => '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

/// Keeps the last 10 digits so "+234 913 405 7359" and "0913 405 7359" match.
String _digitsTail(String raw) {
  final d = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.length >= 10) return d.substring(d.length - 10);
  return d;
}

// ═══════════════════════════════════════════════════════════════════════════
// NATIVE RECORDER (Talks directly to MainActivity.kt)
// ═══════════════════════════════════════════════════════════════════════════
class LocalRecorder {
  static const _channel = MethodChannel('com.lumachat.app/recorder');
  Future<void> start(String path) async => await _channel.invokeMethod('start', {'path': path});
  Future<String?> stop() async => await _channel.invokeMethod<String>('stop');
  Future<void> cancel() async => await _channel.invokeMethod('cancel');
}

class _LumaContact {
  final String name;
  final String phone;
  final String uid;
  final String? avatar;
  _LumaContact({required this.name, required this.phone, required this.uid, this.avatar});
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
  bool _hasText = false;

  Map<String, dynamic>? _chatData;
  List<Map<String, dynamic>> _messages = [];
  List<Map<String, dynamic>> _pinnedMessages = [];
  StreamSubscription? _messageSub;
  StreamSubscription? _chatSub;
  StreamSubscription? _typingSub;
  StreamSubscription? _premiumSub;
  final List<StreamSubscription> _audioSubs = [];
  bool _isLoading = true;
  Timer? _loadingFallback;

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

  // Members / online count
  String _membersKey = '';
  final List<StreamSubscription> _memberSubs = [];
  final Map<int, int> _onlineByChunk = {};
  int get _onlineCount => _onlineByChunk.values.fold(0, (a, b) => a + b);

  // Custom Attachment State
  int _selectedBottomTab = 0;
  List<File> _selectedImages = [];
  final List<AssetEntity> _selectedAssets = [];
  Future<List<AssetEntity>>? _assetsFuture;
  Future<List<AssetEntity>>? _audioFuture;
  Future<List<_LumaContact>>? _contactsFuture;
  final _contactSearch = TextEditingController();
  final _musicSearch = TextEditingController();

  // Live location state
  StreamSubscription<Position>? _liveSub;
  Timer? _liveTimer;
  String? _liveMsgId;
  DateTime? _liveUntil;

  @override
  void initState() {
    super.initState();
    _messageController.addListener(() {
      final h = _messageController.text.trim().isNotEmpty;
      if (h != _hasText && mounted) setState(() => _hasText = h);
    });
    // Safety net so the screen can never be stuck on the loading spinner.
    _loadingFallback = Timer(const Duration(seconds: 8), () {
      if (mounted && _isLoading) setState(() => _isLoading = false);
    });
    _initAudioPlayer();
    _init();
  }

  void _initAudioPlayer() {
    _audioSubs.add(_audioPlayer.positionStream.listen((pos) { if (mounted) setState(() => _audioPosition = pos); }));
    _audioSubs.add(_audioPlayer.durationStream.listen((dur) { if (mounted) setState(() => _audioDuration = dur ?? Duration.zero); }));
    _audioSubs.add(_audioPlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        if (mounted) setState(() => _currentlyPlayingId = null);
        _audioPlayer.stop();
      }
    }));
  }

  Future<void> _init() async {
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    _currentUserId = auth.user?.uid ?? auth.mockUserId;
    if (_currentUserId == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    _listenToChat();
    _listenToMessages();
    _listenToPremium();
    _loadWallpaper();
    _listenToTyping();
  }

  void _listenToChat() {
    _chatSub = FirebaseFirestore.instance.collection('chats').doc(widget.chatId).snapshots().listen((doc) {
      if (!mounted) return;
      setState(() {
        if (doc.exists) {
          _chatData = doc.data();
          _myRole = _chatData?['participants_data']?[_currentUserId]?['role'] ?? 'member';
        }
        _isLoading = false;
      });
      if (doc.exists) {
        _loadPinnedMessages();
        final parts = _chatData?['participants'];
        if (parts is List) _listenToMembers(parts.map((e) => e.toString()).toList());
      }
    }, onError: (_) {
      if (mounted) setState(() => _isLoading = false);
    });
  }

  void _listenToMembers(List<String> ids) {
    final key = ids.join(',');
    if (key == _membersKey) return;
    _membersKey = key;
    for (final s in _memberSubs) { s.cancel(); }
    _memberSubs.clear();
    _onlineByChunk.clear();
    for (var i = 0; i < ids.length; i += 10) {
      final chunk = ids.sublist(i, math.min(i + 10, ids.length));
      final idx = i;
      _memberSubs.add(FirebaseFirestore.instance.collection('users').where(FieldPath.documentId, whereIn: chunk).snapshots().listen((snap) {
        if (!mounted) return;
        setState(() => _onlineByChunk[idx] = snap.docs.where((d) => d.data()[_kUserOnlineField] == true).length);
      }, onError: (_) {}));
    }
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
    }, onError: (_) {});
  }

  void _listenToTyping() {
    _typingSub = FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('typing').snapshots().listen((snap) {
      if (!mounted) return;
      setState(() {
        _typingUsers.clear();
        for (final doc in snap.docs) {
          if (doc.id != _currentUserId && doc.data()['is_typing'] == true) _typingUsers[doc.id] = true;
        }
      });
    }, onError: (_) {});
  }

  Future<void> _fetchUser(String uid) async {
    _userCache[uid] = {'display_name': 'Member', 'avatar_url': null}; // prevents duplicate fetches
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      if (doc.exists && mounted) setState(() => _userCache[uid] = doc.data());
    } catch (_) {}
  }

  void _listenToPremium() {
    _premiumSub = FirebaseFirestore.instance.collection('users').doc(_currentUserId).snapshots().listen((doc) {
      if (mounted && doc.exists) setState(() => _isMePremium = doc.data()?['is_premium'] == true);
    }, onError: (_) {});
  }

  Future<void> _loadWallpaper() async {
    try {
      final doc = await FirebaseFirestore.instance.collection('user_settings').doc(_currentUserId).get();
      if (doc.exists && mounted) {
        final walls = doc.data()?['chat_wallpapers'] as Map<String, dynamic>? ?? {};
        setState(() => _wallpaperUrl = walls[widget.chatId]);
      }
    } catch (_) {}
  }

  Future<void> _loadPinnedMessages() async {
    try {
      final snap = await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('pinned_messages').orderBy('pinned_at', descending: true).limit(1).get();
      if (mounted) setState(() => _pinnedMessages = snap.docs.map((d) => {'id': d.id, ...d.data()}).toList());
    } catch (_) {}
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
  /// Shared helper used by the new attachment features. Returns the new message id.
  Future<String> _postMessage(Map<String, dynamic> data) async {
    final msgId = const Uuid().v4();
    await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(msgId).set({
      'id': msgId,
      'sender_id': _currentUserId,
      'created_at': FieldValue.serverTimestamp(),
      'is_read': false,
      ...data,
    });
    return msgId;
  }

  Future<void> _sendText() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    // Check if group is locked
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
    if (mounted) setState(() => _replyingTo = null);
  }

  Future<void> _sendSticker(String url) async {
    final msgId = const Uuid().v4();
    await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(msgId).set({
      'id': msgId, 'sender_id': _currentUserId, 'type': 'sticker', 'media_type': 'sticker', 'media_url': url, 'created_at': FieldValue.serverTimestamp(), 'is_read': false,
    });
    if (mounted) setState(() => _activePanel = null);
  }

  Future<void> _sendGif(String url) async {
    final msgId = const Uuid().v4();
    await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(msgId).set({
      'id': msgId, 'sender_id': _currentUserId, 'type': 'gif', 'media_type': 'gif', 'media_url': url, 'created_at': FieldValue.serverTimestamp(), 'is_read': false,
    });
    if (mounted) setState(() => _activePanel = null);
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

  /// Sends the photos / videos selected in the custom gallery grid.
  Future<void> _sendAssets(List<AssetEntity> assets) async {
    final limit = _isMePremium ? (5 * 1024 * 1024 * 1024) : (200 * 1024 * 1024);
    for (var i = 0; i < assets.length; i++) {
      final a = assets[i];
      try {
        final file = await a.file;
        if (file == null) continue;
        final size = await file.length();
        if (size > limit) { _showSnack(_isMePremium ? 'Max 5GB' : 'Upgrade to Premium for >200MB'); continue; }
        final isVideo = a.type == AssetType.video;
        _showSnack('Uploading ${i + 1}/${assets.length}...');
        final url = isVideo ? await CloudinaryService.uploadVideo(file, 'luma/groups') : await CloudinaryService.uploadImage(file, 'luma/groups');
        if (url == null) { _showSnack('Upload failed'); continue; }
        await _postMessage({'type': isVideo ? 'video' : 'image', 'media_type': isVideo ? 'video' : 'image', 'media_url': url});
      } catch (e) {
        _showSnack('Send failed: $e');
      }
    }
    if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
  }

  // Camera (image_picker). Pass closeSheet: true when called from the attachment sheet.
  Future<void> _pickFromCamera({bool closeSheet = false}) async {
    try {
      if (closeSheet) {
        Navigator.pop(context); // closes the sheet (also releases the live preview camera)
        await Future.delayed(const Duration(milliseconds: 300));
      }
      final XFile? photo = await _picker.pickImage(source: ImageSource.camera);
      if (photo != null) {
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
    try {
      final mic = await Permission.microphone.request();
      if (!mic.isGranted) { _showSnack('Microphone permission is required'); return; }
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _audioRecorder.start(path);
      setState(() { _isRecording = true; _recordingSeconds = 0; });
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (t) { if (mounted) setState(() => _recordingSeconds++); });
    } catch (e) {
      _showSnack('Could not start recording: $e');
    }
  }

  Future<void> _stopRecording({bool send = true}) async {
    if (!_isRecording) return;
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

  void _showSnack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  Map<String, dynamic>? _findMessage(String? id) => id == null ? null : _messages.firstWhere((m) => m['id'] == id, orElse: () => {});

  // ═══════════════════════════════════════════════════════════════════════
  // LOCATION (current + live)
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _sendCurrentLocation(Position pos) async {
    Navigator.pop(context);
    try {
      await _postMessage({
        'type': 'location', 'media_type': 'location',
        'latitude': pos.latitude, 'longitude': pos.longitude, 'accuracy': pos.accuracy,
        'text': 'https://maps.google.com/?q=${pos.latitude},${pos.longitude}',
      });
    } catch (e) {
      _showSnack('Could not send location: $e');
    }
  }

  Future<void> _startLiveLocation(Position pos, Duration duration) async {
    Navigator.pop(context);
    try {
      await _stopLiveLocation();
      final until = DateTime.now().add(duration);
      final id = await _postMessage({
        'type': 'live_location', 'media_type': 'location',
        'latitude': pos.latitude, 'longitude': pos.longitude, 'accuracy': pos.accuracy,
        'live_active': true, 'live_until': Timestamp.fromDate(until),
        'text': 'https://maps.google.com/?q=${pos.latitude},${pos.longitude}',
      });
      _liveMsgId = id;
      if (mounted) setState(() => _liveUntil = until);
      _liveSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 10),
      ).listen((p) {
        FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(id).update({
          'latitude': p.latitude, 'longitude': p.longitude, 'accuracy': p.accuracy, 'updated_at': FieldValue.serverTimestamp(),
        }).catchError((_) {});
      }, onError: (_) {});
      _liveTimer = Timer(duration, () => _stopLiveLocation());
    } catch (e) {
      _showSnack('Could not start live location: $e');
    }
  }

  Future<void> _stopLiveLocation({bool updateUi = true}) async {
    _liveSub?.cancel();
    _liveTimer?.cancel();
    _liveSub = null;
    _liveTimer = null;
    final id = _liveMsgId;
    _liveMsgId = null;
    if (updateUi && mounted) setState(() => _liveUntil = null);
    if (id != null) {
      try {
        await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(id).update({'live_active': false});
      } catch (_) {}
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // CONTACTS (Luma Chat users only) & MUSIC loaders
  // ═══════════════════════════════════════════════════════════════════════
  Future<List<AssetEntity>> _loadAssets(RequestType type, {int size = 90}) async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) throw Exception('Permission denied');
    final paths = await PhotoManager.getAssetPathList(type: type, onlyAll: true);
    if (paths.isEmpty) return [];
    return paths.first.getAssetListPaged(page: 0, size: size);
  }

  Future<List<_LumaContact>> _loadLumaContacts() async {
    final granted = await FlutterContacts.requestPermission(readonly: true);
    if (!granted) throw Exception('Contacts permission denied');
    final contacts = await FlutterContacts.getContacts(withProperties: true);
    final usersSnap = await FirebaseFirestore.instance.collection('users').limit(3000).get();

    final byPhone = <String, Map<String, dynamic>>{};
    for (final d in usersSnap.docs) {
      final data = d.data();
      final key = _digitsTail('${data[_kUserPhoneField] ?? ''}');
      if (key.isNotEmpty) byPhone[key] = {'uid': d.id, ...data};
    }

    final out = <_LumaContact>[];
    final seen = <String>{};
    for (final c in contacts) {
      for (final ph in c.phones) {
        final u = byPhone[_digitsTail(ph.number)];
        if (u != null && u['uid'] != _currentUserId && seen.add(u['uid'])) {
          out.add(_LumaContact(
            name: c.displayName.isNotEmpty ? c.displayName : (u[_kUserNameField] ?? 'Unknown').toString(),
            phone: ph.number,
            uid: u['uid'],
            avatar: u[_kUserAvatarField]?.toString(),
          ));
          break;
        }
      }
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  @override
  void dispose() {
    _loadingFallback?.cancel();
    _messageSub?.cancel(); _chatSub?.cancel(); _typingSub?.cancel(); _premiumSub?.cancel();
    for (final s in _audioSubs) { s.cancel(); }
    for (final s in _memberSubs) { s.cancel(); }
    _stopLiveLocation(updateUi: false);
    _messageController.dispose(); _scrollController.dispose(); _searchController.dispose();
    _contactSearch.dispose(); _musicSearch.dispose();
    _audioPlayer.dispose(); _recordingTimer?.cancel(); _typingTimer?.cancel(); _audioRecorder.cancel();
    for (final v in _videoControllers.values) { v.dispose(); }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    if (_isLoading) return Scaffold(body: Center(child: CircularProgressIndicator(color: theme.colorScheme.primary)));

    final topInset = MediaQuery.of(context).padding.top + 64;
    final q = _searchController.text.trim().toLowerCase();
    final visibleMessages = (_isSearching && q.isNotEmpty)
        ? _messages.where((m) => (m['text'] ?? '').toString().toLowerCase().contains(q)).toList()
        : _messages;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(64),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: _isSearching
                ? _buildSearchBar(theme)
                : Row(
                    children: [
                      // Back arrow: its own circle
                      _headerCircle(icon: Icons.arrow_back, onTap: () => Navigator.pop(context)),
                      const SizedBox(width: 8),
                      // Group name + members/online pill
                      Expanded(
                        child: GestureDetector(
                          onTap: () => Navigator.pushNamed(context, '/group_info', arguments: {'chatId': widget.chatId}),
                          child: Container(
                            height: 48,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            decoration: _headerDecoration(isDark, radius: 26),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(widget.chatName, style: TextStyle(color: theme.colorScheme.onSurface, fontSize: 15, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
                                Text(
                                  _typingUsers.isNotEmpty
                                      ? 'typing...'
                                      : '${(_chatData?['participants'] as List?)?.length ?? 0} members${_onlineCount > 0 ? ', $_onlineCount online' : ''}',
                                  style: TextStyle(color: _typingUsers.isNotEmpty ? const Color(0xFF3390EC) : theme.colorScheme.onSurface.withOpacity(0.55), fontSize: 12),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _headerCircle(icon: Icons.search, onTap: () => setState(() => _isSearching = true)),
                      const SizedBox(width: 8),
                      // 3-dot menu: its own circle
                      _headerCircle(icon: Icons.more_vert, onTap: _showMoreMenu),
                    ],
                  ),
          ),
        ),
      ),
      body: Stack(
        children: [
          if (_wallpaperUrl != null) Positioned.fill(child: Image.network(_wallpaperUrl!, fit: BoxFit.cover, opacity: const AlwaysStoppedAnimation(0.2))),
          Padding(
            padding: EdgeInsets.only(top: topInset),
            child: Column(
              children: [
                if (_pinnedMessages.isNotEmpty) _buildPinnedBanner(theme),
                Expanded(
                  child: ListView.builder(
                    controller: _scrollController, reverse: true, padding: const EdgeInsets.all(8), itemCount: visibleMessages.length,
                    itemBuilder: (context, i) => _buildMessage(visibleMessages[i], theme, isDark),
                  ),
                ),
                if (_replyingTo != null) _buildReplyBar(theme),
                if (_multiSelectMode) _buildMultiSelectBar(theme),
                if (_isRecording) _buildRecordingBar(theme),
                if (_liveUntil != null) _buildLiveBar(theme),
                _buildComposer(theme, isDark),
                if (_activePanel != null) _buildPanel(theme, isDark),
              ],
            ),
          ),
        ],
      ),
    );
  }

  BoxDecoration _headerDecoration(bool isDark, {double radius = 24}) => BoxDecoration(
        color: isDark ? const Color(0xFF1F2C34) : Colors.white,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 6, offset: const Offset(0, 2))],
      );

  Widget _buildSearchBar(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    return Row(
      children: [
        _headerCircle(icon: Icons.arrow_back, onTap: () => setState(() { _isSearching = false; _searchController.clear(); })),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: _headerDecoration(isDark, radius: 26),
            child: TextField(
              controller: _searchController, autofocus: true, style: TextStyle(color: theme.colorScheme.onSurface),
              decoration: InputDecoration(hintText: 'Search messages...', hintStyle: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.5)), border: InputBorder.none),
              onChanged: (val) => setState(() {}),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLiveBar(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(color: Colors.green.withOpacity(0.15), borderRadius: BorderRadius.circular(20)),
      child: Row(children: [
        const Icon(Icons.location_searching, size: 18, color: Colors.green),
        const SizedBox(width: 8),
        Expanded(child: Text('Sharing live location until ${DateFormat('HH:mm').format(_liveUntil!)}', style: const TextStyle(fontSize: 13))),
        TextButton(onPressed: () => _stopLiveLocation(), child: const Text('Stop', style: TextStyle(color: Colors.red))),
      ]),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // COMPOSER: single rounded pill, mic is a solid circle inside it,
  // nothing painted behind the pill.
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildComposer(ThemeData theme, bool isDark) {
    final isLocked = _chatData?['is_locked'] == true;
    final canText = !isLocked || _myRole == 'admin' || _myRole == 'owner';
    final iconColor = theme.colorScheme.onSurface.withOpacity(0.55);

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      child: SafeArea(
        top: false,
        bottom: _activePanel == null,
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1F2C34) : Colors.white,
            borderRadius: BorderRadius.circular(30),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.10), blurRadius: 6, offset: const Offset(0, 2))],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SizedBox(
                width: 44, height: 44,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: Icon(_activePanel != null ? Icons.keyboard : Icons.emoji_emotions_outlined, color: iconColor),
                  onPressed: () {
                    if (_activePanel != null) { setState(() => _activePanel = null); SystemChannels.textInput.invokeMethod('TextInput.show'); }
                    else { FocusScope.of(context).unfocus(); setState(() => _activePanel = 'emoji'); }
                  },
                ),
              ),
              Expanded(
                child: canText
                    ? TextField(
                        controller: _messageController, minLines: 1, maxLines: 5,
                        onChanged: (val) => _sendTypingStatus(val.isNotEmpty),
                        decoration: InputDecoration(
                          hintText: 'Message',
                          hintStyle: TextStyle(color: Colors.grey[500], fontSize: 16),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 13),
                        ),
                        onTap: () { if (_activePanel != null) setState(() => _activePanel = null); },
                      )
                    : GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _showSnack('Text not allowed. Group is locked to admins.'),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 13),
                          child: Row(children: [
                            Icon(Icons.lock, size: 16, color: Colors.grey[500]),
                            const SizedBox(width: 6),
                            Flexible(child: Text('Text Not Allowed', overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.grey[500], fontSize: 16))),
                          ]),
                        ),
                      ),
              ),
              SizedBox(width: 44, height: 44, child: IconButton(padding: EdgeInsets.zero, icon: Icon(Icons.attach_file, color: iconColor), onPressed: () => _showAttachmentSheet())),
              // Camera quick action (shown while there is no text, like Telegram)
              if (!_hasText && canText)
                SizedBox(width: 44, height: 44, child: IconButton(padding: EdgeInsets.zero, icon: Icon(Icons.camera_alt_outlined, color: iconColor), onPressed: _pickFromCamera)),
              const SizedBox(width: 2),
              // Sharp solid circle (mic / send)
              GestureDetector(
                onTap: _hasText ? _sendText : () => _showSnack('Hold to record a voice message'),
                onLongPress: (canText && !_hasText) ? _startRecording : null,
                onLongPressEnd: (_) => (canText && !_hasText) ? _stopRecording(send: true) : null,
                child: Container(
                  width: 44, height: 44,
                  decoration: const BoxDecoration(color: Color(0xFF3390EC), shape: BoxShape.circle),
                  child: Icon(_hasText ? Icons.send : Icons.mic, color: Colors.white, size: 22),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // EMOJI / GIFs / STICKERS PANEL
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildPanel(ThemeData theme, bool isDark) {
    final bg = isDark ? const Color(0xFF17212B) : Colors.white;
    Widget content;
    if (_activePanel == 'sticker') {
      content = _GiphyPanel(key: const ValueKey('giphy_stickers'), isSticker: true, apiKey: ApiConfig.giphyApiKey, onSelected: _sendSticker);
    } else if (_activePanel == 'gif') {
      content = _GiphyPanel(key: const ValueKey('giphy_gifs'), isSticker: false, apiKey: ApiConfig.giphyApiKey, onSelected: _sendGif);
    } else {
      content = EmojiPicker(
        textEditingController: _messageController,
        config: Config(
          height: 272,
          emojiViewConfig: EmojiViewConfig(backgroundColor: bg, columns: 8, emojiSizeMax: 28),
          categoryViewConfig: CategoryViewConfig(
            backgroundColor: bg,
            indicatorColor: const Color(0xFF3390EC),
            iconColorSelected: const Color(0xFF3390EC),
            iconColor: theme.colorScheme.onSurface.withOpacity(0.55),
          ),
          bottomActionBarConfig: BottomActionBarConfig(
            backgroundColor: bg,
            buttonColor: Colors.transparent,
            buttonIconColor: theme.colorScheme.onSurface.withOpacity(0.7),
          ),
          searchViewConfig: SearchViewConfig(backgroundColor: bg),
        ),
      );
    }

    return Container(
      height: 340,
      color: bg,
      child: Column(
        children: [
          Expanded(child: content),
          _buildPanelTabs(theme, isDark),
        ],
      ),
    );
  }

  Widget _buildPanelTabs(ThemeData theme, bool isDark) {
    Widget tab(String label, String key) {
      final selected = _activePanel == key;
      return GestureDetector(
        onTap: () => setState(() => _activePanel = key),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 9),
          decoration: BoxDecoration(color: selected ? (isDark ? const Color(0xFF2B394A) : const Color(0xFFE9E9EC)) : Colors.transparent, borderRadius: BorderRadius.circular(22)),
          child: Text(label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: selected ? theme.colorScheme.onSurface : theme.colorScheme.onSurface.withOpacity(0.55))),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: SafeArea(
        top: false,
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1F2C34) : Colors.white,
              borderRadius: BorderRadius.circular(26),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 8, offset: const Offset(0, 2))],
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [tab('Emoji', 'emoji'), tab('GIFs', 'gif'), tab('Stickers', 'sticker')]),
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // ATTACHMENT BOTTOM SHEET (Gallery · File · Location · Contact · Music)
  // ═══════════════════════════════════════════════════════════════════════
  void _showAttachmentSheet() {
    _selectedBottomTab = 0;
    _selectedAssets.clear();
    _assetsFuture = _loadAssets(RequestType.common);
    _contactsFuture = null;
    _audioFuture = null;
    _contactSearch.clear();
    _musicSearch.clear();
    FocusScope.of(context).unfocus();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (BuildContext ctx, StateSetter setModalState) {
            final isDark = Theme.of(ctx).brightness == Brightness.dark;
            final bg = isDark ? const Color(0xFF17212B) : Colors.white;
            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: Container(
                height: MediaQuery.of(ctx).size.height * 0.85,
                decoration: BoxDecoration(color: bg, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                  child: Stack(
                    children: [
                      Column(
                        children: [
                          Container(margin: const EdgeInsets.only(top: 10, bottom: 10), height: 4, width: 40, decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(2))),
                          Expanded(child: _buildBottomSheetContent(_selectedBottomTab, setModalState)),
                        ],
                      ),
                      if (_selectedBottomTab == 0 && _selectedAssets.isNotEmpty)
                        Positioned(
                          right: 16,
                          bottom: 96 + MediaQuery.of(ctx).padding.bottom,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF3390EC), foregroundColor: Colors.white, shape: const StadiumBorder(), padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
                            icon: const Icon(Icons.send, size: 18),
                            label: Text('Send ${_selectedAssets.length}'),
                            onPressed: () {
                              final list = List<AssetEntity>.from(_selectedAssets);
                              _selectedAssets.clear();
                              Navigator.pop(ctx);
                              _sendAssets(list);
                            },
                          ),
                        ),
                      Positioned(
                        left: 12, right: 12,
                        bottom: 12 + MediaQuery.of(ctx).padding.bottom,
                        child: _buildBottomTabBar(setModalState),
                      ),
                    ],
                  ),
                ),
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
      case 3: return _buildContactsPicker(setModalState);
      case 4: return _buildMusicPicker(setModalState);
      default: return const Center(child: Text("Select an option"));
    }
  }

  // Gallery: camera preview tile + photo/video grid with selection circles
  Widget _buildCustomImagePicker(StateSetter setModalState) {
    return FutureBuilder<List<AssetEntity>>(
      future: _assetsFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
        if (snap.hasError) {
          return Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.photo_library_outlined, size: 48, color: Colors.grey),
              const SizedBox(height: 8),
              const Text('Allow access to your photos'),
              const SizedBox(height: 8),
              TextButton(onPressed: () async { await PhotoManager.openSetting(); }, child: const Text('Open settings')),
              TextButton(onPressed: () => setModalState(() => _assetsFuture = _loadAssets(RequestType.common)), child: const Text('Retry')),
            ]),
          );
        }
        final assets = snap.data ?? [];
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(2, 2, 2, 110),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 2, mainAxisSpacing: 2),
          itemCount: assets.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) return _CameraPreviewTile(onTap: () => _pickFromCamera(closeSheet: true));
            final a = assets[i - 1];
            final selIndex = _selectedAssets.indexWhere((e) => e.id == a.id);
            return _AssetThumb(
              key: ValueKey(a.id),
              entity: a,
              selectedIndex: selIndex,
              onTap: () => setModalState(() {
                if (selIndex >= 0) { _selectedAssets.removeAt(selIndex); } else { _selectedAssets.add(a); }
              }),
            );
          },
        );
      },
    );
  }

  Future<void> _uploadAndSendFile(File file, String name) async {
    _showSnack('Uploading File...');
    final url = await CloudinaryService.uploadFile(file, 'luma/files'); // Ensure this method exists in your CloudinaryService
    if (url != null) {
      if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
      final msgId = const Uuid().v4();
      await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(msgId).set({
        'id': msgId, 'sender_id': _currentUserId, 'type': 'file', 'media_type': 'file', 'media_url': url, 'file_name': name, 'created_at': FieldValue.serverTimestamp(), 'is_read': false,
      });
    }
  }

  Future<void> _pickFromAppFolder() async {
    final dir = await getApplicationDocumentsDirectory();
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    if (!mounted) return;
    if (files.isEmpty) { _showSnack('No files in the Luma Chat folder yet'); return; }
    final picked = await showDialog<File>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Luma Chat'),
        children: files.take(30).map((f) {
          final name = f.path.split('/').last;
          return ListTile(leading: const Icon(Icons.insert_drive_file), title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis), onTap: () => Navigator.pop(context, f));
        }).toList(),
      ),
    );
    if (picked == null || !mounted) return;
    Navigator.pop(context); // close attachment sheet
    await _uploadAndSendFile(picked, picked.path.split('/').last);
  }

  // File tab
  Widget _buildFilePicker() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
      children: [
        _buildListTile(Icons.storage, Colors.green, "Internal Storage", "Browse your file system", onTap: () async {
          FilePickerResult? result = await FilePicker.platform.pickFiles();
          if (result != null && result.files.single.path != null) {
            if (!mounted) return;
            Navigator.pop(context);
            await _uploadAndSendFile(File(result.files.single.path!), result.files.single.name);
          }
        }),
        _buildListTile(Icons.folder, Colors.blue, "Luma Chat", "Browse the app's folder", onTap: _pickFromAppFolder),
        _buildListTile(Icons.photo_library, Colors.orange, "Gallery", "To send images without compression", onTap: () => _pickAndSendMedia('image')),
      ],
    );
  }

  // Location tab
  Widget _buildLocationPicker() {
    return _LocationTab(onSendCurrent: _sendCurrentLocation, onShareLive: _startLiveLocation);
  }

  // Contact tab (Luma Chat users only)
  Widget _buildContactsPicker(StateSetter setModalState) {
    _contactsFuture ??= _loadLumaContacts();
    return FutureBuilder<List<_LumaContact>>(
      future: _contactsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError) {
          return Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.contacts_outlined, size: 48, color: Colors.grey),
              const SizedBox(height: 8),
              const Text('Allow access to your contacts'),
              TextButton(onPressed: () async { await openAppSettings(); }, child: const Text('Open settings')),
              TextButton(onPressed: () => setModalState(() => _contactsFuture = _loadLumaContacts()), child: const Text('Retry')),
            ]),
          );
        }
        final all = snapshot.data ?? [];
        final q = _contactSearch.text.trim().toLowerCase();
        final contacts = q.isEmpty ? all : all.where((c) => c.name.toLowerCase().contains(q) || c.phone.contains(q)).toList();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: TextField(
                controller: _contactSearch,
                onChanged: (_) => setModalState(() {}),
                decoration: InputDecoration(hintText: "Search contacts", prefixIcon: const Icon(Icons.search), filled: true, fillColor: Colors.grey.withOpacity(0.15), border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none)),
              ),
            ),
            Expanded(
              child: contacts.isEmpty
                  ? const Center(child: Text("None of your contacts are on Luma Chat yet"))
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 110),
                      itemCount: contacts.length,
                      itemBuilder: (context, index) {
                        final c = contacts[index];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Colors.blue,
                            backgroundImage: (c.avatar != null && c.avatar!.isNotEmpty) ? NetworkImage(c.avatar!) : null,
                            child: (c.avatar == null || c.avatar!.isEmpty) ? Text(c.name.isNotEmpty ? c.name[0].toUpperCase() : '?', style: const TextStyle(color: Colors.white)) : null,
                          ),
                          title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text(c.phone, style: TextStyle(color: Colors.grey[600])),
                          onTap: () async {
                            Navigator.pop(context);
                            await _postMessage({
                              'type': 'contact', 'media_type': 'contact',
                              'text': '${c.name}\n${c.phone}',
                              'contact_name': c.name, 'contact_phone': c.phone, 'contact_uid': c.uid, 'contact_avatar': c.avatar,
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

  // Music tab
  Widget _buildMusicPicker(StateSetter setModalState) {
    _audioFuture ??= _loadAssets(RequestType.audio, size: 200);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12.0),
          child: TextField(
            controller: _musicSearch,
            onChanged: (_) => setModalState(() {}),
            decoration: InputDecoration(hintText: "Search music", prefixIcon: const Icon(Icons.search), filled: true, fillColor: Colors.grey.withOpacity(0.15), border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none)),
          ),
        ),
        ListTile(
          leading: const CircleAvatar(backgroundColor: Colors.blue, child: Icon(Icons.audio_file, color: Colors.white)),
          title: const Text("Pick Audio File from Device"),
          subtitle: const Text("Select an MP3 or M4A"),
          onTap: () async {
            FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.audio);
            if (result != null && result.files.single.path != null) {
              if (!mounted) return;
              Navigator.pop(context);
              _showSnack('Uploading Audio...');
              final file = File(result.files.single.path!);
              final url = await CloudinaryService.uploadAudio(file, 'luma/music');
              if (url != null) {
                final msgId = const Uuid().v4();
                await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(msgId).set({
                  'id': msgId, 'sender_id': _currentUserId, 'type': 'audio', 'media_type': 'audio', 'media_url': url, 'file_name': result.files.single.name, 'created_at': FieldValue.serverTimestamp(), 'is_read': false,
                });
              }
            }
          },
        ),
        Expanded(
          child: FutureBuilder<List<AssetEntity>>(
            future: _audioFuture,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
              if (snap.hasError) {
                return Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('Allow access to your music'),
                    TextButton(onPressed: () async { await PhotoManager.openSetting(); }, child: const Text('Open settings')),
                    TextButton(onPressed: () => setModalState(() => _audioFuture = _loadAssets(RequestType.audio, size: 200)), child: const Text('Retry')),
                  ]),
                );
              }
              final q = _musicSearch.text.trim().toLowerCase();
              final items = (snap.data ?? []).where((a) => q.isEmpty || (a.title ?? '').toLowerCase().contains(q)).toList();
              if (items.isEmpty) return const Center(child: Text('No music found'));
              return ListView.builder(
                padding: const EdgeInsets.only(bottom: 110),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final a = items[i];
                  final title = (a.title == null || a.title!.isEmpty) ? 'Audio' : a.title!;
                  return ListTile(
                    leading: const CircleAvatar(backgroundColor: Color(0xFF3390EC), child: Icon(Icons.music_note, color: Colors.white)),
                    title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(_fmtDur(a.duration), style: TextStyle(color: Colors.grey[600])),
                    onTap: () async {
                      final file = await a.file;
                      if (file == null) { _showSnack('Could not read this file'); return; }
                      if (!mounted) return;
                      Navigator.pop(context);
                      _showSnack('Uploading Audio...');
                      final url = await CloudinaryService.uploadAudio(file, 'luma/music');
                      if (url != null) {
                        if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        await _postMessage({'type': 'audio', 'media_type': 'audio', 'media_url': url, 'file_name': title, 'duration': a.duration});
                      }
                    },
                  );
                },
              );
            },
          ),
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

  // Floating tab bar of the attachment sheet
  Widget _buildBottomTabBar(StateSetter setModalState) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F2C34) : Colors.white,
        borderRadius: BorderRadius.circular(32),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: 12, offset: const Offset(0, 3))],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildTabIcon(Icons.photo_library_outlined, "Gallery", 0, setModalState),
          _buildTabIcon(Icons.insert_drive_file_outlined, "File", 1, setModalState),
          _buildTabIcon(Icons.location_on_outlined, "Location", 2, setModalState),
          _buildTabIcon(Icons.account_circle_outlined, "Contact", 3, setModalState),
          _buildTabIcon(Icons.play_circle_outline, "Music", 4, setModalState),
        ],
      ),
    );
  }

  Widget _buildTabIcon(IconData icon, String label, int index, StateSetter setModalState) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? Colors.white70 : Colors.black87;
    bool isSelected = _selectedBottomTab == index;
    return GestureDetector(
      onTap: () {
        setModalState(() {
          _selectedBottomTab = index;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF3390EC).withOpacity(0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: isSelected ? const Color(0xFF3390EC) : base, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? const Color(0xFF3390EC) : base,
                fontSize: 11,
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

  // Header circle (each header button is its own separate circle)
  Widget _headerCircle({required IconData icon, required VoidCallback onTap}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      width: 48, height: 48,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F2C34) : Colors.white,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Center(child: Icon(icon, color: theme.colorScheme.onSurface, size: 22)),
        ),
      ),
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

    final isLocation = msg['latitude'] != null && (msg['type'] == 'location' || msg['type'] == 'live_location');
    final isContact = msg['type'] == 'contact';
    final isFile = msg['type'] == 'file' && msg['media_url'] != null;
    final hideText = isLocation || isContact;

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
                    if (isLocation) _buildLocationBubble(msg),
                    if (isContact) _buildContactBubble(msg, theme),
                    if (isFile) _buildFileBubble(msg, theme),
                    if (!hideText && (msg['text'] ?? '').toString().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(msg['text'], style: TextStyle(color: isMe && isDark ? Colors.white : theme.colorScheme.onSurface, fontSize: 15))),
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

  Widget _buildLocationBubble(Map<String, dynamic> msg) {
    final lat = (msg['latitude'] as num).toDouble();
    final lng = (msg['longitude'] as num).toDouble();
    final isLive = msg['type'] == 'live_location';
    final until = (msg['live_until'] as Timestamp?)?.toDate();
    final active = isLive && msg['live_active'] == true && until != null && until.isAfter(DateTime.now());
    final pos = LatLng(lat, lng);
    final mine = msg['sender_id'] == _currentUserId && msg['id'] == _liveMsgId;

    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => _LocationViewerScreen(chatId: widget.chatId, msgId: msg['id'], lat: lat, lng: lng, live: isLive))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 220, height: 140,
              child: AbsorbPointer(
                child: FlutterMap(
                  key: ValueKey('map_${msg['id']}_${lat}_$lng'),
                  options: MapOptions(initialCenter: pos, initialZoom: 15, interactionOptions: const InteractionOptions(flags: InteractiveFlag.none)),
                  children: [
                    TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.lumachat.app'),
                    MarkerLayer(markers: [Marker(point: pos, width: 36, height: 36, child: const Icon(Icons.location_on, color: Colors.red, size: 36))]),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(isLive ? Icons.location_searching : Icons.location_on, size: 16, color: active ? Colors.green : Colors.red),
            const SizedBox(width: 4),
            Text(
              isLive ? (active ? 'Live location · until ${DateFormat('HH:mm').format(until)}' : 'Live location ended') : 'Location',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ]),
          if (active && mine) TextButton(style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 30)), onPressed: () => _stopLiveLocation(), child: const Text('Stop sharing', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
  }

  Widget _buildContactBubble(Map<String, dynamic> msg, ThemeData theme) {
    final lines = (msg['text'] ?? '').toString().split('\n');
    final name = (msg['contact_name'] ?? (lines.isNotEmpty ? lines.first : 'Contact')).toString();
    final phone = (msg['contact_phone'] ?? (lines.length > 1 ? lines[1] : '')).toString();
    final avatar = msg['contact_avatar']?.toString();
    return GestureDetector(
      onTap: () { Clipboard.setData(ClipboardData(text: phone)); _showSnack('Number copied'); },
      child: SizedBox(
        width: 220,
        child: Row(children: [
          CircleAvatar(
            radius: 22, backgroundColor: Colors.blue,
            backgroundImage: (avatar != null && avatar.isNotEmpty) ? NetworkImage(avatar) : null,
            child: (avatar == null || avatar.isEmpty) ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?', style: const TextStyle(color: Colors.white)) : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              Text(phone, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withOpacity(0.6))),
              const Text('Luma Chat', style: TextStyle(fontSize: 11, color: Color(0xFF3390EC))),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _buildFileBubble(Map<String, dynamic> msg, ThemeData theme) {
    final name = (msg['file_name'] ?? 'File').toString();
    return GestureDetector(
      onTap: () => _downloadAndOpen(msg['media_url'], 'file', fileName: name),
      child: SizedBox(
        width: 220,
        child: Row(children: [
          const CircleAvatar(radius: 22, backgroundColor: Color(0xFF3390EC), child: Icon(Icons.insert_drive_file, color: Colors.white)),
          const SizedBox(width: 10),
          Expanded(child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14))),
        ]),
      ),
    );
  }

  Widget _buildAudioBubble(Map<String, dynamic> msg) {
    final isPlaying = _currentlyPlayingId == msg['id'];
    const accent = Color(0xFF3390EC);
    return Container(
      width: 200, padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            IconButton(
              icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow, color: accent),
              onPressed: () {
                if (isPlaying) { _audioPlayer.pause(); setState(() => _currentlyPlayingId = null); }
                else { _audioPlayer.setUrl(msg['media_url']).then((_) { _audioPlayer.play(); setState(() => _currentlyPlayingId = msg['id']); }); }
              },
            ),
            Expanded(child: isPlaying ? LinearProgressIndicator(value: _audioDuration.inMilliseconds > 0 ? _audioPosition.inMilliseconds / _audioDuration.inMilliseconds : 0, color: accent, backgroundColor: Colors.black12) : Text('${msg['duration'] ?? 0}s', style: const TextStyle(color: accent))),
          ]),
          if (msg['file_name'] != null) Padding(padding: const EdgeInsets.only(left: 8, bottom: 2), child: Text(msg['file_name'].toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }

  Widget _buildVideoBubble(String url) {
    final controller = _videoControllers.putIfAbsent(url, () { final c = VideoPlayerController.networkUrl(Uri.parse(url)); c.initialize().then((_) { if (mounted) setState(() {}); }); return c; });
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

  Future<void> _downloadAndOpen(String url, String type, {String? fileName}) async {
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    try {
      final response = await http.get(Uri.parse(url));
      final dir = await getApplicationDocumentsDirectory();
      final ext = type == 'image'
          ? 'jpg'
          : type == 'file'
              ? ((fileName != null && fileName.contains('.')) ? fileName.split('.').last : 'bin')
              : 'mp4';
      final file = File('${dir.path}/luma_${DateTime.now().millisecondsSinceEpoch}.$ext');
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

// ═══════════════════════════════════════════════════════════════════════════
// LIVE CAMERA PREVIEW TILE (first tile of the gallery grid)
// ═══════════════════════════════════════════════════════════════════════════
class _CameraPreviewTile extends StatefulWidget {
  final VoidCallback onTap;
  const _CameraPreviewTile({required this.onTap});

  @override
  State<_CameraPreviewTile> createState() => _CameraPreviewTileState();
}

class _CameraPreviewTileState extends State<_CameraPreviewTile> {
  CameraController? _controller;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) return;
      final back = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
      final c = CameraController(back, ResolutionPreset.low, enableAudio: false);
      await c.initialize();
      if (!mounted) { c.dispose(); return; }
      setState(() => _controller = c);
    } catch (_) {
      // Preview is optional; tapping the tile still opens the camera.
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return GestureDetector(
      onTap: widget.onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: Colors.black87),
          if (c != null && c.value.isInitialized && c.value.previewSize != null)
            ClipRect(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(width: c.value.previewSize!.height, height: c.value.previewSize!.width, child: CameraPreview(c)),
              ),
            ),
          const Center(child: Icon(Icons.camera_alt, color: Colors.white, size: 28)),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// GALLERY GRID TILE
// ═══════════════════════════════════════════════════════════════════════════
class _AssetThumb extends StatefulWidget {
  final AssetEntity entity;
  final int selectedIndex; // -1 when not selected
  final VoidCallback onTap;
  const _AssetThumb({super.key, required this.entity, required this.selectedIndex, required this.onTap});

  @override
  State<_AssetThumb> createState() => _AssetThumbState();
}

class _AssetThumbState extends State<_AssetThumb> {
  late final Future<Uint8List?> _thumb = widget.entity.thumbnailDataWithSize(const ThumbnailSize(300, 300));

  @override
  Widget build(BuildContext context) {
    final selected = widget.selectedIndex >= 0;
    return GestureDetector(
      onTap: widget.onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<Uint8List?>(
            future: _thumb,
            builder: (context, snap) {
              if (snap.data == null) return Container(color: Colors.grey.withOpacity(0.25));
              return Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true);
            },
          ),
          if (selected) Container(color: Colors.black26),
          if (widget.entity.type == AssetType.video)
            Positioned(
              left: 6, bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                child: Text(_fmtDur(widget.entity.duration), style: const TextStyle(color: Colors.white, fontSize: 11)),
              ),
            ),
          Positioned(
            top: 6, right: 6,
            child: Container(
              width: 24, height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? const Color(0xFF3390EC) : Colors.black26,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: selected ? Text('${widget.selectedIndex + 1}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)) : null,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// LOCATION TAB (Google map + send current / share live)
// ═══════════════════════════════════════════════════════════════════════════
class _LocationTab extends StatefulWidget {
  final void Function(Position) onSendCurrent;
  final void Function(Position, Duration) onShareLive;
  const _LocationTab({required this.onSendCurrent, required this.onShareLive});

  @override
  State<_LocationTab> createState() => _LocationTabState();
}

class _LocationTabState extends State<_LocationTab> {
  Position? _pos;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _locate();
  }

  Future<void> _locate() async {
    setState(() { _loading = true; _error = null; });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) throw 'Turn on location services';
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) throw 'Location permission denied';
      final p = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 15));
      if (!mounted) return;
      setState(() { _pos = p; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e is TimeoutException ? 'Could not get your location. Try again.' : e.toString(); _loading = false; });
    }
  }

  Future<void> _chooseDuration() async {
    final d = await showDialog<Duration>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Share live location for...'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(context, const Duration(minutes: 15)), child: const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('15 minutes'))),
          SimpleDialogOption(onPressed: () => Navigator.pop(context, const Duration(hours: 1)), child: const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('1 hour'))),
          SimpleDialogOption(onPressed: () => Navigator.pop(context, const Duration(hours: 8)), child: const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('8 hours'))),
        ],
      ),
    );
    if (d != null && _pos != null) widget.onShareLive(_pos!, d);
  }

  @override
  Widget build(BuildContext context) {
    final p = _pos;
    return Column(
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            color: Colors.grey.withOpacity(0.15),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.location_off, size: 48, color: Colors.grey),
                          Padding(padding: const EdgeInsets.all(12), child: Text(_error!, textAlign: TextAlign.center)),
                          TextButton(onPressed: _locate, child: const Text('Retry')),
                          TextButton(onPressed: () async { await Geolocator.openAppSettings(); }, child: const Text('Open settings')),
                        ]),
                      )
                    : FlutterMap(
                        options: MapOptions(initialCenter: LatLng(p!.latitude, p.longitude), initialZoom: 16),
                        children: [
                          TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.lumachat.app'),
                          CircleLayer(circles: [CircleMarker(point: LatLng(p.latitude, p.longitude), radius: math.max(p.accuracy, 3), useRadiusInMeter: true, color: Colors.blue.withOpacity(0.12), borderColor: Colors.blue.withOpacity(0.4), borderStrokeWidth: 1)]),
                          MarkerLayer(markers: [Marker(point: LatLng(p.latitude, p.longitude), width: 40, height: 40, child: const Icon(Icons.location_on, color: Colors.red, size: 40))]),
                          const SimpleAttributionWidget(source: Text('OpenStreetMap contributors')),
                        ],
                      ),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 110),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                enabled: p != null,
                leading: const CircleAvatar(backgroundColor: Color(0xFF3390EC), child: Icon(Icons.location_on, color: Colors.white)),
                title: const Text('Send My Current Location', style: TextStyle(color: Color(0xFF3390EC), fontWeight: FontWeight.bold)),
                subtitle: Text(p == null ? 'Locating...' : 'Accurate to ${p.accuracy.round()} meters'),
                onTap: p == null ? null : () => widget.onSendCurrent(p),
              ),
              ListTile(
                enabled: p != null,
                leading: const CircleAvatar(backgroundColor: Colors.green, child: Icon(Icons.location_searching, color: Colors.white)),
                title: const Text('Share My Live Location for...', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                subtitle: const Text('Updated in real time as you move'),
                onTap: p == null ? null : _chooseDuration,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// FULL-SCREEN LOCATION VIEWER (follows live location updates)
// ═══════════════════════════════════════════════════════════════════════════
class _LocationViewerScreen extends StatefulWidget {
  final String chatId;
  final String msgId;
  final double lat;
  final double lng;
  final bool live;
  const _LocationViewerScreen({required this.chatId, required this.msgId, required this.lat, required this.lng, required this.live});

  @override
  State<_LocationViewerScreen> createState() => _LocationViewerScreenState();
}

class _LocationViewerScreenState extends State<_LocationViewerScreen> {
  final MapController _map = MapController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.live ? 'Live location' : 'Location')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').doc(widget.msgId).snapshots(),
        builder: (context, snap) {
          final data = snap.data?.data();
          final lat = (data?['latitude'] as num?)?.toDouble() ?? widget.lat;
          final lng = (data?['longitude'] as num?)?.toDouble() ?? widget.lng;
          final pos = LatLng(lat, lng);
          WidgetsBinding.instance.addPostFrameCallback((_) { try { _map.move(pos, 16); } catch (_) {} });
          return FlutterMap(
            mapController: _map,
            options: MapOptions(initialCenter: pos, initialZoom: 16),
            children: [
              TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.lumachat.app'),
              MarkerLayer(markers: [Marker(point: pos, width: 40, height: 40, child: const Icon(Icons.location_on, color: Colors.red, size: 40))]),
              const SimpleAttributionWidget(source: Text('OpenStreetMap contributors')),
            ],
          );
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// GIPHY PANEL (GIFs and Stickers) via the GIPHY REST API
// Requires: static const String giphyApiKey = '...'; in ApiConfig
// ═══════════════════════════════════════════════════════════════════════════
class _GiphyItem {
  final String preview;
  final String full;
  _GiphyItem(this.preview, this.full);
}

class _GiphyPanel extends StatefulWidget {
  final bool isSticker;
  final String apiKey;
  final void Function(String url) onSelected;
  const _GiphyPanel({super.key, required this.isSticker, required this.apiKey, required this.onSelected});

  @override
  State<_GiphyPanel> createState() => _GiphyPanelState();
}

class _GiphyPanelState extends State<_GiphyPanel> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<_GiphyItem> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.apiKey.isEmpty) {
      setState(() { _loading = false; _error = 'GIPHY API key is missing'; });
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final kind = widget.isSticker ? 'stickers' : 'gifs';
      final q = _ctrl.text.trim();
      final uri = q.isEmpty
          ? Uri.https('api.giphy.com', '/v1/$kind/trending', {'api_key': widget.apiKey, 'limit': '36'})
          : Uri.https('api.giphy.com', '/v1/$kind/search', {'api_key': widget.apiKey, 'q': q, 'limit': '36'});
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) throw Exception('GIPHY error ${res.statusCode}');
      final list = (jsonDecode(res.body)['data'] as List?) ?? [];
      final items = <_GiphyItem>[];
      for (final g in list) {
        final images = g['images'] as Map<String, dynamic>?;
        if (images == null) continue;
        final preview = images['fixed_width']?['url'] ?? images['fixed_height']?['url'];
        final full = images['fixed_height']?['url'] ?? images['original']?['url'];
        if (preview != null && full != null) items.add(_GiphyItem(preview.toString(), full.toString()));
      }
      if (!mounted) return;
      setState(() { _items = items; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = 'Could not load ${widget.isSticker ? 'stickers' : 'GIFs'}'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = widget.isSticker ? 'Stickers' : 'GIFs';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: TextField(
            controller: _ctrl,
            onChanged: (_) { _debounce?.cancel(); _debounce = Timer(const Duration(milliseconds: 450), _load); },
            decoration: InputDecoration(
              hintText: 'Search $label', prefixIcon: const Icon(Icons.search), isDense: true, filled: true,
              fillColor: Colors.grey.withOpacity(0.15),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Row(children: [
            Text(_ctrl.text.trim().isEmpty ? 'Trending $label' : 'Results', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface.withOpacity(0.6))),
            const Spacer(),
            Text('Powered by GIPHY', style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurface.withOpacity(0.4))),
          ]),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Text(_error!), TextButton(onPressed: _load, child: const Text('Retry'))]))
                  : _items.isEmpty
                      ? Center(child: Text('Nothing found', style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6))))
                      : GridView.builder(
                          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6),
                          itemCount: _items.length,
                          itemBuilder: (context, i) {
                            final it = _items[i];
                            return GestureDetector(
                              onTap: () => widget.onSelected(it.full),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: CachedNetworkImage(
                                  imageUrl: it.preview,
                                  fit: widget.isSticker ? BoxFit.contain : BoxFit.cover,
                                  placeholder: (_, __) => Container(color: Colors.grey.withOpacity(0.2)),
                                  errorWidget: (_, __, ___) => Container(color: Colors.grey.withOpacity(0.2), child: const Icon(Icons.broken_image, color: Colors.grey)),
                                ),
                              ),
                            );
                          },
                        ),
        ),
      ],
    );
  }
}
