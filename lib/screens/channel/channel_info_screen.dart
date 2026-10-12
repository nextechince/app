import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:share_plus/share_plus.dart';
import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../providers/chat_provider.dart';
import '../../services/invitation_service.dart';
import '../../utils/verified_badge.dart';

class ChannelInfoScreen extends StatefulWidget {
  final String chatId;
  final String chatName;
  final String? chatAvatar;

  const ChannelInfoScreen({
    super.key,
    required this.chatId,
    required this.chatName,
    this.chatAvatar,
  });

  @override
  State<ChannelInfoScreen> createState() => _ChannelInfoScreenState();
}

class _ChannelInfoScreenState extends State<ChannelInfoScreen> {
  bool _isLoading = false;
  String? _invitationLink;
  String? _invitationCode;

  @override
  void initState() {
    super.initState();
    _loadInvitationLink();
  }

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

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _regenerateLink() async {
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
    final memberCount = preview['member_count'] ?? 0;
    final link = preview['link'] ?? '';

    final text = 'Join $chatName on Luma Chat!\n\n'
        'Channel\n'
        'Subscribers: $memberCount\n\n'
        'Tap to join: $link';

    await Share.share(text);
  }

  void _startCall({required bool video}) {
    Navigator.pushNamed(context, '/call_screen', arguments: {
      'chatId': widget.chatId,
      'chatName': widget.chatName,
      'isVideo': video,
      'isGroup': true,
    });
  }

  // ═══════════════════════════════════════════════════════════════════════
  // ADD MEMBERS
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _showAddMembersDialog() async {
    final theme = Theme.of(context);
    final searchController = TextEditingController();
    List<Map<String, dynamic>> searchResults = [];
    List<Map<String, dynamic>> selectedUsers = [];

    await showModalBottomSheet(
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
                maxHeight: MediaQuery.of(ctx).size.height * 0.8,
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
                    'Add Subscribers',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: searchController,
                    style: TextStyle(color: theme.colorScheme.onSurface),
                    decoration: InputDecoration(
                      hintText: 'Search by username or email...',
                      prefixIcon: const Icon(Icons.search),
                    ),
                    onChanged: (query) async {
                      if (query.isEmpty) {
                        setModalState(() => searchResults = []);
                        return;
                      }
                      final results = await _searchUsers(query);
                      setModalState(() => searchResults = results);
                    },
                  ),
                  const SizedBox(height: 16),
                  if (selectedUsers.isNotEmpty) ...[
                    SizedBox(
                      height: 80,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: selectedUsers.length,
                        itemBuilder: (_, index) {
                          final user = selectedUsers[index];
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Column(
                              children: [
                                Stack(
                                  children: [
                                    _buildMemberAvatar(
                                      theme,
                                      user['avatar_url'],
                                      user['username'],
                                    ),
                                    Positioned(
                                      top: 0,
                                      right: 0,
                                      child: GestureDetector(
                                        onTap: () => setModalState(() {
                                          selectedUsers.removeWhere(
                                              (u) => u['id'] == user['id']);
                                        }),
                                        child: Container(
                                          padding:
                                              const EdgeInsets.all(2),
                                          decoration: BoxDecoration(
                                            color:
                                                theme.colorScheme.error,
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: theme
                                                  .scaffoldBackgroundColor,
                                              width: 2,
                                            ),
                                          ),
                                          child: const Icon(Icons.close,
                                              size: 10,
                                              color: Colors.white),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                SizedBox(
                                  width: 60,
                                  child: Text(
                                    user['username'] ?? 'Unknown',
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(fontSize: 11),
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Expanded(
                    child: searchResults.isEmpty
                        ? Center(
                            child: Text(
                              searchController.text.isEmpty
                                  ? 'Type to search users'
                                  : 'No users found',
                              style: TextStyle(
                                color: theme.colorScheme.onSurface
                                    .withOpacity(0.4),
                              ),
                            ),
                          )
                        : ListView.builder(
                            itemCount: searchResults.length,
                            itemBuilder: (_, index) {
                              final user = searchResults[index];
                              final isSelected = selectedUsers
                                  .any((u) => u['id'] == user['id']);
                              return ListTile(
                                leading: _buildMemberAvatar(
                                  theme,
                                  user['avatar_url'],
                                  user['username'],
                                ),
                                title: Text(user['username'] ?? 'Unknown'),
                                subtitle: Text(user['email'] ?? ''),
                                trailing: isSelected
                                    ? Icon(Icons.check_circle,
                                        color: theme.colorScheme.primary)
                                    : Icon(Icons.add_circle_outline,
                                        color: theme.colorScheme.onSurface
                                            .withOpacity(0.4)),
                                onTap: () => setModalState(() {
                                  if (isSelected) {
                                    selectedUsers.removeWhere(
                                        (u) => u['id'] == user['id']);
                                  } else {
                                    selectedUsers.add(user);
                                  }
                                }),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: selectedUsers.isEmpty
                          ? null
                          : () async {
                              Navigator.pop(ctx);
                              await _addMembers(selectedUsers);
                            },
                      child: Text(
                        'Add ${selectedUsers.length} Subscriber${selectedUsers.length > 1 ? 's' : ''}',
                      ),
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

  Future<List<Map<String, dynamic>>> _searchUsers(String query) async {
    try {
      final authProvider =
          Provider.of<LumaAuthProvider>(context, listen: false);
      final currentUserId =
          authProvider.user?.uid ?? authProvider.mockUserId;

      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .where('username', isGreaterThanOrEqualTo: query)
          .where('username', isLessThanOrEqualTo: '$query\uf8ff')
          .limit(20)
          .get();

      return snapshot.docs
          .map((doc) => {'id': doc.id, ...doc.data()})
          .where((u) => u['id'] != currentUserId)
          .toList();
    } catch (e) {
      debugPrint('Search error: $e');
      return [];
    }
  }

  Future<void> _addMembers(List<Map<String, dynamic>> users) async {
    try {
      final firestore = FirebaseFirestore.instance;
      final chatRef = firestore.collection('chats').doc(widget.chatId);

      final blockedUsers = <Map<String, dynamic>>[];
      final addedUsers = <Map<String, dynamic>>[];

      for (final user in users) {
        final userId = user['id'] as String;
        final userDoc = await firestore.collection('users').doc(userId).get();
        final privacy =
            userDoc.data()?['privacy_settings'] as Map<String, dynamic>?;
        final allowAddToGroup = privacy?['allow_add_to_group'] ?? true;

        if (!allowAddToGroup) {
          blockedUsers.add(user);
        } else {
          addedUsers.add(user);
          await chatRef.update({
            'participants': FieldValue.arrayUnion([userId]),
            'participants_data.$userId': {
              'role': 'subscriber',
              'joined_at': FieldValue.serverTimestamp(),
            },
            'member_count': FieldValue.increment(1),
          });

          await firestore
              .collection('users')
              .doc(userId)
              .collection('notifications')
              .add({
            'type': 'added_to_channel',
            'chat_id': widget.chatId,
            'chat_name': widget.chatName,
            'timestamp': FieldValue.serverTimestamp(),
            'read': false,
          });
        }
      }

      if (!mounted) return;
      if (addedUsers.isNotEmpty) {
        _toast('Added ${addedUsers.length} subscriber(s)');
      }
      if (blockedUsers.isNotEmpty) {
        _showBlockedUsersDialog(blockedUsers);
      }
    } catch (e) {
      debugPrint('Add members error: $e');
      _toast('Failed to add members: $e');
    }
  }

  void _showBlockedUsersDialog(List<Map<String, dynamic>> blockedUsers) {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cannot Add Users'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'These users have disabled being added to groups/channels:',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.7),
              ),
            ),
            const SizedBox(height: 12),
            ...blockedUsers.map((user) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      _buildMemberAvatar(
                          theme, user['avatar_url'], user['username']),
                      const SizedBox(width: 8),
                      Text(user['username'] ?? 'Unknown'),
                    ],
                  ),
                )),
            const SizedBox(height: 16),
            Text(
              'Send them the invitation link instead.',
              style: TextStyle(
                color: theme.colorScheme.primary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _shareInvitationLink();
            },
            icon: const Icon(Icons.share, size: 16),
            label: const Text('Send Link'),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // MEMBER OPTIONS
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
              if (myRole == 'owner' && memberRole == 'subscriber')
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
    return (data['participants_data']?[userId]?['role'] ?? 'subscriber')
        as String;
  }

  void _confirmKick(String memberId, String memberName) {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $memberName?'),
        content: const Text('They will be removed from this channel.'),
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
      builder: (ctx) => ChannelSettingsSheet(
        chatId: widget.chatId,
        currentRole: currentRole,
      ),
    );
  }

  Future<void> _leaveChannel() async {
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
        (data['participants_data']?[userId]?['role'] ?? 'subscriber')
            as String;

    if (myRole == 'owner') {
      _toast('Owner cannot leave. Delete the channel instead.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave Channel?'),
        content: const Text(
            'You will no longer receive messages from this channel.'),
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

  Future<void> _deleteChannel() async {
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
        (data['participants_data']?[userId]?['role'] ?? 'subscriber')
            as String;

    if (myRole != 'owner') {
      _toast('Only the owner can delete this channel');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Channel?'),
        content: const Text(
          'This will permanently delete the channel and all its messages. This action cannot be undone.',
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
        _toast('Channel deleted');
        Navigator.pop(context);
      } else if (mounted) {
        _toast(chatProvider.error ?? 'Failed to delete channel');
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
        title: const Text('Channel Info'),
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
                          'subscriber') as String;
              final canManage = myRole == 'owner' || myRole == 'admin';
              final isOwner = myRole == 'owner';

              return Row(
                children: [
                  if (isOwner || myRole == 'admin') ...[
                    IconButton(
                      icon: const Icon(Icons.videocam_outlined),
                      onPressed: () => _startCall(video: true),
                    ),
                    IconButton(
                      icon: const Icon(Icons.call_outlined),
                      onPressed: () => _startCall(video: false),
                    ),
                  ],
                  if (canManage)
                    IconButton(
                      icon: const Icon(Icons.person_add_outlined),
                      onPressed: () => _showAddMembersDialog(),
                    ),
                  IconButton(
                    icon: const Icon(Icons.share_outlined),
                    onPressed: _shareInvitationLink,
                  ),
                  if (canManage)
                    IconButton(
                      icon: const Icon(Icons.settings_outlined),
                      onPressed: () => _showSettings(myRole),
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
              'subscriber') as String;
          final canManage = myRole == 'owner' || myRole == 'admin';
          final isOwner = myRole == 'owner';

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Channel header ──
                Center(
                  child: Column(
                    children: [
                      _buildAvatar(theme, data['avatar_url']),
                      const SizedBox(height: 12),
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
                      if (description.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 24),
                          child: Text(
                            description,
                            textAlign: TextAlign.center,
                            style:
                                theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurface
                                  .withOpacity(0.6),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        '$memberCount subscriber${memberCount == 1 ? '' : 's'} • Channel',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface
                              .withOpacity(0.5),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // ── Actions ──
                Row(
                  children: [
                    Expanded(
                      child: _buildActionButton(
                        theme,
                        icon: Icons.share_outlined,
                        label: 'Invite',
                        onTap: _shareInvitationLink,
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (!isOwner) ...[
                      Expanded(
                        child: _buildActionButton(
                          theme,
                          icon: Icons.exit_to_app,
                          label: 'Leave',
                          color: theme.colorScheme.error,
                          onTap: _leaveChannel,
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    if (isOwner) ...[
                      Expanded(
                        child: _buildActionButton(
                          theme,
                          icon: Icons.delete_forever_outlined,
                          label: 'Delete',
                          color: theme.colorScheme.error,
                          onTap: _deleteChannel,
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                  ],
                ),
                const SizedBox(height: 24),

                // ── Invitation link ──
                if (_invitationLink != null &&
                    _invitationLink!.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: theme.colorScheme.primary.withOpacity(0.2),
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
                                onTap: _isLoading ? null : _regenerateLink,
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
                                  side: BorderSide(color: theme.dividerColor),
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

                // ── Info block ──
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withOpacity(0.03),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      _buildInfoRow(
                        theme,
                        icon: Icons.campaign_outlined,
                        label: 'Channel Type',
                        value: 'Broadcast',
                      ),
                      _buildInfoRow(
                        theme,
                        icon: Icons.admin_panel_settings_outlined,
                        label: 'Messaging',
                        value: 'Admin-only',
                      ),
                      _buildInfoRow(
                        theme,
                        icon: Icons.visibility_outlined,
                        label: 'Subscribers can',
                        value: 'View only',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // ── Settings preview (admins only) ──
                if (canManage) ...[
                  _sectionTitle(theme, 'SETTINGS'),
                  const SizedBox(height: 8),
                  _buildSettingsPreview(theme, data),
                  const SizedBox(height: 24),
                ],

                // ── Members section ──
                if (canManage) ...[
                  // Admins see the full member list
                  _sectionTitle(theme, 'SUBSCRIBERS ($memberCount)'),
                  const SizedBox(height: 8),
                  FutureBuilder<List<Map<String, dynamic>>>(
                    future: Future.wait(participants.map((uid) async {
                      final doc = await FirebaseFirestore.instance
                          .collection('users')
                          .doc(uid)
                          .get();
                      final userData = doc.data() ?? {};
                      final role = (data['participants_data']?[uid]?['role'] ??
                          'subscriber') as String;
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
                          'subscriber': 2,
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
                                        : 'Subscriber',
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
                                      onPressed: () => _showMemberOptions(
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
                  // Non-admins just see a count, no member list
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
                          '$memberCount subscriber${memberCount == 1 ? '' : 's'}',
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
      child: Icon(Icons.campaign,
          size: 44, color: theme.colorScheme.primary),
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

  Widget _buildInfoRow(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon,
              size: 20,
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
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
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
// CHANNEL SETTINGS SHEET
// ═══════════════════════════════════════════════════════════════════════════
class ChannelSettingsSheet extends StatefulWidget {
  final String chatId;
  final String currentRole;

  const ChannelSettingsSheet({
    super.key,
    required this.chatId,
    required this.currentRole,
  });

  @override
  State<ChannelSettingsSheet> createState() => _ChannelSettingsSheetState();
}

class _ChannelSettingsSheetState extends State<ChannelSettingsSheet> {
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
                  'Channel Settings',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: ListView(
                    children: [
                      _buildToggle(
                        theme,
                        label: 'Disable Chat',
                        subtitle: 'Only admins can send messages',
                        value: settings['chat_disabled'] ?? false,
                        onChanged: (v) =>
                            _updateSetting('chat_disabled', v),
                      ),
                      _buildToggle(
                        theme,
                        label: 'Disable File Sharing',
                        subtitle:
                            'Prevent subscribers from sending files',
                        value: settings['file_sharing_disabled'] ?? false,
                        onChanged: (v) =>
                            _updateSetting('file_sharing_disabled', v),
                      ),
                      _buildToggle(
                        theme,
                        label: 'Enable Polls',
                        value: settings['polls_enabled'] ?? true,
                        onChanged: (v) =>
                            _updateSetting('polls_enabled', v),
                      ),
                      _buildToggle(
                        theme,
                        label: 'Enable Reactions',
                        value: settings['reactions_enabled'] ?? true,
                        onChanged: (v) =>
                            _updateSetting('reactions_enabled', v),
                      ),
                      _buildToggle(
                        theme,
                        label: 'Allow Forwarding',
                        value: settings['forwarding_enabled'] ?? true,
                        onChanged: (v) =>
                            _updateSetting('forwarding_enabled', v),
                      ),
                      if (isOwner)
                        _buildToggle(
                          theme,
                          label: 'Enable Voice Chat',
                          value: settings['voice_chat_enabled'] ?? false,
                          onChanged: (v) =>
                              _updateSetting('voice_chat_enabled', v),
                        ),
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
