import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:photo_view/photo_view.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:open_filex/open_filex.dart';

import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../services/cloudinary_service.dart';
import '../../widgets/custom_emoji_picker.dart';

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
    with WidgetsBindingObserver {
  // ═══════════════════════════════════════════════════════════════════════
  // STATE
  // ═══════════════════════════════════════════════════════════════════════
  final _messageController = TextEditingController();
  final _editController = TextEditingController();
  final _scrollController = ScrollController();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final Record _audioRecorder = Record();
  final ImagePicker _picker = ImagePicker();

  bool _isLoading = false;
  bool _showEmojiPicker = false;
  bool _showStickerPicker = false;
  String _pickerTab = 'emoji';
  double _keyboardHeight = 300;

  File? _selectedImage;
  File? _selectedVideo;
  String? _recordingPath;
  bool _isRecording = false;
  bool _isRecordingLocked = false;
  double _recordingSlideOffset = 0;
  double? _recordingDragStartX;
  int _recordingSeconds = 0;
  Timer? _recordingTimer;
  Timer? _recordingSecondsTimer;
  final List<double> _recordingWave = [];

  // Channel info
  String? _channelAvatarUrl;
  String? _channelDescription;
  String? _channelLink;
  String? _channelUsername;
  String? _linkedGroupId;
  int _subscriberCount = 0;
  bool _signaturesEnabled = true;
  bool _silentMode = false;
  DateTime? _scheduledAt;
  String? _myRole = 'member';

  // Audio
  bool _isPlayingAudio = false;
  String? _currentlyPlayingAudioId;
  Duration _audioDuration = Duration.zero;
  Duration _audioPosition = Duration.zero;

  // Composer state
  String? _editingMessageId;
  String? _replyingTo;
  String? _replyingToContent;
  String? _replyingToSender;

  // Reactions cache
  static const _quickReactions = ['👍', '❤️', '🔥', '😂', '😮', '🎉'];

  // Pinned
  Map<String, dynamic>? _pinnedMessage;
  StreamSubscription<QuerySnapshot>? _pinnedMessageSub;
  StreamSubscription<DocumentSnapshot>? _channelSub;

  // Comments count cache (messageId -> count) — populated on demand
  final Map<String, int> _commentCounts = {};

  Stream<QuerySnapshot> get _messagesStream => FirebaseFirestore.instance
      .collection('chats')
      .doc(widget.channelId)
      .collection('messages')
      .orderBy('created_at', descending: true)
      .snapshots();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAudioPlayer();
    _loadChannelInfo();
    _subscribeToChannel();
    _listenToPinnedMessage();
    _messageController.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
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
      setState(() => _isPlayingAudio = state.playing);
      if (state.processingState == ProcessingState.completed) {
        setState(() {
          _currentlyPlayingAudioId = null;
          _audioPosition = Duration.zero;
        });
      }
    });
  }

  Future<void> _loadChannelInfo() async {
    final doc = await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.channelId)
        .get();
    if (doc.exists && mounted) {
      final data = doc.data()!;
      setState(() {
        _channelAvatarUrl = data['avatar_url'] as String?;
        _channelDescription = data['description'] as String?;
        _channelLink = data['invitation_link'] as String?;
        _channelUsername = data['username'] as String?;
        _linkedGroupId = data['linked_group_id'] as String?;
        _signaturesEnabled = data['signatures_enabled'] as bool? ?? true;
        final parts =
            List<dynamic>.from(data['participants'] ?? const []);
        _subscriberCount = parts.length;
      });
    }
  }

  void _subscribeToChannel() {
    _channelSub?.cancel();
    _channelSub = FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.channelId)
        .snapshots()
        .listen((doc) {
      if (!mounted || !doc.exists) return;
      final data = doc.data() as Map<String, dynamic>;
      final parts = List<dynamic>.from(data['participants'] ?? const []);
      setState(() {
        _channelAvatarUrl = data['avatar_url'] as String? ?? _channelAvatarUrl;
        _channelDescription =
            data['description'] as String? ?? _channelDescription;
        _channelLink =
            data['invitation_link'] as String? ?? _channelLink;
        _channelUsername = data['username'] as String? ?? _channelUsername;
        _linkedGroupId =
            data['linked_group_id'] as String? ?? _linkedGroupId;
        _signaturesEnabled =
            data['signatures_enabled'] as bool? ?? _signaturesEnabled;
        _subscriberCount = parts.length;
      });
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
      final pinnedDoc = snapshot.docs.first;
      final messageId = pinnedDoc.data()['message_id'] as String?;
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

  bool get _isAdmin => _myRole == 'owner' || _myRole == 'admin';

  // ═══════════════════════════════════════════════════════════════════════
  // SEND
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _sendMessage({
    String? text,
    String? mediaUrl,
    String? mediaType,
    String? fileName,
    String? fileSize,
    int? duration,
    bool viewOnce = false,
  }) async {
    final content = text ?? _messageController.text.trim();
    if (content.isEmpty &&
        mediaUrl == null &&
        _selectedImage == null &&
        _selectedVideo == null &&
        _recordingPath == null) {
      return;
    }

    setState(() => _isLoading = true);

    try {
      final authProvider =
          Provider.of<LumaAuthProvider>(context, listen: false);
      final userId = authProvider.user?.uid ?? authProvider.mockUserId;
      if (userId == null) throw Exception('Not authenticated');

      // Load sender profile for signature (if signatures enabled)
      String? senderName;
      String? senderAvatar;
      if (_signaturesEnabled) {
        final userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(userId)
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

      final now = DateTime.now();
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
        'sender_id': userId,
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
        'reactions': {},
        'views_count': 0,
        'post_type': 'message',
      });

      // Auto-delete silent flag from local state
      _silentMode = false;
      _scheduledAt = null;

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
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.channelId)
          .collection('messages')
          .doc(messageId)
          .update({
        'text': newContent.trim(),
        'content': newContent.trim(),
        'is_edited': true,
        'updated_at': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Message edited')),
        );
      }
    } catch (e) {
      _showError('Edit failed: $e');
    }
  }

  Future<void> _deleteMessageForEveryone(String messageId) async {
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

  Future<void> _pinMessage(String messageId) async {
    try {
      final authProvider =
          Provider.of<LumaAuthProvider>(context, listen: false);
      final userId = authProvider.user?.uid ?? authProvider.mockUserId;

      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.channelId)
          .collection('pinned_messages')
          .doc(messageId)
          .set({
        'message_id': messageId,
        'pinned_at': FieldValue.serverTimestamp(),
        'pinned_by': userId,
      });
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.channelId)
          .update({'pinned_message_id': messageId});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Message pinned')),
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
          const SnackBar(content: Text('Message unpinned')),
        );
      }
    } catch (e) {
      _showError('Unpin failed: $e');
    }
  }

  Future<void> _toggleReaction(String messageId, String emoji) async {
    try {
      final authProvider =
          Provider.of<LumaAuthProvider>(context, listen: false);
      final userId = authProvider.user?.uid ?? authProvider.mockUserId;
      if (userId == null) return;

      final messageRef = FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.channelId)
          .collection('messages')
          .doc(messageId);

      final doc = await messageRef.get();
      if (!doc.exists) return;

      final reactions =
          Map<String, dynamic>.from(doc.data()?['reactions'] ?? {});
      final users = List<String>.from(reactions[emoji] ?? []);

      if (users.contains(userId)) {
        users.remove(userId);
        if (users.isEmpty) {
          reactions.remove(emoji);
        } else {
          reactions[emoji] = users;
        }
      } else {
        users.add(userId);
        reactions[emoji] = users;
      }

      await messageRef.update({'reactions': reactions});
    } catch (e) {
      debugPrint('Reaction error: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // MEDIA PICKERS
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _pickImage() async {
    final picked = await _picker.pickImage(
        source: ImageSource.gallery, imageQuality: 80);
    if (picked != null) setState(() => _selectedImage = File(picked.path));
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
    if (result != null && result.files.isNotEmpty) {
      final file = result.files.first;
      if (file.path != null) {
        final uploaded = await CloudinaryService.uploadFile(
            File(file.path!), 'luma/channels/${widget.channelId}');
        if (uploaded != null) {
          await _sendMessage(
            text: null,
            mediaUrl: uploaded,
            mediaType: 'file',
            fileName: file.name,
            fileSize: _formatFileSize(file.size),
          );
        } else {
          _showError('File upload failed');
        }
      }
    }
  }

  Future<void> _startRecording() async {
    final hasPermission = await _audioRecorder.hasPermission();
    if (!hasPermission) {
      _showError('Microphone permission required');
      return;
    }
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _audioRecorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: path,
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
  }

  Future<void> _stopRecordingAndSend() async {
    _recordingTimer?.cancel();
    _recordingSecondsTimer?.cancel();
    final path = await _audioRecorder.stop();
    if (!mounted) return;
    setState(() {
      _isRecording = false;
      _isRecordingLocked = false;
      _recordingSlideOffset = 0;
    });
    if (path != null) {
      _recordingPath = path;
      await _sendMessage();
      setState(() => _recordingPath = null);
    }
  }

  Future<void> _cancelRecording() async {
    _recordingTimer?.cancel();
    _recordingSecondsTimer?.cancel();
    await _audioRecorder.stop();
    if (_recordingPath != null) {
      final file = File(_recordingPath!);
      if (await file.exists()) await file.delete();
    }
    if (!mounted) return;
    setState(() {
      _isRecording = false;
      _isRecordingLocked = false;
      _recordingSlideOffset = 0;
      _recordingPath = null;
      _recordingSeconds = 0;
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

  // ═══════════════════════════════════════════════════════════════════════
  // FORMATTERS
  // ═══════════════════════════════════════════════════════════════════════
  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatTime(Timestamp? timestamp) {
    if (timestamp == null) return '';
    return DateFormat('HH:mm').format(timestamp.toDate());
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

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // MESSAGE OPTIONS — Telegram style floating panel
  // ═══════════════════════════════════════════════════════════════════════
  void _showMessageOptions(Map<String, dynamic> msg, bool isMe) {
    final isDeleted = msg['deleted_for_everyone'] == true;
    final messageId = msg['id'] as String?;
    if (messageId == null) return;

    final bool isPinned =
        _pinnedMessage != null && _pinnedMessage!['id'] == messageId;

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'dismiss',
      barrierColor: Colors.black.withOpacity(0.4),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (ctx, _, __) {
        return _ChannelMessageOptionsOverlay(
          message: msg,
          isMe: isMe,
          isDeleted: isDeleted,
          isPinned: isPinned,
          isAdmin: _isAdmin,
          onReact: (e) {
            Navigator.pop(ctx);
            _toggleReaction(messageId, e);
          },
          onEdit: () {
            Navigator.pop(ctx);
            _showEditDialog(
                messageId, msg['text'] ?? msg['content'] ?? '');
          },
          onCopy: () {
            Navigator.pop(ctx);
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
            _saveToSavedMessages(msg);
          },
          onDelete: () {
            Navigator.pop(ctx);
            _confirmDelete(messageId);
          },
          onReport: () {
            Navigator.pop(ctx);
            _reportMessage(msg);
          },
        );
      },
    );
  }

  Future<void> _forwardMessage(Map<String, dynamic> msg) async {
    // Basic forward: just show a snackbar; extend with chat picker if needed
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Forwarding...')),
    );
  }

  Future<void> _saveToSavedMessages(Map<String, dynamic> msg) async {
    try {
      final authProvider =
          Provider.of<LumaAuthProvider>(context, listen: false);
      final userId = authProvider.user?.uid ?? authProvider.mockUserId;
      if (userId == null) return;
      await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('saved')
          .add({
        'text': msg['text'] ?? msg['content'],
        'media_url': msg['media_url'],
        'media_type': msg['media_type'],
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

  Future<void> _reportMessage(Map<String, dynamic> msg) async {
    try {
      final authProvider =
          Provider.of<LumaAuthProvider>(context, listen: false);
      final userId = authProvider.user?.uid ?? authProvider.mockUserId;
      await FirebaseFirestore.instance.collection('reports').add({
        'reporter_id': userId,
        'channel_id': widget.channelId,
        'message_id': msg['id'],
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
        title: const Text('Edit Message'),
        content: TextField(
          controller: _editController,
          maxLines: null,
          decoration: const InputDecoration(
            hintText: 'Edit your message...',
          ),
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

  void _confirmDelete(String messageId) {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete for Everyone?'),
        content: const Text(
            'This will delete the message for all subscribers.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteMessageForEveryone(messageId);
            },
            style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // ATTACHMENT MENU — Telegram channel style (rows of circles)
  // ═══════════════════════════════════════════════════════════════════════
  void _showAttachmentMenu() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor:
          isDark ? const Color(0xFF17212B) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
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
                    _pickImage();
                  }),
                  _attachTile(theme, Icons.camera_alt_outlined,
                      'Camera', () {
                    Navigator.pop(context);
                    _takePhoto();
                  }),
                  _attachTile(theme, Icons.videocam_outlined, 'Video',
                      () {
                    Navigator.pop(context);
                    _pickVideo();
                  }),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  _attachTile(theme, Icons.videocam, 'Record', () {
                    Navigator.pop(context);
                    _recordVideo();
                  }),
                  _attachTile(theme, Icons.insert_drive_file_outlined,
                      'File', () {
                    Navigator.pop(context);
                    _pickFile();
                  }),
                  _attachTile(theme, Icons.poll_outlined, 'Poll', () {
                    Navigator.pop(context);
                    _createPoll();
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

  Future<void> _createPoll() async {
    // Minimal poll composer — extend as needed
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create Poll'),
        content: TextField(
          controller: ctrl,
          decoration:
              const InputDecoration(hintText: 'Ask a question...'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Next'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      final ref = FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.channelId)
          .collection('messages')
          .doc();
      final authProvider =
          Provider.of<LumaAuthProvider>(context, listen: false);
      final userId = authProvider.user?.uid ?? authProvider.mockUserId;
      await ref.set({
        'id': ref.id,
        'text': result,
        'content': result,
        'media_type': 'poll',
        'post_type': 'poll',
        'poll_options': [],
        'poll_votes': {},
        'sender_id': userId,
        'created_at': FieldValue.serverTimestamp(),
        'deleted_for_everyone': false,
        'reactions': {},
        'views_count': 0,
      });
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // UI: HEADER
  // ═══════════════════════════════════════════════════════════════════════
  PreferredSizeWidget _buildChannelHeader(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    // Public = blue, private = gray (Telegram convention)
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
                    icon: Icons.arrow_back,
                    onTap: () => Navigator.pop(context),
                  ),
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
                // Search in channel
                _headerCircleBtn(
                  icon: Icons.search,
                  onTap: _openSearch,
                ),
                // Monoforum / Direct messages bubble
                if (true)
                  _headerCircleBtn(
                    icon: Icons.forum_outlined,
                    onTap: _openMonoforum,
                  ),
                _headerCircleBtn(
                  icon: Icons.more_vert,
                  onTap: _showChannelMoreMenu,
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _headerCircleBtn({
    required IconData icon,
    required VoidCallback onTap,
  }) {
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
    // Placeholder — hook into a monoforum screen if available
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Direct messages coming soon')),
    );
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
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Statistics coming soon')),
                  );
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
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Link: $link')),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.share,
                  color: theme.colorScheme.primary),
              title: const Text('Share channel'),
              onTap: () => Navigator.pop(context),
            ),
            if (!_isPublicChannel)
              ListTile(
                leading: const Icon(Icons.public,
                    color: Color(0xFF3390EC)),
                title: const Text('Make public'),
                onTap: () => Navigator.pop(context),
              ),
          ],
        ),
      ),
    );
  }

  void _goToChannelInfo() {
    Navigator.pushNamed(context, '/channel_info', arguments: {
      'chatId': widget.channelId,
      'chatName': widget.channelName,
      'chatAvatar': _channelAvatarUrl,
    });
  }

  // ═══════════════════════════════════════════════════════════════════════
  // UI: PINNED BANNER
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildPinnedMessageBanner(ThemeData theme) {
    if (_pinnedMessage == null) return const SizedBox.shrink();

    final text = _pinnedMessage!['text'] ??
        _pinnedMessage!['content'] ??
        'Pinned message';
    final sender = _pinnedMessage!['sender_name'] ?? 'Channel';

    return GestureDetector(
      onTap: () {
        final idx = 0;
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
        debugPrint('Scroll to pinned: $idx');
      },
      child: Container(
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
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // UI: MESSAGE LIST — channel-style post bubbles
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildMessageList(
      ThemeData theme, List<QueryDocumentSnapshot> messages, String? userId) {
    return ListView.builder(
      reverse: true,
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final msg = messages[index].data() as Map<String, dynamic>;
        msg['id'] = messages[index].id;
        final isMe = msg['sender_id'] == userId;
        return _ChannelPostBubble(
          message: msg,
          isMe: isMe,
          isAdmin: _isAdmin,
          signaturesEnabled: _signaturesEnabled,
          linkedGroupId: _linkedGroupId,
          onLongPress: () => _showMessageOptions(msg, isMe),
          onReaction: (e) => _toggleReaction(msg['id'], e),
          onComment: () => _openComments(msg['id']),
          onShare: () => _sharePost(msg),
          onViewImage: _showImageViewer,
          onPlayAudio: _playAudio,
          playingAudioId: _currentlyPlayingAudioId,
          isPlayingAudio: _isPlayingAudio,
          audioPosition: _audioPosition,
          audioDuration: _audioDuration,
          formatTime: _formatTime,
          formatDuration: _formatDuration,
          formatViewCount: _formatViewCount,
          onDelete: () => _confirmDelete(msg['id']),
          onEdit: () => _showEditDialog(
              msg['id'], msg['text'] ?? msg['content'] ?? ''),
          onPin: () => _pinMessage(msg['id']),
          onUnpin: () => _unpinMessage(msg['id']),
          isPinned: _pinnedMessage != null &&
              _pinnedMessage!['id'] == msg['id'],
        );
      },
    );
  }

  void _openComments(String messageId) {
    // Placeholder — hook into a comments screen if available
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Comments coming soon')),
    );
  }

  void _sharePost(Map<String, dynamic> msg) {
    final link =
        _channelLink ?? 'https://t.me/${_channelUsername ?? widget.channelId}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Share: $link')),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // UI: COMPOSER
  // ═══════════════════════════════════════════════════════════════════════
  Widget _buildComposer(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    final hasText = _messageController.text.trim().isNotEmpty;
    final hasMedia = _selectedImage != null || _selectedVideo != null;

    return Container(
      color: isDark ? const Color(0xFF17212B) : Colors.white,
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Silent / schedule indicators
            if (_silentMode || _scheduledAt != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                child: Row(
                  children: [
                    if (_silentMode)
                      Container(
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary
                              .withOpacity(0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.notifications_off,
                                size: 12,
                                color: theme.colorScheme.primary),
                            const SizedBox(width: 4),
                            Text('Silent',
                                style: TextStyle(
                                    color: theme.colorScheme.primary,
                                    fontSize: 11)),
                            const SizedBox(width: 4),
                            GestureDetector(
                              onTap: () =>
                                  setState(() => _silentMode = false),
                              child: Icon(Icons.close,
                                  size: 12,
                                  color: theme.colorScheme.primary),
                            ),
                          ],
                        ),
                      ),
                    if (_scheduledAt != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary
                              .withOpacity(0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.schedule,
                                size: 12,
                                color: theme.colorScheme.primary),
                            const SizedBox(width: 4),
                            Text(
                                DateFormat('MMM d, HH:mm')
                                    .format(_scheduledAt!),
                                style: TextStyle(
                                    color: theme.colorScheme.primary,
                                    fontSize: 11)),
                            const SizedBox(width: 4),
                            GestureDetector(
                              onTap: () =>
                                  setState(() => _scheduledAt = null),
                              child: Icon(Icons.close,
                                  size: 12,
                                  color: theme.colorScheme.primary),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),

            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                GestureDetector(
                  onTap: _showAttachmentMenu,
                  child: Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    child: Icon(Icons.attach_file,
                        size: 24,
                        color:
                            theme.colorScheme.onSurface.withOpacity(0.6)),
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
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Send button
                GestureDetector(
                  onTap: _isLoading ? null : () => _sendMessage(),
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
                            hasMedia
                                ? Icons.send
                                : (hasText
                                    ? Icons.send
                                    : Icons.send),
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

  // ═══════════════════════════════════════════════════════════════════════
  // UI: RECORDING BAR
  // ═══════════════════════════════════════════════════════════════════════
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
            onTap: _cancelRecording,
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
          IconButton(
            icon: Icon(Icons.send, color: theme.colorScheme.primary),
            onPressed: _stopRecordingAndSend,
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final authProvider = Provider.of<LumaAuthProvider>(context);
    final userId = authProvider.user?.uid ?? authProvider.mockUserId;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: _buildChannelHeader(theme),
      body: Column(
        children: [
          _buildPinnedMessageBanner(theme),

          // Role gate — check admin permission
          FutureBuilder<DocumentSnapshot>(
            future: FirebaseFirestore.instance
                .collection('chats')
                .doc(widget.channelId)
                .get(),
            builder: (context, snapshot) {
              if (snapshot.hasData && snapshot.data!.exists) {
                final data =
                    snapshot.data!.data() as Map<String, dynamic>;
                final role =
                    (data['participants_data']?[userId]?['role'] ??
                        'member') as String;
                _myRole = role;
              }
              return const SizedBox.shrink();
            },
          ),

          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _messagesStream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                      child: Text('Error: ${snapshot.error}'));
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
                        Text(
                          'No posts yet',
                          style: TextStyle(
                            color: theme.colorScheme.onSurface
                                .withOpacity(0.5),
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return _buildMessageList(theme, messages, userId);
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
          if (_showEmojiPicker)
            CustomEmojiPicker(
              onEmojiSelected: (emoji) =>
                  setState(() => _messageController.text += emoji),
              onClose: () =>
                  setState(() => _showEmojiPicker = false),
            ),

          _isAdmin
              ? _buildComposer(theme)
              : Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  color:
                      theme.colorScheme.onSurface.withOpacity(0.03),
                  child: Center(
                    child: Text(
                      'Only admins can post in this channel',
                      style: TextStyle(
                        color: theme.colorScheme.onSurface
                            .withOpacity(0.4),
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
        ],
      ),
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _audioPlayer.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageController.removeListener(_onTextChanged);
    _messageController.dispose();
    _editController.dispose();
    _scrollController.dispose();
    _audioPlayer.dispose();
    _audioRecorder.dispose();
    _recordingTimer?.cancel();
    _recordingSecondsTimer?.cancel();
    _pinnedMessageSub?.cancel();
    _channelSub?.cancel();
    super.dispose();
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// CHANNEL POST BUBBLE — Telegram channel layout (name + photo BELOW)
// ═══════════════════════════════════════════════════════════════════════════
class _ChannelPostBubble extends StatelessWidget {
  final Map<String, dynamic> message;
  final bool isMe;
  final bool isAdmin;
  final bool signaturesEnabled;
  final String? linkedGroupId;
  final VoidCallback onLongPress;
  final ValueChanged<String> onReaction;
  final VoidCallback onComment;
  final VoidCallback onShare;
  final void Function(String url) onViewImage;
  final void Function(String id, String url) onPlayAudio;
  final String? playingAudioId;
  final bool isPlayingAudio;
  final Duration audioPosition;
  final Duration audioDuration;
  final String Function(Timestamp?) formatTime;
  final String Function(int) formatDuration;
  final String Function(int) formatViewCount;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final VoidCallback onPin;
  final VoidCallback onUnpin;
  final bool isPinned;

  const _ChannelPostBubble({
    required this.message,
    required this.isMe,
    required this.isAdmin,
    required this.signaturesEnabled,
    required this.linkedGroupId,
    required this.onLongPress,
    required this.onReaction,
    required this.onComment,
    required this.onShare,
    required this.onViewImage,
    required this.onPlayAudio,
    required this.playingAudioId,
    required this.isPlayingAudio,
    required this.audioPosition,
    required this.audioDuration,
    required this.formatTime,
    required this.formatDuration,
    required this.formatViewCount,
    required this.onDelete,
    required this.onEdit,
    required this.onPin,
    required this.onUnpin,
    required this.isPinned,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isDeleted = message['deleted_for_everyone'] == true;
    final mediaType = message['media_type'] as String?;
    final mediaUrl = message['media_url'] ?? message['image_url'];
    final reactions =
        Map<String, dynamic>.from(message['reactions'] ?? {});
    final viewsCount = (message['views_count'] as int?) ?? 0;
    final commentCount =
        (message['comments_count'] as int?) ?? 0;
    final postType = message['post_type'] as String? ?? 'message';

    final bubbleColor =
        isDark ? const Color(0xFF182533) : Colors.white;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Align(
        alignment: Alignment.centerLeft,
        child: GestureDetector(
          onLongPress: onLongPress,
          onTap: onLongPress,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.85,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Main bubble
                Container(
                  decoration: BoxDecoration(
                    color: bubbleColor,
                    borderRadius: BorderRadius.circular(12),
                    border: isPinned
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
                      // Reply preview
                      if (message['reply_to'] != null)
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
                                message['reply_to_sender'] ?? 'Unknown',
                                style: TextStyle(
                                  color: theme.colorScheme.primary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                message['reply_to_content'] ?? '',
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

                      // Silent / scheduled badges
                      if (message['is_silent'] == true)
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
                      if (message['is_scheduled'] == true)
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

                      // Content
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
                      else if (mediaType == 'image' && mediaUrl != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: GestureDetector(
                            onTap: () => onViewImage(mediaUrl),
                            child: CachedNetworkImage(
                              imageUrl: mediaUrl,
                              fit: BoxFit.cover,
                              placeholder: (_, __) => Container(
                                height: 200,
                                color: theme.colorScheme.onSurface
                                    .withOpacity(0.05),
                                child: Center(
                                  child: CircularProgressIndicator(
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        )
                      else if (mediaType == 'video' && mediaUrl != null)
                        _buildVideoThumbnail(theme, mediaUrl)
                      else if (mediaType == 'audio' && mediaUrl != null)
                        _buildVoiceNote(theme, mediaUrl)
                      else if (mediaType == 'file')
                        _buildFileMessage(theme)
                      else if ((message['text'] ?? message['content'] ?? '')
                          .toString()
                          .isNotEmpty)
                        Text(
                          (message['text'] ?? message['content'])
                              .toString(),
                          style: TextStyle(
                            color: theme.colorScheme.onSurface,
                            fontSize: 15,
                            height: 1.4,
                          ),
                        ),

                      // Reactions pill
                      if (reactions.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
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
                    ],
                  ),
                ),

                // ── Footer: view counter, share, discuss ──
                Padding(
                  padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
                  child: Row(
                    children: [
                      // View counter
                      Icon(Icons.remove_red_eye_outlined,
                          size: 14,
                          color: theme.colorScheme.onSurface
                              .withOpacity(0.5)),
                      const SizedBox(width: 3),
                      Text(
                        formatViewCount(viewsCount),
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface
                              .withOpacity(0.5),
                        ),
                      ),

                      // Comment / discuss button (only if linked group)
                      if (linkedGroupId != null) ...[
                        const SizedBox(width: 14),
                        GestureDetector(
                          onTap: onComment,
                          child: Row(
                            children: [
                              Icon(Icons.mode_comment_outlined,
                                  size: 14,
                                  color: theme.colorScheme
                                      .onSurface
                                      .withOpacity(0.5)),
                              const SizedBox(width: 3),
                              Text(
                                commentCount > 0
                                    ? '$commentCount'
                                    : 'Discuss',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme
                                      .onSurface
                                      .withOpacity(0.5),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      const Spacer(),

                      // Share
                      GestureDetector(
                        onTap: onShare,
                        child: Icon(Icons.share_outlined,
                            size: 14,
                            color: theme.colorScheme.onSurface
                                .withOpacity(0.5)),
                      ),
                    ],
                  ),
                ),

                // ── Channel signature (name + avatar) BELOW ──
                Padding(
                  padding:
                      const EdgeInsets.only(top: 2, left: 4, right: 4),
                  child: Row(
                    children: [
                      Text(
                        formatTime(message['created_at'] as Timestamp?),
                        style: TextStyle(
                          fontSize: 11,
                          color:
                              theme.colorScheme.onSurface.withOpacity(0.5),
                        ),
                      ),
                      const Spacer(),
                      if (signaturesEnabled &&
                          message['sender_name'] != null)
                        Text(
                          message['sender_name'] as String,
                          style: TextStyle(
                            color: theme.colorScheme.primary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      if (signaturesEnabled &&
                          message['sender_name'] != null)
                        const SizedBox(width: 6),
                      if (signaturesEnabled &&
                          message['sender_avatar'] != null)
                        CircleAvatar(
                          radius: 10,
                          backgroundImage: NetworkImage(
                              message['sender_avatar'] as String),
                          onBackgroundImageError: (_, __) {},
                          child: message['sender_avatar'] == null
                              ? Icon(Icons.person,
                                  size: 12,
                                  color: theme.colorScheme.primary)
                              : null,
                        ),
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

  Widget _buildPoll(ThemeData theme) {
    final options = List<dynamic>.from(message['poll_options'] ?? []);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          message['text'] ?? message['content'] ?? 'Poll',
          style: TextStyle(
            color: theme.colorScheme.onSurface,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        if (options.isEmpty)
          Text(
            'No options yet',
            style: TextStyle(
                color: theme.colorScheme.onSurface.withOpacity(0.4),
                fontSize: 12),
          )
        else
          for (final o in options)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color:
                      theme.colorScheme.onSurface.withOpacity(0.05),
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

  Widget _buildVideoThumbnail(ThemeData theme, String videoUrl) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 200,
        color: Colors.black,
        child: const Center(
          child: Icon(Icons.play_circle_fill,
              color: Colors.white, size: 50),
        ),
      ),
    );
  }

  Widget _buildVoiceNote(ThemeData theme, String audioUrl) {
    final isCurrent = playingAudioId == message['id'];
    final total = isCurrent && audioDuration != Duration.zero
        ? audioDuration
        : Duration(seconds: (message['duration'] as int?) ?? 0);
    final progress = total.inMilliseconds > 0
        ? audioPosition.inMilliseconds / total.inMilliseconds
        : 0.0;

    return Container(
      width: 240,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => onPlayAudio(message['id'], audioUrl),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                isCurrent && isPlayingAudio
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
                      ? '${formatDuration(audioPosition.inSeconds)} / ${formatDuration(total.inSeconds)}'
                      : formatDuration(total.inSeconds),
                  style: TextStyle(
                    fontSize: 11,
                    color:
                        theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileMessage(ThemeData theme) {
    final fileName = message['file_name'] as String? ??
        message['text'] ??
        'File';
    final fileSize = message['file_size'] as String?;
    return Container(
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
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// CHANNEL MESSAGE OPTIONS OVERLAY — Telegram-style floating panel
// ═══════════════════════════════════════════════════════════════════════════
class _ChannelMessageOptionsOverlay extends StatelessWidget {
  final Map<String, dynamic> message;
  final bool isMe;
  final bool isDeleted;
  final bool isPinned;
  final bool isAdmin;
  final void Function(String emoji) onReact;
  final VoidCallback onEdit;
  final VoidCallback onCopy;
  final VoidCallback onReply;
  final VoidCallback onForward;
  final VoidCallback onPinToggle;
  final VoidCallback onSave;
  final VoidCallback onDelete;
  final VoidCallback onReport;

  const _ChannelMessageOptionsOverlay({
    required this.message,
    required this.isMe,
    required this.isDeleted,
    required this.isPinned,
    required this.isAdmin,
    required this.onReact,
    required this.onEdit,
    required this.onCopy,
    required this.onReply,
    required this.onForward,
    required this.onPinToggle,
    required this.onSave,
    required this.onDelete,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    const bg = Color(0xFF17212B);

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

                // Menu
                Container(
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isMe || isAdmin)
                        _tile(Icons.edit_outlined, 'Edit', onEdit),
                      _tile(Icons.reply, 'Reply', onReply),
                      _tile(Icons.content_copy, 'Copy',
                          onCopy),
                      _tile(Icons.forward, 'Forward', onForward),
                      _tile(
                        isPinned
                            ? Icons.push_pin
                            : Icons.push_pin_outlined,
                        isPinned ? 'Unpin' : 'Pin',
                        onPinToggle,
                      ),
                      _tile(Icons.bookmark_outline, 'Save',
                          onSave),
                      if (!isMe)
                        _tile(Icons.report_outlined, 'Report',
                            onReport),
                      if (isMe || isAdmin)
                        _tile(Icons.delete_outline, 'Delete',
                            onDelete,
                            color: Colors.redAccent),
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

  Widget _tile(IconData icon, String label, VoidCallback onTap,
      {Color color = Colors.white}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
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
// CHANNEL SEARCH DELEGATE — search posts inside the channel
// ═══════════════════════════════════════════════════════════════════════════
class _ChannelSearchDelegate extends SearchDelegate<String?> {
  final String channelId;
  final String channelName;
  _ChannelSearchDelegate({
    required this.channelId,
    required this.channelName,
  });

  @override
  List<Widget> buildActions(BuildContext context) {
    return [
      IconButton(
        icon: const Icon(Icons.clear),
        onPressed: () => query = '',
      ),
    ];
  }

  @override
  Widget buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () => close(context, null),
    );
  }

  @override
  Widget buildResults(BuildContext context) => _buildResults(context);

  @override
  Widget buildSuggestions(BuildContext context) => _buildResults(context);

  Widget _buildResults(BuildContext context) {
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
            return ListTile(
              title: Text(
                (d['text'] ?? d['content'] ?? '')
                    .toString()
                    .substring(0,
                        ((d['text'] ?? d['content'] ?? '')
                                    .toString()
                                    .length >
                                80)
                            ? 80
                            : (d['text'] ?? d['content'] ?? '')
                                .toString()
                                .length),
              ),
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
