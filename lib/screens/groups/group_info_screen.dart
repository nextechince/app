import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../providers/chat_provider.dart';
import '../../services/cloudinary_service.dart';
import '../../services/invitation_service.dart';
import '../../utils/verified_badge.dart';

class GroupInfoScreen extends StatefulWidget {
  final String chatId;
  final String chatName;
  final String? chatAvatar;
  final bool isChannel;

  const GroupInfoScreen({
    super.key,
    required this.chatId,
    required this.chatName,
    this.chatAvatar,
    required this.isChannel,
  });

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  bool _isLoading = false;
  bool _isEditing = false;
  String? _invitationLink;
  String? _invitationCode;

  final _editNameController = TextEditingController();
  final _editDescriptionController = TextEditingController();
  String? _editPhotoUrl;

  @override
  void initState() {
    super.initState();
    _loadInvitationLink();
  }

  @override
  void dispose() {
    _editNameController.dispose();
    _editDescriptionController.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // INVITATION
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _loadInvitationLink() async {
    final preview = await InvitationService.getInvitationPreview(widget.chatId);
    if (preview != null && mounted) {
      setState(() {
        _invitationLink = preview['link'] as String?;
        _invitationCode = preview['code'] as String?;
      });
    }
  }

  Future<void> _copyLinkToClipboard() async {
    if (_invitationLink == null || _invitationLink!.isEmpty) {
      _toast('No invitation link available');
      return;
    }
    await Clipboard.setData(ClipboardData(text: _invitationLink!));
    _toast('Link copied to clipboard');
  }

  Future<void> _copyCodeToClipboard() async {
    if (_invitationCode == null || _invitationCode!.isEmpty) {
      _toast('No invitation code available');
      return;
    }
    await Clipboard.setData(ClipboardData(text: _invitationCode!));
    _toast('Code copied to clipboard');
  }

  Future<void> _regenerateLink() async {
    final theme = Theme.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Regenerate Link?'),
        content: const Text(
          'This will invalidate the current invitation link and create a new one. Anyone with the old link will no longer be able to join.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.orange),
            child: const Text('Regenerate'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isLoading = true);

    try {
      final authProvider =
          Provider.of<LumaAuthProvider>(context, listen: false);
      final createdBy =
          authProvider.user?.uid ?? authProvider.mockUserId ?? 'unknown';
      final newLink =
          await InvitationService.regenerateLink(widget.chatId, createdBy);

      if (newLink != null && mounted) {
        await _loadInvitationLink();
        _toast('Invitation link regenerated');
      } else if (mounted) {
        _toast('Failed to regenerate link');
      }
    } catch (e) {
      _toast('Error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _shareInvitationLink() async {
    final preview = await InvitationService.getInvitationPreview(widget.chatId);
    if (preview == null) {
      _toast('No active invitation link');
      return;
    }

    final chatName = preview['chat_name'] ?? 'Unknown';
    final chatType = preview['chat_type'] ?? 'group';
    final memberCount = preview['member_count'] ?? 0;
    final link = preview['link'] ?? '';

    final text = 'Join $chatName on Luma Chat!\n'
        '${widget.isChannel ? "Channel" : "Group"}: $chatType\n'
        'Members: $memberCount\n\n'
        'Tap to join: $link';

    await Share.share(text);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // EDIT
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _pickEditPhoto() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile == null) return;

    setState(() => _isLoading = true);

    try {
      final authProvider =
          Provider.of<LumaAuthProvider>(context, listen: false);
      final userId = authProvider.user?.uid ?? authProvider.mockUserId;
      if (userId == null) throw Exception('Not authenticated');

      final imageUrl = await CloudinaryService.uploadImage(
        File(pickedFile.path),
        'luma/permanent/avatars/${widget.isChannel ? "channels" : "groups"}/$userId',
      );

      if (imageUrl != null) {
        setState(() => _editPhotoUrl = imageUrl);
      }
    } catch (e) {
      debugPrint('Photo upload failed: $e');
      _toast('Upload failed: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _deleteOldAvatar(String? oldUrl) async {
    if (oldUrl == null || oldUrl.isEmpty) return;
    if (!oldUrl.contains('cloudinary.com')) return;

    try {
      await CloudinaryService.deleteImage(oldUrl);
    } catch (e) {
      debugPrint('Failed to delete old avatar: $e');
    }
  }

  Future<void> _saveEdit() async {
    final name = _editNameController.text.trim();
    if (name.isEmpty) {
      _toast('Name cannot be empty');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final chatDoc = await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .get();
      final oldAvatarUrl = chatDoc.data()?['avatar_url'] as String?;

      final updates = <String, dynamic>{
        'name': name,
        'description': _editDescriptionController.text.trim().isNotEmpty
            ? _editDescriptionController.text.trim()
            : null,
        'updated_at': FieldValue.serverTimestamp(),
      };

      if (_editPhotoUrl != null && _editPhotoUrl != oldAvatarUrl) {
        updates['avatar_url'] = _editPhotoUrl;
        await _deleteOldAvatar(oldAvatarUrl);
      }

      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .update(updates);

      if (!mounted) return;
      setState(() {
        _isEditing = false;
        _isLoading = false;
      });
      _toast('Updated successfully');
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _toast('Update failed: $e');
    }
  }

  void _startEdit(Map<String, dynamic> data) {
    _editNameController.text = data['name'] ?? '';
    _editDescriptionController.text = data['description'] ?? '';
    _editPhotoUrl = data['avatar_url'];
    setState(() => _isEditing = true);
  }

  void _cancelEdit() {
    setState(() => _isEditing = false);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // MEMBER MANAGEMENT
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _showMemberOptions(
    String memberId,
    String memberName,
    String memberRole,
    bool isMe,
    bool canManage,
  ) async {
    if (isMe) return;
    if (!canManage) return;

    final theme = Theme.of(context);
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);
    final myRole = await _getMyRole();
    if (myRole == null) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: theme.brightness == Brightness.dark
          ? const Color(0xFF1F1F1F)
          : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    memberName,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              if (myRole == 'owner' && memberRole == 'member')
                ListTile(
                  leading: Icon(Icons.admin_panel_settings,
                      color: theme.colorScheme.primary),
                  title: const Text('Promote to Admin'),
                  onTap: () {
                    Navigator.pop(ctx);
                    chatProvider.promoteToAdmin(widget.chatId, memberId);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.remove_circle_outline,
                    color: Color(0xFFE0954A)),
                title: const Text('Remove',
                    style: TextStyle(color: Color(0xFFE0954A))),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmKick(memberId, memberName);
                },
              ),
              ListTile(
                leading: Icon(Icons.block, color: theme.colorScheme.error),
                title: Text('Ban',
                    style: TextStyle(color: theme.colorScheme.error)),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmBan(memberId, memberName);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String?> _getMyRole() async {
    final authProvider =
        Provider.of<LumaAuthProvider>(context, listen: false);
    final userId = authProvider.user?.uid ?? authProvider.mockUserId;
    if (userId == null) return null;

    final doc = await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .get();
    if (!doc.exists) return null;

    final data = doc.data()!;
    return (data['participants_data']?[userId]?['role'] ?? 'member')
        as String;
  }

  void _confirmKick(String memberId, String memberName) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $memberName?'),
        content: const Text('They will be removed from this group.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              Provider.of<ChatProvider>(context, listen: false)
                  .kickMember(widget.chatId, memberId);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.orange),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  void _confirmBan(String memberId, String memberName) {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Ban $memberName?'),
        content:
            const Text('They will be removed and banned from rejoining.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              Provider.of<ChatProvider>(context, listen: false)
                  .banMember(widget.chatId, memberId);
            },
            style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error),
            child: const Text('Ban'),
          ),
        ],
      ),
    );
  }

  void _showSettings(String currentRole) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: theme.brightness == Brightness.dark
          ? const Color(0xFF1F1F1F)
          : Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => GroupSettingsSheet(
        chatId: widget.chatId,
        currentRole: currentRole,
        isChannel: widget.isChannel,
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // LEAVE / DELETE
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _leaveGroup() async {
    final theme = Theme.of(context);
    final authProvider =
        Provider.of<LumaAuthProvider>(context, listen: false);
    final userId = authProvider.user?.uid ?? authProvider.mockUserId;

    final chatDoc = await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .get();
    if (!chatDoc.exists) return;

    final data = chatDoc.data()!;
    final myRole =
        (data['participants_data']?[userId]?['role'] ?? 'member') as String;

    if (myRole == 'owner') {
      _toast('Owner cannot leave. Delete the group instead.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
            'Leave ${widget.isChannel ? "Channel" : "Group"}?'),
        content: Text(
            'You will no longer receive messages from this ${widget.isChannel ? "channel" : "group"}.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error),
            child: const Text('Leave'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await Provider.of<ChatProvider>(context, listen: false)
          .leaveChat(widget.chatId);
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _deleteGroup() async {
    final theme = Theme.of(context);
    final authProvider =
        Provider.of<LumaAuthProvider>(context, listen: false);
    final userId = authProvider.user?.uid ?? authProvider.mockUserId;

    final chatDoc = await FirebaseFirestore.instance
        .collection('chats')
        .doc(widget.chatId)
        .get();
    if (!chatDoc.exists) return;

    final data = chatDoc.data()!;
    final myRole =
        (data['participants_data']?[userId]?['role'] ?? 'member') as String;

    if (myRole != 'owner') {
      _toast('Only the owner can delete this group');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Group?'),
        content: const Text(
          'This will permanently delete the group and all its messages. This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isLoading = true);

    try {
      final chatProvider = Provider.of<ChatProvider>(context, listen: false);
      final success =
          await chatProvider.permanentlyDeleteChat(widget.chatId);

      if (success && mounted) {
        _toast('Group deleted');
        Navigator.pop(context);
      } else if (mounted) {
        _toast(chatProvider.error ?? 'Failed to delete group');
      }
    } catch (e) {
      _toast('Error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
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
      appBar: AppBar(
        title: Text(widget.isChannel ? 'Channel Info' : 'Group Info'),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
        actions: [
          StreamBuilder<DocumentSnapshot>(
            stream: FirebaseFirestore.instance
                .collection('chats')
                .doc(widget.chatId)
                .snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const SizedBox.shrink();
              final data = snapshot.data!.data() as Map<String, dynamic>?;
              final myRole =
                  (data?['participants_data']?[userId]?['role'] ??
                          'member') as String;
              final canManage = myRole == 'owner' || myRole == 'admin';

              return Row(
                children: [
                  if (canManage && !_isEditing)
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _startEdit(data!),
                    ),
                  if (_isEditing)
                    IconButton(
                      icon: const Icon(Icons.check,
                          color: Color(0xFF4FAE4F)),
                      onPressed: _saveEdit,
                    ),
                  if (_isEditing)
                    IconButton(
                      icon: Icon(Icons.close,
                          color: theme.colorScheme.error),
                      onPressed: _cancelEdit,
                    ),
                  if (canManage && !_isEditing)
                    IconButton(
                      icon: const Icon(Icons.settings_outlined),
                      onPressed: () => _showSettings(myRole),
                    ),
                  if (!_isEditing)
                    IconButton(
                      icon: const Icon(Icons.share_outlined),
                      onPressed: _shareInvitationLink,
                    ),
                ],
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('chats')
            .doc(widget.chatId)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Center(
              child: CircularProgressIndicator(
                  color: theme.colorScheme.primary),
            );
          }

          final data = snapshot.data!.data() as Map<String, dynamic>;
          final participants =
              List<String>.from(data['participants'] ?? []);
          final memberCount = data['member_count'] ?? participants.length;
          final description = data['description'] ?? '';
          final createdByEmail = data['created_by_email'] as String?;
          final myRole = (data['participants_data']?[userId]?['role'] ??
              'member') as String;
          final canManage = myRole == 'owner' || myRole == 'admin';
          final isOwner = myRole == 'owner';

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Center(
                  child: Column(
                    children: [
                      GestureDetector(
                        onTap: _isEditing ? _pickEditPhoto : null,
                        child: Stack(
                          children: [
                            _buildAvatar(theme,
                                _isEditing
                                    ? (_editPhotoUrl ??
                                        data['avatar_url'])
                                    : data['avatar_url']),
                            if (_isEditing)
                              Positioned(
                                bottom: 0,
                                right: 0,
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primary,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: theme.scaffoldBackgroundColor,
                                      width: 2,
                                    ),
                                  ),
                                  child: const Icon(Icons.camera_alt,
                                      color: Colors.white, size: 14),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      if (_isEditing)
                        Container(
                          margin:
                              const EdgeInsets.symmetric(horizontal: 32),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.onSurface
                                .withOpacity(0.05),
                            borderRadius: BorderRadius.circular(10),
                            border:
                                Border.all(color: theme.dividerColor),
                          ),
                          child: TextField(
                            controller: _editNameController,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: theme.colorScheme.onSurface,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 12),
                            ),
                          ),
                        )
                      else
                        VerifiedUsername(
                          username: data['name'] ?? 'Unknown',
                          email: createdByEmail,
                          style: TextStyle(
                            color: theme.colorScheme.onSurface,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                          badgeSize: 16,
                          spacing: 6,
                        ),

                      if (_isEditing) ...[
                        const SizedBox(height: 12),
                        Container(
                          margin:
                              const EdgeInsets.symmetric(horizontal: 32),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.onSurface
                                .withOpacity(0.05),
                            borderRadius: BorderRadius.circular(10),
                            border:
                                Border.all(color: theme.dividerColor),
                          ),
                          child: TextField(
                            controller: _editDescriptionController,
                            textAlign: TextAlign.center,
                            maxLines: 3,
                            style: TextStyle(
                              color: theme.colorScheme.onSurface
                                  .withOpacity(0.85),
                              fontSize: 14,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Add a description...',
                              hintStyle: TextStyle(
                                color: theme.colorScheme.onSurface
                                    .withOpacity(0.3),
                              ),
                              border: InputBorder.none,
                              contentPadding:
                                  const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 12),
                            ),
                          ),
                        ),
                      ] else if (description.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 24),
                          child: Text(
                            description,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurface
                                  .withOpacity(0.6),
                            ),
                          ),
                        ),
                      ],

                      const SizedBox(height: 4),
                      Text(
                        '$memberCount member${memberCount == 1 ? '' : 's'} • ${widget.isChannel ? "Channel" : "Group"}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface
                              .withOpacity(0.5),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Actions
                if (!_isEditing)
                  Row(
                    children: [
                      Expanded(
                        child: _buildActionButton(
                          theme,
                          icon: Icons.person_add_outlined,
                          label: 'Add',
                          onTap: () => _showAddMembersSheet(context),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildActionButton(
                          theme,
                          icon: Icons.share_outlined,
                          label: 'Invite',
                          onTap: _shareInvitationLink,
                        ),
                      ),
                      if (!isOwner) ...[
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildActionButton(
                            theme,
                            icon: Icons.exit_to_app,
                            label: 'Leave',
                            color: theme.colorScheme.error,
                            onTap: _leaveGroup,
                          ),
                        ),
                      ],
                      if (isOwner) ...[
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildActionButton(
                            theme,
                            icon: Icons.delete_forever_outlined,
                            label: 'Delete',
                            color: theme.colorScheme.error,
                            onTap: _deleteGroup,
                          ),
                        ),
                      ],
                    ],
                  ),
                if (!_isEditing) const SizedBox(height: 24),

                // Invitation link section
                if (!_isEditing &&
                    _invitationLink != null &&
                    _invitationLink!.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color:
                            theme.colorScheme.primary.withOpacity(0.2),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.link,
                                color: theme.colorScheme.primary, size: 18),
                            const SizedBox(width: 8),
                            Text(
                              'Invitation Link',
                              style: TextStyle(
                                color: theme.colorScheme.primary,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            if (canManage)
                              GestureDetector(
                                onTap:
                                    _isLoading ? null : _regenerateLink,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE0954A)
                                        .withOpacity(0.12),
                                    borderRadius:
                                        BorderRadius.circular(8),
                                    border: Border.all(
                                      color: const Color(0xFFE0954A)
                                          .withOpacity(0.3),
                                    ),
                                  ),
                                  child: _isLoading
                                      ? const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child:
                                              CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Color(0xFFE0954A),
                                          ),
                                        )
                                      : const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.refresh,
                                                color: Color(0xFFE0954A),
                                                size: 12),
                                            SizedBox(width: 4),
                                            Text(
                                              'Regenerate',
                                              style: TextStyle(
                                                color: Color(0xFFE0954A),
                                                fontSize: 11,
                                                fontWeight:
                                                    FontWeight.w500,
                                              ),
                                            ),
                                          ],
                                        ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (_invitationCode != null &&
                            _invitationCode!.isNotEmpty) ...[
                          GestureDetector(
                            onTap: _copyCodeToClipboard,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.onSurface
                                    .withOpacity(0.05),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primary
                                          .withOpacity(0.15),
                                      borderRadius:
                                          BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      'CODE',
                                      style: TextStyle(
                                        color: theme.colorScheme.primary,
                                        fontSize: 9,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 1,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      _invitationCode!,
                                      style: TextStyle(
                                        color: theme
                                            .colorScheme.onSurface,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: 1,
                                      ),
                                    ),
                                  ),
                                  Icon(Icons.copy,
                                      color: theme.colorScheme.onSurface
                                          .withOpacity(0.4),
                                      size: 16),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.onSurface
                                .withOpacity(0.05),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _invitationLink!,
                                  style: TextStyle(
                                    color: theme
                                        .colorScheme.onSurface
                                        .withOpacity(0.85),
                                    fontSize: 13,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: _copyLinkToClipboard,
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primary
                                        .withOpacity(0.15),
                                    borderRadius:
                                        BorderRadius.circular(8),
                                  ),
                                  child: Icon(Icons.copy,
                                      color: theme.colorScheme.primary,
                                      size: 18),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: SizedBox(
                                height: 42,
                                child: ElevatedButton.icon(
                                  onPressed: _shareInvitationLink,
                                  icon: const Icon(Icons.share, size: 16),
                                  label: const Text('Share Link'),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              height: 42,
                              child: OutlinedButton(
                                onPressed: _copyLinkToClipboard,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor:
                                      theme.colorScheme.onSurface,
                                  side: BorderSide(
                                      color: theme.dividerColor),
                                  shape: RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius.circular(10),
                                  ),
                                ),
                                child: const Text('Copy'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                ],

                // Settings preview
                if (canManage && !_isEditing) ...[
                  _sectionTitle(theme, 'SETTINGS'),
                  const SizedBox(height: 8),
                  _buildSettingsPreview(theme, data),
                  const SizedBox(height: 24),
                ],

                // Members section — admins only see full list
                if (canManage) ...[
                  _sectionTitle(theme, 'MEMBERS ($memberCount)'),
                  const SizedBox(height: 8),
                  FutureBuilder<List<Map<String, dynamic>>>(
                    future: Future.wait(participants.map((uid) async {
                      final doc = await FirebaseFirestore.instance
                          .collection('users')
                          .doc(uid)
                          .get();
                      final userData = doc.data() ?? {};
                      final role =
                          (data['participants_data']?[uid]?['role'] ??
                              'member') as String;
                      return {'uid': uid, ...userData, 'role': role};
                    })),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return Padding(
                          padding: const EdgeInsets.all(16),
                          child: Center(
                            child: CircularProgressIndicator(
                                color: theme.colorScheme.primary),
                          ),
                        );
                      }

                      final users = snapshot.data!;
                      users.sort((a, b) {
                        final roleOrder = {
                          'owner': 0,
                          'admin': 1,
                          'member': 2,
                        };
                        return (roleOrder[a['role']] ?? 3)
                            .compareTo(roleOrder[b['role']] ?? 3);
                      });

                      return Container(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.onSurface
                              .withOpacity(0.03),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: users.map((user) {
                            final uid = user['uid'] as String;
                            final isMe = uid == userId;
                            final role = user['role'] as String;

                            return ListTile(
                              leading: _buildMemberAvatar(
                                theme,
                                user['avatar_url'],
                                user['username'],
                              ),
                              title: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      user['username'] ?? 'Unknown',
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w500),
                                    ),
                                  ),
                                  if (isMe)
                                    Padding(
                                      padding:
                                          const EdgeInsets.only(left: 6),
                                      child: Text(
                                        '(You)',
                                        style: TextStyle(
                                          color: theme
                                              .colorScheme.onSurface
                                              .withOpacity(0.5),
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              subtitle: Text(
                                role == 'owner'
                                    ? 'Owner'
                                    : role == 'admin'
                                        ? 'Admin'
                                        : 'Member',
                                style: TextStyle(
                                  color: role == 'owner'
                                      ? const Color(0xFFD4A73A)
                                      : role == 'admin'
                                          ? theme.colorScheme.primary
                                          : theme.colorScheme.onSurface
                                              .withOpacity(0.5),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              trailing: !isMe &&
                                      canManage &&
                                      role != 'owner'
                                  ? IconButton(
                                      icon: Icon(Icons.more_vert,
                                          color: theme
                                              .colorScheme.onSurface
                                              .withOpacity(0.5)),
                                      onPressed: () =>
                                          _showMemberOptions(
                                        uid,
                                        user['username'] ?? 'Unknown',
                                        role,
                                        isMe,
                                        canManage,
                                      ),
                                    )
                                  : null,
                              onTap: () {
                                if (!isMe) {
                                  Navigator.pushNamed(
                                    context,
                                    '/public_profile',
                                    arguments: {
                                      'userId': uid,
                                      'username': user['username'],
                                      'avatarUrl': user['avatar_url'],
                                      'bio': user['bio'],
                                    },
                                  );
                                }
                              },
                            );
                          }).toList(),
                        ),
                      );
                    },
                  ),
                ] else ...[
                  // Non-admins just see the count
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color:
                          theme.colorScheme.onSurface.withOpacity(0.03),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.people_outline,
                          color:
                              theme.colorScheme.onSurface.withOpacity(0.5),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '$memberCount member${memberCount == 1 ? '' : 's'}',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurface.withOpacity(0.55),
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  void _showAddMembersSheet(BuildContext context) {
    final theme = Theme.of(context);
    final searchController = TextEditingController();
    List<Map<String, dynamic>> searchResults = [];

    showModalBottomSheet(
      context: context,
      backgroundColor: theme.brightness == Brightness.dark
          ? const Color(0xFF1F1F1F)
          : Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Container(
              padding: const EdgeInsets.all(16),
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.7,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.dividerColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Add Members',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: searchController,
                    style:
                        TextStyle(color: theme.colorScheme.onSurface),
                    decoration: const InputDecoration(
                      hintText: 'Search by username...',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (value) async {
                      if (value.length < 2) {
                        setModalState(() => searchResults = []);
                        return;
                      }
                      final snapshot = await FirebaseFirestore.instance
                          .collection('users')
                          .where('username',
                              isGreaterThanOrEqualTo: value)
                          .where('username',
                              isLessThanOrEqualTo: '$value\uf8ff')
                          .limit(10)
                          .get();
                      setModalState(() {
                        searchResults = snapshot.docs
                            .map((doc) => {'id': doc.id, ...doc.data()})
                            .toList();
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: ListView.builder(
                      itemCount: searchResults.length,
                      itemBuilder: (context, index) {
                        final user = searchResults[index];
                        return ListTile(
                          leading: _buildMemberAvatar(
                            theme,
                            user['avatar_url'],
                            user['username'],
                          ),
                          title: Text(user['username'] ?? 'Unknown'),
                          subtitle: Text(user['email'] ?? ''),
                          trailing: TextButton(
                            onPressed: () async {
                              final chatProvider =
                                  Provider.of<ChatProvider>(ctx,
                                      listen: false);
                              final authProvider =
                                  Provider.of<LumaAuthProvider>(ctx,
                                      listen: false);
                              final currentUserId =
                                  authProvider.user?.uid ??
                                      authProvider.mockUserId;

                              final userDoc = await FirebaseFirestore
                                  .instance
                                  .collection('users')
                                  .doc(user['id'])
                                  .get();
                              final privacySettings =
                                  userDoc.data()?['privacy_settings'] ??
                                      {};
                              final allowAddToGroups =
                                  privacySettings['allow_add_to_groups'] ??
                                      true;

                              if (!allowAddToGroups) {
                                if (!ctx.mounted) return;
                                _showCannotAddDialog(
                                  ctx,
                                  user,
                                  currentUserId,
                                );
                                return;
                              }

                              await FirebaseFirestore.instance
                                  .collection('chats')
                                  .doc(widget.chatId)
                                  .update({
                                'participants':
                                    FieldValue.arrayUnion([user['id']]),
                                'participants_data.${user['id']}': {
                                  'role': 'member',
                                  'joined_at':
                                      FieldValue.serverTimestamp(),
                                },
                                'member_count': FieldValue.increment(1),
                              });

                              await FirebaseFirestore.instance
                                  .collection('chats')
                                  .doc(widget.chatId)
                                  .collection('messages')
                                  .add({
                                'type': 'system',
                                'content':
                                    '${user['username']} was added by ${authProvider.userName ?? 'an admin'}',
                                'created_at':
                                    FieldValue.serverTimestamp(),
                              });

                              if (ctx.mounted) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  SnackBar(
                                      content: Text(
                                          'Added ${user['username']}')),
                                );
                              }
                            },
                            child: Text('Add',
                                style: TextStyle(
                                    color: theme.colorScheme.primary,
                                    fontWeight: FontWeight.w600)),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showCannotAddDialog(
    BuildContext ctx,
    Map<String, dynamic> user,
    String? currentUserId,
  ) {
    final theme = Theme.of(ctx);
    showDialog(
      context: ctx,
      builder: (innerCtx) => AlertDialog(
        title: const Text('Cannot Add User'),
        content: Text(
          '${user['username']} does not allow being added to groups. Send them the invite link instead?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(innerCtx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(innerCtx);
              final preview = await InvitationService.getInvitationPreview(
                  widget.chatId);
              String link = preview?['link'] ?? '';

              if (link.isEmpty && currentUserId != null) {
                final result = await InvitationService.createInvitation(
                  chatId: widget.chatId,
                  chatName: widget.chatName,
                  chatType: widget.isChannel ? 'channel' : 'group',
                  createdBy: currentUserId,
                );
                link = result['link'] as String;
              }

              final shouldSend = await showDialog<bool>(
                context: ctx,
                builder: (sendCtx) => AlertDialog(
                  title:
                      Text('Send Invite to ${user['username']}?'),
                  content: Text(
                    'This will open a chat with ${user['username']} and send them the invitation link for "${widget.chatName}".',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () =>
                          Navigator.pop(sendCtx, false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () =>
                          Navigator.pop(sendCtx, true),
                      child: const Text('Send'),
                    ),
                  ],
                ),
              );

              if (shouldSend != true) return;
              if (!ctx.mounted) return;

              final chatProvider = Provider.of<ChatProvider>(ctx,
                  listen: false);
              final dmChat =
                  await chatProvider.startDirectChat(user['id']);

              if (dmChat != null && ctx.mounted) {
                final previewData = await InvitationService
                    .getChatPreviewData(widget.chatId);

                await FirebaseFirestore.instance
                    .collection('chats')
                    .doc(dmChat['id'])
                    .collection('messages')
                    .add({
                  'chat_id': dmChat['id'],
                  'sender_id': currentUserId,
                  'type': 'link_preview',
                  'content': link,
                  'preview_data': {
                    'title': previewData['name'] ?? widget.chatName,
                    'description': previewData['description'] ??
                        'Join us on Luma Chat',
                    'image_url': previewData['avatar_url'],
                    'member_count': previewData['member_count'] ?? 0,
                    'type': previewData['type'] ?? 'group',
                    'source_chat_id': widget.chatId,
                  },
                  'created_at': FieldValue.serverTimestamp(),
                  'is_read': false,
                  'deleted_for_everyone': false,
                  'deleted_for': [],
                  'reactions': {},
                  'is_edited': false,
                });

                await FirebaseFirestore.instance
                    .collection('chats')
                    .doc(dmChat['id'])
                    .update({
                  'last_message': link,
                  'last_message_at': FieldValue.serverTimestamp(),
                });

                if (!ctx.mounted) return;
                Navigator.pushNamed(
                  ctx,
                  '/chat',
                  arguments: {
                    'chatId': dmChat['id'],
                    'chatName': user['username'],
                    'chatAvatar': user['avatar_url'],
                    'isGroup': false,
                  },
                );

                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(
                      content: Text(
                          'Invite link sent to ${user['username']}')),
                );
              }
            },
            style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.primary),
            child: const Text('Send Link'),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(ThemeData theme, String? avatarUrl) {
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      return CircleAvatar(
        radius: 44,
        backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
        backgroundImage: NetworkImage(avatarUrl),
        onBackgroundImageError: (_, __) {},
      );
    }
    return CircleAvatar(
      radius: 44,
      backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
      child: Icon(
        widget.isChannel ? Icons.campaign : Icons.group,
        size: 44,
        color: theme.colorScheme.primary,
      ),
    );
  }

  Widget _buildMemberAvatar(
    ThemeData theme,
    String? avatarUrl,
    String? username,
  ) {
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      return CircleAvatar(
        radius: 20,
        backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
        backgroundImage: NetworkImage(avatarUrl),
        onBackgroundImageError: (_, __) {},
      );
    }
    return CircleAvatar(
      radius: 20,
      backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
      child: Text(
        (username ?? 'U')[0].toUpperCase(),
        style: TextStyle(
          color: theme.colorScheme.primary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildActionButton(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    final c = color ?? theme.colorScheme.primary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: c.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.withOpacity(0.25)),
        ),
        child: Column(
          children: [
            Icon(icon, color: c, size: 20),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: c,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsPreview(ThemeData theme, Map<String, dynamic> data) {
    final settings = data['settings'] as Map<String, dynamic>? ?? {};
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withOpacity(0.03),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          _buildSettingRow(theme,
              icon: Icons.chat_bubble_outline,
              label: 'Chat Enabled',
              value: !(settings['chat_disabled'] ?? false)),
          _buildSettingRow(theme,
              icon: Icons.attach_file,
              label: 'File Sharing',
              value: !(settings['file_sharing_disabled'] ?? false)),
          _buildSettingRow(theme,
              icon: Icons.poll_outlined,
              label: 'Polls',
              value: settings['polls_enabled'] ?? true),
          _buildSettingRow(theme,
              icon: Icons.emoji_emotions_outlined,
              label: 'Reactions',
              value: settings['reactions_enabled'] ?? true),
        ],
      ),
    );
  }

  Widget _buildSettingRow(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required bool value,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon,
              size: 18,
              color: theme.colorScheme.onSurface.withOpacity(0.5)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                  color:
                      theme.colorScheme.onSurface.withOpacity(0.7)),
            ),
          ),
          Icon(
            value ? Icons.check_circle : Icons.cancel_outlined,
            size: 18,
            color: value
                ? const Color(0xFF4FAE4F)
                : theme.colorScheme.error,
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// GROUP SETTINGS SHEET
// ═══════════════════════════════════════════════════════════════════════════
class GroupSettingsSheet extends StatefulWidget {
  final String chatId;
  final String currentRole;
  final bool isChannel;

  const GroupSettingsSheet({
    super.key,
    required this.chatId,
    required this.currentRole,
    required this.isChannel,
  });

  @override
  State<GroupSettingsSheet> createState() => _GroupSettingsSheetState();
}

class _GroupSettingsSheetState extends State<GroupSettingsSheet> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox(
            height: 200,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final data = snapshot.data!.data() as Map<String, dynamic>;
        final settings = data['settings'] as Map<String, dynamic>? ?? {};
        final isOwner = widget.currentRole == 'owner';

        return SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.all(16),
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.7,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.dividerColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Group Settings',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: ListView(
                    children: [
                      _buildToggle(theme,
                          label: 'Disable Chat',
                          subtitle: 'Only admins can send messages',
                          value: settings['chat_disabled'] ?? false,
                          onChanged: (v) =>
                              _updateSetting('chat_disabled', v)),
                      _buildToggle(theme,
                          label: 'Disable File Sharing',
                          subtitle:
                              'Prevent members from sending files',
                          value: settings['file_sharing_disabled'] ?? false,
                          onChanged: (v) =>
                              _updateSetting('file_sharing_disabled', v)),
                      _buildToggle(theme,
                          label: 'Announcements Only',
                          subtitle:
                              'Only admins can send announcements',
                          value: settings['announcements_only'] ?? false,
                          onChanged: isOwner
                              ? (v) => _updateSetting(
                                  'announcements_only', v)
                              : null),
                      _buildToggle(theme,
                          label: 'Enable Polls',
                          value: settings['polls_enabled'] ?? true,
                          onChanged: (v) =>
                              _updateSetting('polls_enabled', v)),
                      _buildToggle(theme,
                          label: 'Enable Reactions',
                          value: settings['reactions_enabled'] ?? true,
                          onChanged: (v) =>
                              _updateSetting('reactions_enabled', v)),
                      _buildToggle(theme,
                          label: 'Allow Forwarding',
                          value: settings['forwarding_enabled'] ?? true,
                          onChanged: (v) =>
                              _updateSetting('forwarding_enabled', v)),
                      if (isOwner)
                        _buildToggle(theme,
                            label: 'Enable Voice Chat',
                            value:
                                settings['voice_chat_enabled'] ?? false,
                            onChanged: (v) => _updateSetting(
                                'voice_chat_enabled', v)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildToggle(
    ThemeData theme, {
    required String label,
    String? subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return SwitchListTile(
      title: Text(label, style: const TextStyle(fontSize: 15)),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: TextStyle(
                color: theme.colorScheme.onSurface.withOpacity(0.5),
                fontSize: 12,
              ),
            )
          : null,
      value: value,
      onChanged: onChanged,
      activeColor: theme.colorScheme.primary,
    );
  }

  Future<void> _updateSetting(String key, bool value) async {
    await Provider.of<ChatProvider>(context, listen: false)
        .toggleSetting(widget.chatId, key, value);
  }
}
