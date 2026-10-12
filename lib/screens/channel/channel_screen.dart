import 'dart:async';
import 'dart:io';
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

class _ChannelChatScreenState extends State<ChannelChatScreen> {
  final _messageController = TextEditingController();
  final _editController = TextEditingController();
  final _scrollController = ScrollController();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final Record _audioRecorder = Record();

  bool _isLoading = false;
  bool _showEmojiPicker = false;
  File? _selectedImage;
  File? _selectedVideo;
  String? _recordingPath;
  bool _isRecording = false;
  int _recordingSeconds = 0;
  Timer? _recordingTimer;

  String? _channelAvatarUrl;
  String? _channelDescription;
  String? _channelLink;

  bool _isPlayingAudio = false;
  String? _currentlyPlayingAudioId;
  Duration _audioDuration = Duration.zero;
  Duration _audioPosition = Duration.zero;

  String? _editingMessageId;
  String? _replyingTo;
  String? _replyingToContent;
  String? _replyingToSender;

  Map<String, dynamic>? _pinnedMessage;
  StreamSubscription<QuerySnapshot>? _pinnedMessageSub;

  Stream<QuerySnapshot> get _messagesStream => FirebaseFirestore.instance
      .collection('chats')
      .doc(widget.channelId)
      .collection('messages')
      .orderBy('created_at', descending: true)
      .snapshots();

  @override
  void initState() {
    super.initState();
    _initAudioPlayer();
    _loadChannelInfo();
    _messageController.addListener(_onTextChanged);
    _listenToPinnedMessage();
  }

  void _listenToPinnedMessage() {
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

  void _onTextChanged() {
    setState(() {});
  }

  void _initAudioPlayer() {
    _audioPlayer.durationStream.listen((d) {
      if (mounted && d != null) setState(() => _audioDuration = d);
    });
    _audioPlayer.positionStream.listen((p) {
      if (mounted) setState(() => _audioPosition = p);
    });
    _audioPlayer.playerStateStream.listen((state) {
      if (mounted) {
        setState(() => _isPlayingAudio = state.playing);
        if (state.processingState == ProcessingState.completed) {
          setState(() {
            _currentlyPlayingAudioId = null;
            _audioPosition = Duration.zero;
          });
        }
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
      });
    }
  }

  void _goToChannelInfo() {
    Navigator.pushNamed(context, '/channel_info', arguments: {
      'chatId': widget.channelId,
      'chatName': widget.channelName,
      'chatAvatar': _channelAvatarUrl,
    });
  }

  Future<void> _sendMessage({
    String? text,
    String? mediaUrl,
    String? mediaType,
    String? fileName,
    String? fileSize,
    int? duration,
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

      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();
      final userData = userDoc.data() ?? {};
      final senderName = userData['display_name'] ??
          userData['username'] ??
          userData['name'] ??
          'Admin';
      final senderAvatar = userData['avatar_url'];

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
        'reply_to': _replyingTo,
        'reply_to_content': _replyingToContent,
        'reply_to_sender': _replyingToSender,
        'created_at': FieldValue.serverTimestamp(),
        'is_edited': false,
        'deleted_for_everyone': false,
        'reactions': {},
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

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
        source: ImageSource.gallery, imageQuality: 80);
    if (picked != null) setState(() => _selectedImage = File(picked.path));
  }

  Future<void> _takePhoto() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
        source: ImageSource.camera, imageQuality: 80);
    if (picked != null) setState(() => _selectedImage = File(picked.path));
  }

  Future<void> _pickVideo() async {
    final picker = ImagePicker();
    final picked = await picker.pickVideo(source: ImageSource.gallery);
    if (picked != null) setState(() => _selectedVideo = File(picked.path));
  }

  Future<void> _recordVideo() async {
    final picker = ImagePicker();
    final picked = await picker.pickVideo(source: ImageSource.camera);
    if (picked != null) setState(() => _selectedVideo = File(picked.path));
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform
        .pickFiles(allowMultiple: false, withData: true);
    if (result != null && result.files.isNotEmpty) {
      final file = result.files.first;
      if (file.path != null) {
        await _sendMessage(
          text: '📎 ${file.name}',
          mediaType: 'file',
          fileName: file.name,
          fileSize: _formatFileSize(file.size),
        );
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
        '${dir.path}/voice_note_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _audioRecorder.start(path: path, encoder: AudioEncoder.aacLc);
    setState(() {
      _isRecording = true;
      _recordingPath = path;
      _recordingSeconds = 0;
    });
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _recordingSeconds++);
    });
  }

  Future<void> _stopRecordingAndSend() async {
    _recordingTimer?.cancel();
    final path = await _audioRecorder.stop();
    setState(() => _isRecording = false);
    if (path != null) {
      await _sendMessage();
      setState(() => _recordingPath = null);
    }
  }

  Future<void> _cancelRecording() async {
    _recordingTimer?.cancel();
    await _audioRecorder.stop();
    if (_recordingPath != null) {
      final file = File(_recordingPath!);
      if (await file.exists()) await file.delete();
    }
    setState(() {
      _isRecording = false;
      _recordingPath = null;
      _recordingSeconds = 0;
    });
  }

  Future<void> _playAudio(String messageId, String audioUrl) async {
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
      setState(() {
        _currentlyPlayingAudioId = messageId;
        _audioPosition = Duration.zero;
      });
    }
  }

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

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  void _showMessageOptions(Map<String, dynamic> msg, bool isMe) {
    final theme = Theme.of(context);
    final isDeleted = msg['deleted_for_everyone'] == true;
    final messageId = msg['id'] as String?;
    if (messageId == null) return;

    final bool isPinned =
        _pinnedMessage != null && _pinnedMessage!['id'] == messageId;

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
              if (!isDeleted) ...[
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children:
                        ['❤️', '👍', '🔥', '😂', '😮', '🎉'].map((emoji) {
                      return GestureDetector(
                        onTap: () {
                          Navigator.pop(context);
                          _toggleReaction(messageId, emoji);
                        },
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 6),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.onSurface
                                .withOpacity(0.05),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(emoji,
                              style: const TextStyle(fontSize: 24)),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                Divider(color: theme.dividerColor, height: 1),
                if (isMe)
                  ListTile(
                    leading: Icon(Icons.edit,
                        color: theme.colorScheme.primary),
                    title: const Text('Edit'),
                    onTap: () {
                      Navigator.pop(context);
                      _showEditDialog(
                          messageId, msg['text'] ?? msg['content'] ?? '');
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.push_pin,
                      color: Color(0xFFE0954A)),
                  title: Text(isPinned ? 'Unpin' : 'Pin'),
                  onTap: () {
                    Navigator.pop(context);
                    if (isPinned) {
                      _unpinMessage(messageId);
                    } else {
                      _pinMessage(messageId);
                    }
                  },
                ),
                ListTile(
                  leading:
                      Icon(Icons.reply, color: theme.colorScheme.primary),
                  title: const Text('Reply'),
                  onTap: () {
                    Navigator.pop(context);
                    setState(() {
                      _replyingTo = messageId;
                      _replyingToContent =
                          msg['text'] ?? msg['content'] ?? 'Media';
                      _replyingToSender = msg['sender_name'] ?? 'Unknown';
                    });
                  },
                ),
              ],
              if (isMe)
                ListTile(
                  leading: Icon(Icons.delete_forever,
                      color: theme.colorScheme.error),
                  title: Text(
                    'Delete for Everyone',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _confirmDelete(messageId);
                  },
                ),
            ],
          ),
        ),
      ),
    );
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

  void _showAttachmentMenu() {
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
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: theme.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Wrap(
                spacing: 16,
                runSpacing: 16,
                alignment: WrapAlignment.center,
                children: [
                  _buildAttachmentButton(
                      theme, icon: Icons.photo_outlined,
                      label: 'Gallery',
                      onTap: () {
                        Navigator.pop(context);
                        _pickImage();
                      }),
                  _buildAttachmentButton(
                      theme, icon: Icons.camera_alt_outlined,
                      label: 'Camera',
                      onTap: () {
                        Navigator.pop(context);
                        _takePhoto();
                      }),
                  _buildAttachmentButton(
                      theme, icon: Icons.videocam_outlined,
                      label: 'Video',
                      onTap: () {
                        Navigator.pop(context);
                        _pickVideo();
                      }),
                  _buildAttachmentButton(
                      theme, icon: Icons.videocam,
                      label: 'Record',
                      onTap: () {
                        Navigator.pop(context);
                        _recordVideo();
                      }),
                  _buildAttachmentButton(
                      theme, icon: Icons.insert_drive_file_outlined,
                      label: 'File',
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

  Widget _buildAttachmentButton(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 76,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child:
                  Icon(icon, color: theme.colorScheme.primary, size: 24),
            ),
            const SizedBox(height: 8),
            Text(label,
                style: theme.textTheme.bodySmall?.copyWith(fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _buildPinnedMessageBanner(ThemeData theme) {
    if (_pinnedMessage == null) return const SizedBox.shrink();

    final text = _pinnedMessage!['text'] ??
        _pinnedMessage!['content'] ??
        'Pinned message';
    final sender = _pinnedMessage!['sender_name'] ?? 'Unknown';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: theme.colorScheme.primary.withOpacity(0.08),
      child: Row(
        children: [
          const Icon(Icons.push_pin,
              color: Color(0xFFE0954A), size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Pinned by $sender',
                  style: const TextStyle(
                    color: Color(0xFFE0954A),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 13),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final authProvider = Provider.of<LumaAuthProvider>(context);
    final userId = authProvider.user?.uid ?? authProvider.mockUserId;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: BoxDecoration(
                color: theme.brightness == Brightness.dark
                    ? const Color(0xFF1F1F1F)
                    : Colors.white,
                border: Border(
                  bottom: BorderSide(color: theme.dividerColor, width: 0.5),
                ),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.arrow_back,
                        color: theme.colorScheme.onSurface),
                    onPressed: () => Navigator.pop(context),
                  ),
                  GestureDetector(
                    onTap: _goToChannelInfo,
                    child: Row(
                      children: [
                        _channelAvatarUrl != null &&
                                _channelAvatarUrl!.isNotEmpty
                            ? CircleAvatar(
                                radius: 20,
                                backgroundImage:
                                    NetworkImage(_channelAvatarUrl!),
                                onBackgroundImageError: (_, __) {},
                              )
                            : CircleAvatar(
                                radius: 20,
                                backgroundColor: theme.colorScheme.primary
                                    .withOpacity(0.15),
                                child: Icon(Icons.campaign,
                                    color: theme.colorScheme.primary,
                                    size: 20),
                              ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.channelName,
                              style: TextStyle(
                                color: theme.colorScheme.onSurface,
                                fontWeight: FontWeight.w600,
                                fontSize: 16,
                              ),
                            ),
                            Text(
                              'Channel',
                              style: TextStyle(
                                color: theme.colorScheme.onSurface
                                    .withOpacity(0.5),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.more_vert,
                        color: theme.colorScheme.onSurface
                            .withOpacity(0.7)),
                    onPressed: _goToChannelInfo,
                  ),
                ],
              ),
            ),

            _buildPinnedMessageBanner(theme),

            // Messages
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
                            'No messages yet',
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

                  return ListView.builder(
                    reverse: true,
                    controller: _scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final msg =
                          messages[index].data() as Map<String, dynamic>;
                      msg['id'] = messages[index].id;
                      final isMe = msg['sender_id'] == userId;
                      final isDeleted =
                          msg['deleted_for_everyone'] == true;
                      final hasImage = msg['image_url'] != null ||
                          msg['media_url'] != null;
                      final mediaType = msg['media_type'] as String?;
                      final reactions = Map<String, dynamic>.from(
                          msg['reactions'] ?? {});

                      return GestureDetector(
                        onLongPress: () =>
                            _showMessageOptions(msg, isMe),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            constraints: BoxConstraints(
                              maxWidth:
                                  MediaQuery.of(context).size.width *
                                      0.85,
                            ),
                            decoration: BoxDecoration(
                              color: theme.brightness == Brightness.dark
                                  ? const Color(0xFF182533)
                                  : Colors.white,
                              borderRadius:
                                  BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.all(10),
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    _buildMessageAvatar(
                                      theme,
                                      msg['sender_avatar'],
                                      msg['sender_name'],
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        msg['sender_name'] ?? 'Admin',
                                        style: TextStyle(
                                          color: theme.colorScheme
                                              .primary,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      _formatTime(msg['created_at']
                                          as Timestamp?),
                                      style: TextStyle(
                                        color: theme
                                            .colorScheme.onSurface
                                            .withOpacity(0.4),
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),

                                if (msg['reply_to'] != null)
                                  Container(
                                    margin:
                                        const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme
                                          .primary
                                          .withOpacity(0.08),
                                      borderRadius:
                                          BorderRadius.circular(8),
                                      border: Border(
                                        left: BorderSide(
                                          color: theme
                                              .colorScheme.primary,
                                          width: 3,
                                        ),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          msg['reply_to_sender'] ??
                                              'Unknown',
                                          style: TextStyle(
                                            color: theme
                                                .colorScheme.primary,
                                            fontSize: 11,
                                            fontWeight:
                                                FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          msg['reply_to_content'] ?? '',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: theme
                                                .colorScheme.onSurface
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
                                      color: theme
                                          .colorScheme.onSurface
                                          .withOpacity(0.4),
                                      fontStyle: FontStyle.italic,
                                    ),
                                  )
                                else if (mediaType == 'image' && hasImage)
                                  ClipRRect(
                                    borderRadius:
                                        BorderRadius.circular(10),
                                    child: GestureDetector(
                                      onTap: () => _showImageViewer(
                                          msg['media_url'] ??
                                              msg['image_url']),
                                      child: CachedNetworkImage(
                                        imageUrl: msg['media_url'] ??
                                            msg['image_url'],
                                        fit: BoxFit.cover,
                                        placeholder: (_, __) => Container(
                                          height: 200,
                                          color: theme.colorScheme
                                              .onSurface
                                              .withOpacity(0.05),
                                          child: Center(
                                            child:
                                                CircularProgressIndicator(
                                              color: theme
                                                  .colorScheme.primary,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  )
                                else if (mediaType == 'video' && hasImage)
                                  _buildVideoThumbnail(theme,
                                      msg['media_url'] ??
                                          msg['image_url'])
                                else if (mediaType == 'audio')
                                  _buildVoiceNote(
                                    theme,
                                    msg['id'],
                                    msg['media_url'] ??
                                        msg['image_url'],
                                    msg['duration'] as int?,
                                  )
                                else if (mediaType == 'file')
                                  _buildFileMessage(
                                    theme,
                                    msg['content'] ?? msg['text'] ?? 'File',
                                    msg['file_name'],
                                    msg['file_size'],
                                  )
                                else
                                  Text(
                                    msg['text'] ??
                                        msg['content'] ??
                                        '',
                                    style: TextStyle(
                                      color: theme
                                          .colorScheme.onSurface,
                                      fontSize: 15,
                                      height: 1.4,
                                    ),
                                  ),

                                if (reactions.isNotEmpty)
                                  Padding(
                                    padding:
                                        const EdgeInsets.only(top: 8),
                                    child: Wrap(
                                      spacing: 4,
                                      children: reactions.entries
                                          .map((entry) {
                                        final emoji = entry.key;
                                        final count =
                                            (entry.value as List).length;
                                        return Container(
                                          padding: const EdgeInsets
                                              .symmetric(
                                              horizontal: 6,
                                              vertical: 2),
                                          decoration: BoxDecoration(
                                            color: theme.colorScheme
                                                .primary
                                                .withOpacity(0.1),
                                            borderRadius:
                                                BorderRadius.circular(12),
                                          ),
                                          child: Text(
                                            '$emoji ${count > 1 ? count : ''}',
                                            style: const TextStyle(
                                                fontSize: 12),
                                          ),
                                        );
                                      }).toList(),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),

            // Reply bar
            if (_replyingTo != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                              color: theme.colorScheme.onSurface
                                  .withOpacity(0.6),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close,
                          size: 18,
                          color: theme.colorScheme.onSurface
                              .withOpacity(0.5)),
                      onPressed: () => setState(() {
                        _replyingTo = null;
                        _replyingToContent = null;
                        _replyingToSender = null;
                      }),
                    ),
                  ],
                ),
              ),

            // Selected media preview
            if (_selectedImage != null)
              _buildMediaPreview(theme, 'Image',
                  () => setState(() => _selectedImage = null))
            else if (_selectedVideo != null)
              _buildMediaPreview(theme, 'Video',
                  () => setState(() => _selectedVideo = null)),

            // Recording indicator
            if (_isRecording)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                color: theme.colorScheme.error.withOpacity(0.15),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.error,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Recording ${_formatDuration(_recordingSeconds)}',
                      style: TextStyle(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: _cancelRecording,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color:
                              theme.colorScheme.error.withOpacity(0.2),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.delete,
                            color: theme.colorScheme.error, size: 20),
                      ),
                    ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: _stopRecordingAndSend,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.send,
                                color: Colors.white, size: 16),
                            SizedBox(width: 4),
                            Text(
                              'Send',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // Emoji picker
            if (_showEmojiPicker)
              CustomEmojiPicker(
                onEmojiSelected: (emoji) =>
                    setState(() => _messageController.text += emoji),
                onClose: () => setState(() => _showEmojiPicker = false),
              ),

            // Input
            FutureBuilder<DocumentSnapshot>(
              future: FirebaseFirestore.instance
                  .collection('chats')
                  .doc(widget.channelId)
                  .get(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const SizedBox.shrink();
                final chatData =
                    snapshot.data!.data() as Map<String, dynamic>?;
                final myRole = (chatData?['participants_data']?[userId]
                        ?['role'] ??
                    'member') as String;
                final canPost = myRole == 'owner' || myRole == 'admin';

                if (!canPost) {
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    color: theme.colorScheme.onSurface.withOpacity(0.03),
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
                  );
                }

                return Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.brightness == Brightness.dark
                        ? const Color(0xFF1F1F1F)
                        : Colors.white,
                    border: Border(
                      top: BorderSide(
                          color: theme.dividerColor, width: 0.5),
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _inputCircle(
                          theme,
                          icon: Icons.add,
                          onTap: _showAttachmentMenu,
                        ),
                        const SizedBox(width: 4),
                        _inputCircle(
                          theme,
                          icon: _showEmojiPicker
                              ? Icons.keyboard
                              : Icons.emoji_emotions_outlined,
                          onTap: () => setState(
                              () => _showEmojiPicker = !_showEmojiPicker),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Container(
                            constraints:
                                const BoxConstraints(maxHeight: 120),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.onSurface
                                  .withOpacity(0.05),
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(
                                color: theme.colorScheme.onSurface
                                    .withOpacity(0.08),
                              ),
                            ),
                            child: TextField(
                              controller: _messageController,
                              style: TextStyle(
                                color: theme.colorScheme.onSurface,
                                fontSize: 14,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Message...',
                                hintStyle: TextStyle(
                                  color: theme.colorScheme.onSurface
                                      .withOpacity(0.4),
                                ),
                                border: InputBorder.none,
                                contentPadding:
                                    const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 10),
                              ),
                              maxLines: null,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        if (_messageController.text.trim().isEmpty &&
                            !_isRecording)
                          GestureDetector(
                            onLongPressStart: (_) => _startRecording(),
                            onLongPressEnd: (_) => _stopRecordingAndSend(),
                            child: Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.mic,
                                  color: Colors.white, size: 20),
                            ),
                          )
                        else
                          GestureDetector(
                            onTap: _isLoading ? null : () => _sendMessage(),
                            child: Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary,
                                shape: BoxShape.circle,
                              ),
                              child: _isLoading
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.send,
                                      color: Colors.white, size: 20),
                            ),
                          ),
                      ],
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

  Widget _inputCircle(
    ThemeData theme, {
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: theme.colorScheme.onSurface.withOpacity(0.05),
          shape: BoxShape.circle,
          border: Border.all(
            color: theme.colorScheme.onSurface.withOpacity(0.08),
          ),
        ),
        child: Icon(icon,
            size: 20,
            color: theme.colorScheme.onSurface.withOpacity(0.7)),
      ),
    );
  }

  Widget _buildMessageAvatar(
      ThemeData theme, String? avatarUrl, String? username) {
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      return CircleAvatar(
        radius: 14,
        backgroundImage: NetworkImage(avatarUrl),
        onBackgroundImageError: (_, __) {},
      );
    }
    return CircleAvatar(
      radius: 14,
      backgroundColor: theme.colorScheme.primary.withOpacity(0.2),
      child: Text(
        (username ?? 'A')[0].toUpperCase(),
        style: TextStyle(
            color: theme.colorScheme.primary, fontSize: 10),
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
                    color: theme.colorScheme.onSurface.withOpacity(0.5)),
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

  Widget _buildVideoThumbnail(ThemeData theme, String videoUrl) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 200,
        color: Colors.black,
        child: const Center(
          child:
              Icon(Icons.play_circle_fill, color: Colors.white, size: 50),
        ),
      ),
    );
  }

  Widget _buildVoiceNote(ThemeData theme, String messageId,
      String? audioUrl, int? duration) {
    final isCurrent = _currentlyPlayingAudioId == messageId;
    final totalDuration = isCurrent && _audioDuration != Duration.zero
        ? _audioDuration
        : Duration(seconds: duration ?? 0);
    final progress = totalDuration.inMilliseconds > 0
        ? _audioPosition.inMilliseconds / totalDuration.inMilliseconds
        : 0.0;

    return Container(
      width: 240,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          GestureDetector(
            onTap:
                audioUrl != null ? () => _playAudio(messageId, audioUrl) : null,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                isCurrent && _isPlayingAudio
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
                      ? '${_formatDuration(_audioPosition.inSeconds)} / ${_formatDuration(totalDuration.inSeconds)}'
                      : _formatDuration(totalDuration.inSeconds),
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

  Widget _buildFileMessage(ThemeData theme, String content,
      String? fileName, String? fileSize) {
    return Container(
      width: 240,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.insert_drive_file, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fileName ?? content,
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
              imageProvider: NetworkImage(imageUrl),
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
  void dispose() {
    _messageController.removeListener(_onTextChanged);
    _messageController.dispose();
    _editController.dispose();
    _scrollController.dispose();
    _audioPlayer.dispose();
    _audioRecorder.dispose();
    _recordingTimer?.cancel();
    _pinnedMessageSub?.cancel();
    super.dispose();
  }
}
