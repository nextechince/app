import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../providers/chat_provider.dart';
import '../../utils/verified_badge.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final authProvider = Provider.of<LumaAuthProvider>(context);
    final userId = authProvider.user?.uid ?? authProvider.mockUserId;

    if (userId == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('chats')
            .where('participants', arrayContains: userId)
            .orderBy('last_message_at', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error: ${snapshot.error}',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
            );
          }

          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final chats = snapshot.data!.docs;

          if (chats.isEmpty) {
            return _emptyState(theme);
          }

          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: chats.length,
            itemBuilder: (context, index) {
              final chat = chats[index].data() as Map<String, dynamic>;
              chat['id'] = chats[index].id;

              final isGroupOrChannel =
                  ['group', 'channel'].contains(chat['type']);
              final lastMessage = chat['last_message'] ?? '';
              final lastMessageType = chat['last_message_type'] ?? 'text';

              DateTime? lastMessageAt;
              if (chat['last_message_at'] != null) {
                final val = chat['last_message_at'];
                if (val is DateTime) {
                  lastMessageAt = val;
                } else if (val is Timestamp) {
                  lastMessageAt = val.toDate();
                } else if (val is String) {
                  lastMessageAt = DateTime.tryParse(val)?.toLocal();
                } else {
                  lastMessageAt = DateTime.tryParse(val.toString())?.toLocal();
                }
              }

              final unreadCount = chat['unread_count'] ?? 0;
              final isPinned = chat['is_pinned'] ?? false;

              if (isGroupOrChannel) {
                return _buildGroupOrChannelTile(
                  context,
                  chat,
                  lastMessage,
                  lastMessageType,
                  lastMessageAt,
                  unreadCount,
                  isPinned,
                );
              } else {
                return _buildDirectChatTile(
                  context,
                  chat,
                  lastMessage,
                  lastMessageType,
                  lastMessageAt,
                  unreadCount,
                  isPinned,
                );
              }
            },
          );
        },
      ),
    );
  }

  Widget _emptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 72,
              color: theme.colorScheme.onSurface.withOpacity(0.15),
            ),
            const SizedBox(height: 16),
            Text(
              'No messages yet',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Start a conversation!',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP / CHANNEL TILE
  // ═══════════════════════════════════════════════════════════════════════════
  Widget _buildGroupOrChannelTile(
    BuildContext context,
    Map<String, dynamic> chat,
    String lastMessage,
    String lastMessageType,
    DateTime? lastMessageAt,
    int unreadCount,
    bool isPinned,
  ) {
    final theme = Theme.of(context);
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);
    final name = chat['name'] ?? chat['title'] ?? 'Unknown';
    final avatarUrl = chat['avatar_url'] as String?;
    final type = chat['type'] as String? ?? 'group';
    final createdByEmail = chat['created_by_email'] as String?;

    return Slidable(
      key: ValueKey(chat['id']),
      endActionPane: ActionPane(
        motion: const ScrollMotion(),
        children: [
          SlidableAction(
            onPressed: (_) => chatProvider.archiveChat(chat['id']),
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: Colors.white,
            icon: Icons.archive,
            label: 'Archive',
          ),
          SlidableAction(
            onPressed: (_) => _showDeleteDialog(context, chat['id']),
            backgroundColor: theme.colorScheme.error,
            foregroundColor: Colors.white,
            icon: Icons.delete,
            label: 'Delete',
          ),
        ],
      ),
      child: InkWell(
        onTap: () {
          if (type == 'channel') {
            Navigator.pushNamed(
              context,
              '/channel',
              arguments: {
                'channelId': chat['id'],
                'channelName': name,
              },
            );
          } else {
            Navigator.pushNamed(
              context,
              '/chat',
              arguments: {
                'chatId': chat['id'],
                'chatName': name,
                'isGroup': true,
              },
            );
          }
        },
        onLongPress: () => _showChatOptions(context, chat, true),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Stack(
                children: [
                  _buildAvatar(avatarUrl, name, type == 'channel'),
                  if (isPinned)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: theme.scaffoldBackgroundColor,
                            width: 2,
                          ),
                        ),
                        child: const Icon(
                          Icons.push_pin,
                          size: 10,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: VerifiedUsername(
                            username: name,
                            email: createdByEmail,
                            style: TextStyle(
                              color: theme.colorScheme.onSurface,
                              fontWeight: FontWeight.w500,
                              fontSize: 16,
                            ),
                            badgeSize: 14,
                            spacing: 4,
                          ),
                        ),
                        if (lastMessageAt != null)
                          Text(
                            _formatChatListTime(lastMessageAt),
                            style: TextStyle(
                              color: unreadCount > 0
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurface
                                      .withOpacity(0.4),
                              fontSize: 12,
                              fontWeight: unreadCount > 0
                                  ? FontWeight.w500
                                  : FontWeight.normal,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _getMessagePreview(
                                lastMessage, lastMessageType),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: unreadCount > 0
                                  ? theme.colorScheme.onSurface
                                      .withOpacity(0.75)
                                  : theme.colorScheme.onSurface
                                      .withOpacity(0.55),
                              fontSize: 14,
                            ),
                          ),
                        ),
                        if (unreadCount > 0)
                          Container(
                            margin: const EdgeInsets.only(left: 8),
                            constraints: const BoxConstraints(minWidth: 22),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              borderRadius: BorderRadius.circular(11),
                            ),
                            child: Text(
                              unreadCount > 999 ? '999+' : '$unreadCount',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // DIRECT CHAT TILE
  // ═══════════════════════════════════════════════════════════════════════════
  Widget _buildDirectChatTile(
    BuildContext context,
    Map<String, dynamic> chat,
    String lastMessage,
    String lastMessageType,
    DateTime? lastMessageAt,
    int unreadCount,
    bool isPinned,
  ) {
    final theme = Theme.of(context);
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);
    final authProvider =
        Provider.of<LumaAuthProvider>(context, listen: false);
    final userId = authProvider.user?.uid ?? authProvider.mockUserId;

    final participants = List<String>.from(chat['participants'] ?? []);
    final otherUserId = participants.firstWhere(
      (id) => id != userId,
      orElse: () => '',
    );

    if (otherUserId.isEmpty) return const SizedBox.shrink();

    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance
          .collection('users')
          .doc(otherUserId)
          .get(),
      builder: (context, userSnapshot) {
        if (!userSnapshot.hasData) return const SizedBox.shrink();

        final userData =
            userSnapshot.data!.data() as Map<String, dynamic>? ?? {};
        final displayName = userData['display_name'] ??
            userData['username'] ??
            userData['name'] ??
            'Unknown';
        final avatarUrl = userData['avatar_url'] as String?;
        final email = userData['email'] as String?;
        final isOnline = userData['is_online'] as bool? ?? false;

        return Slidable(
          key: ValueKey(chat['id']),
          endActionPane: ActionPane(
            motion: const ScrollMotion(),
            children: [
              SlidableAction(
                onPressed: (_) => chatProvider.archiveChat(chat['id']),
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: Colors.white,
                icon: Icons.archive,
                label: 'Archive',
              ),
              SlidableAction(
                onPressed: (_) => _showDeleteDialog(context, chat['id']),
                backgroundColor: theme.colorScheme.error,
                foregroundColor: Colors.white,
                icon: Icons.delete,
                label: 'Delete',
              ),
            ],
          ),
          child: InkWell(
            onTap: () {
              Navigator.pushNamed(
                context,
                '/chat',
                arguments: {
                  'chatId': chat['id'],
                  'chatName': displayName,
                  'isGroup': false,
                  'otherUserId': otherUserId,
                },
              );
            },
            onLongPress: () => _showDirectChatOptions(
                context, chat['id'], displayName.toString()),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Stack(
                    children: [
                      _buildAvatar(avatarUrl, displayName.toString(), false),
                      if (isOnline)
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: const Color(0xFF4FAE4F),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: theme.scaffoldBackgroundColor,
                                width: 2,
                              ),
                            ),
                          ),
                        ),
                      if (isPinned)
                        Positioned(
                          right: 0,
                          top: 0,
                          child: Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: theme.scaffoldBackgroundColor,
                                width: 2,
                              ),
                            ),
                            child: const Icon(
                              Icons.push_pin,
                              size: 10,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: VerifiedUsername(
                                username: displayName.toString(),
                                email: email,
                                style: TextStyle(
                                  color: theme.colorScheme.onSurface,
                                  fontWeight: FontWeight.w500,
                                  fontSize: 16,
                                ),
                                badgeSize: 14,
                                spacing: 4,
                              ),
                            ),
                            if (lastMessageAt != null)
                              Text(
                                _formatChatListTime(lastMessageAt),
                                style: TextStyle(
                                  color: unreadCount > 0
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.onSurface
                                          .withOpacity(0.4),
                                  fontSize: 12,
                                  fontWeight: unreadCount > 0
                                      ? FontWeight.w500
                                      : FontWeight.normal,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _getMessagePreview(
                                    lastMessage, lastMessageType),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: unreadCount > 0
                                      ? theme.colorScheme.onSurface
                                          .withOpacity(0.75)
                                      : theme.colorScheme.onSurface
                                          .withOpacity(0.55),
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            if (unreadCount > 0)
                              Container(
                                margin: const EdgeInsets.only(left: 8),
                                constraints:
                                    const BoxConstraints(minWidth: 22),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary,
                                  borderRadius: BorderRadius.circular(11),
                                ),
                                child: Text(
                                  unreadCount > 999
                                      ? '999+'
                                      : '$unreadCount',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // AVATAR
  // ═══════════════════════════════════════════════════════════════════════════
  Widget _buildAvatar(String? url, String name, bool isChannel) {
    final theme = Theme.of(context);

    if (url != null && url.isNotEmpty) {
      return CircleAvatar(
        radius: 27,
        backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
        backgroundImage: NetworkImage(url),
        onBackgroundImageError: (_, __) {},
      );
    }

    return CircleAvatar(
      radius: 27,
      backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
      child: Icon(
        isChannel ? Icons.campaign : Icons.person,
        color: theme.colorScheme.primary,
        size: 24,
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // HELPERS
  // ═══════════════════════════════════════════════════════════════════════════
  String _getMessagePreview(String message, String type) {
    switch (type) {
      case 'image':
        return '📷 Photo';
      case 'video':
        return '🎥 Video';
      case 'audio':
        return '🎤 Voice message';
      case 'file':
        return '📎 File';
      case 'location':
        return '📍 Location';
      default:
        return message;
    }
  }

  String _formatChatListTime(DateTime? dateTime) {
    if (dateTime == null) return '';

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate =
        DateTime(dateTime.year, dateTime.month, dateTime.day);
    final diffDays = today.difference(messageDate).inDays;

    if (diffDays == 0) {
      final diffMinutes = now.difference(dateTime).inMinutes;
      if (diffMinutes < 1) return 'Now';
      if (diffMinutes < 60) return '${diffMinutes}m';
      final hour = dateTime.hour.toString().padLeft(2, '0');
      final minute = dateTime.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    } else if (diffDays == 1) {
      return 'Yesterday';
    } else if (diffDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[dateTime.weekday - 1];
    } else if (dateTime.year == now.year) {
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      return '${months[dateTime.month - 1]} ${dateTime.day}';
    } else {
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      return '${months[dateTime.month - 1]} ${dateTime.day}, ${dateTime.year}';
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SHEETS
  // ═══════════════════════════════════════════════════════════════════════════
  void _showChatOptions(
      BuildContext context, Map<String, dynamic> chat, bool isGroup) {
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
              ListTile(
                leading: Icon(Icons.push_pin,
                    color: theme.colorScheme.onSurface.withOpacity(0.75)),
                title: const Text('Pin Chat'),
                onTap: () {
                  Navigator.pop(context);
                  Provider.of<ChatProvider>(context, listen: false)
                      .togglePinChat(chat['id']);
                },
              ),
              ListTile(
                leading: Icon(Icons.archive_outlined,
                    color: theme.colorScheme.onSurface.withOpacity(0.75)),
                title: const Text('Archive'),
                onTap: () {
                  Navigator.pop(context);
                  Provider.of<ChatProvider>(context, listen: false)
                      .archiveChat(chat['id']);
                },
              ),
              ListTile(
                leading:
                    Icon(Icons.delete_outline, color: theme.colorScheme.error),
                title: Text('Delete Chat',
                    style: TextStyle(color: theme.colorScheme.error)),
                onTap: () {
                  Navigator.pop(context);
                  _showDeleteDialog(context, chat['id']);
                },
              ),
              if (isGroup)
                ListTile(
                  leading: const Icon(Icons.exit_to_app, color: Color(0xFFE0954A)),
                  title: const Text('Leave Group',
                      style: TextStyle(color: Color(0xFFE0954A))),
                  onTap: () {
                    Navigator.pop(context);
                    _showLeaveDialog(context, chat['id']);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDirectChatOptions(
      BuildContext context, String chatId, String userName) {
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
              ListTile(
                leading: Icon(Icons.push_pin,
                    color: theme.colorScheme.onSurface.withOpacity(0.75)),
                title: const Text('Pin Chat'),
                onTap: () {
                  Navigator.pop(context);
                  Provider.of<ChatProvider>(context, listen: false)
                      .togglePinChat(chatId);
                },
              ),
              ListTile(
                leading: Icon(Icons.archive_outlined,
                    color: theme.colorScheme.onSurface.withOpacity(0.75)),
                title: const Text('Archive'),
                onTap: () {
                  Navigator.pop(context);
                  Provider.of<ChatProvider>(context, listen: false)
                      .archiveChat(chatId);
                },
              ),
              ListTile(
                leading:
                    Icon(Icons.delete_outline, color: theme.colorScheme.error),
                title: Text('Delete Chat',
                    style: TextStyle(color: theme.colorScheme.error)),
                onTap: () {
                  Navigator.pop(context);
                  _showDeleteDialog(context, chatId);
                },
              ),
              ListTile(
                leading:
                    const Icon(Icons.block, color: Color(0xFFE0954A)),
                title: const Text('Block User',
                    style: TextStyle(color: Color(0xFFE0954A))),
                onTap: () {
                  Navigator.pop(context);
                  _showBlockDialog(context, chatId, userName);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDeleteDialog(BuildContext context, String chatId) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Chat?'),
        content: const Text(
          'This will delete the chat from your list. Messages will still be visible to other participants.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              Provider.of<ChatProvider>(context, listen: false)
                  .deleteChat(chatId);
            },
            style:
                TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _showLeaveDialog(BuildContext context, String chatId) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave Group?'),
        content: const Text(
          'You will no longer receive messages from this group.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              Provider.of<ChatProvider>(context, listen: false)
                  .leaveChat(chatId);
            },
            style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFE0954A)),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
  }

  void _showBlockDialog(
      BuildContext context, String chatId, String userName) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Block $userName?'),
        content: Text(
          'You will no longer receive messages from $userName.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              // TODO: implement block
            },
            style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFE0954A)),
            child: const Text('Block'),
          ),
        ],
      ),
    );
  }
}
