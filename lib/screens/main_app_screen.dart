import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';

import '../providers/auth_provider.dart' show LumaAuthProvider;
import '../providers/chat_provider.dart';
import 'contacts/contacts_screen.dart';
import 'status/status_screen.dart';
import 'settings/settings_screen.dart';

class MainAppScreen extends StatefulWidget {
  const MainAppScreen({super.key});

  @override
  State<MainAppScreen> createState() => _MainAppScreenState();
}

class _MainAppScreenState extends State<MainAppScreen> {
  int _bottomIndex = 0;
  int _folderIndex = 0;

  final Map<String, Map<String, dynamic>> _userCache = {};
  final Set<String> _inFlight = {};
  List<String> _myBlockedUsers = [];

  final ScrollController _folderScroll = ScrollController();

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = Provider.of<LumaAuthProvider>(context, listen: false);
      final chat = Provider.of<ChatProvider>(context, listen: false);

      if (auth.mockUserId != null) {
        chat.setMockUser(auth.mockUserId!);
      } else {
        chat.loadChats();
      }
      _listenToMyBlockedUsers();
    });
  }

  @override
  void dispose() {
    _folderScroll.dispose();
    super.dispose();
  }

  String get _myUid {
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    final fromProvider = auth.currentUserId ?? auth.mockUserId;
    if (fromProvider != null && fromProvider.isNotEmpty) return fromProvider;
    return FirebaseAuth.instance.currentUser?.uid ?? '';
  }

  void _listenToMyBlockedUsers() {
    final uid = _myUid;
    if (uid.isEmpty) return;
    FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots()
        .listen((doc) {
      if (!mounted || !doc.exists) return;
      setState(() {
        _myBlockedUsers =
            List<String>.from(doc.data()?['blocked_users'] ?? []);
      });
    });
  }

  Future<void> _fetchOtherUser(String uid) async {
    if (uid.isEmpty) return;
    if (_userCache.containsKey(uid)) return;
    if (_inFlight.contains(uid)) return;
    _inFlight.add(uid);
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      if (doc.exists && doc.data() != null) {
        final d = doc.data()!;
        _userCache[uid] = {
          'uid': uid,
          'username': (d['username'] ?? '') as String,
          'display_name': (d['display_name'] ??
              d['username'] ??
              d['name'] ??
              'Unknown') as String,
          'avatar_url': d['avatar_url'],
          'email': d['email'],
          'is_bot': d['is_bot'] == true,
        };
      } else {
        _userCache[uid] = {
          'uid': uid,
          'username': '',
          'display_name': 'User',
          'avatar_url': null,
          'email': null,
          'is_bot': false,
        };
      }
      if (mounted) setState(() {});
    } catch (_) {
      _userCache[uid] = {
        'uid': uid,
        'username': '',
        'display_name': 'User',
        'avatar_url': null,
        'email': null,
        'is_bot': false,
      };
      if (mounted) setState(() {});
    } finally {
      _inFlight.remove(uid);
    }
  }

  String _formatChatTime(dynamic lastMessageAt) {
    if (lastMessageAt == null) return '';
    DateTime dt;
    if (lastMessageAt is Timestamp) {
      dt = lastMessageAt.toDate();
    } else if (lastMessageAt is DateTime) {
      dt = lastMessageAt;
    } else {
      return '';
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(dt.year, dt.month, dt.day);
    final diffDays = today.difference(msgDay).inDays;
    if (diffDays == 0) return DateFormat('HH:mm').format(dt);
    if (diffDays == 1) return 'Yesterday';
    if (diffDays < 7) return DateFormat('EEE').format(dt);
    return DateFormat('MM/dd/yy').format(dt);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (!didPop) SystemNavigator.pop();
      },
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: IndexedStack(
          index: _bottomIndex,
          children: [
            _buildChatsTab(),
            const ContactsScreen(),
            const StatusScreen(),
            const SettingsScreen(),
          ],
        ),
        floatingActionButton: _buildFAB(),
        bottomNavigationBar: _buildBottomNav(),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // BOTTOM NAV
  // ═══════════════════════════════════════════════════════════════════════

  Widget _buildBottomNav() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final items = const [
      _NavItem(
          icon: Icons.chat_bubble_outline,
          active: Icons.chat_bubble,
          label: 'Chats'),
      _NavItem(
          icon: Icons.contacts_outlined,
          active: Icons.contacts,
          label: 'Contacts'),
      _NavItem(
          icon: Icons.donut_large_outlined,
          active: Icons.donut_large,
          label: 'Status'),
      _NavItem(
          icon: Icons.settings_outlined,
          active: Icons.settings,
          label: 'Settings'),
    ];

    return Container(
      decoration: BoxDecoration(
        // Pure black or extremely dark background to match the WhatsApp dark theme
        color: isDark ? const Color(0xFF000000) : Colors.white,
        border: Border(
          top: BorderSide(
            color: isDark ? const Color(0xFF1A1A1A) : const Color(0xFFE4E4E5),
            width: 0.5,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: List.generate(items.length, (i) {
              final item = items[i];
              final selected = i == _bottomIndex;
              final color = selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface.withOpacity(0.5);

              return Expanded(
                child: InkWell(
                  onTap: () => setState(() => _bottomIndex = i),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(selected ? item.active : item.icon,
                          size: 24, color: color),
                      const SizedBox(height: 2),
                      Text(
                        item.label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // FAB — only on Chats (WhatsApp Style)
  // ═══════════════════════════════════════════════════════════════════════

  Widget? _buildFAB() {
    if (_bottomIndex != 0) return null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0, right: 8.0),
      child: FloatingActionButton(
        backgroundColor: const Color(0xFF3390EC), // WhatsApp/Telegram Blue
        foregroundColor: Colors.white,
        elevation: 3,
        shape: const CircleBorder(), // Perfect circle
        onPressed: () => _showNewChatOptions(context),
        child: const Icon(Icons.add_comment, size: 26), // WhatsApp chat icon
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // CHATS TAB
  // ═══════════════════════════════════════════════════════════════════════

  Widget _buildChatsTab() {
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          _buildChatsAppBar(),
          _buildFolderPills(),
          Expanded(child: _buildChatsList()),
        ],
      ),
    );
  }

  Widget _buildChatsAppBar() {
    final theme = Theme.of(context);
    final auth = context.watch<LumaAuthProvider>();
    final avatar = auth.userPhotoUrl;
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pushNamed(context, '/profile'),
            child: CircleAvatar(
              radius: 18,
              backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
              backgroundImage: (avatar != null && avatar.isNotEmpty)
                  ? NetworkImage(avatar)
                  : null,
              child: (avatar == null || avatar.isEmpty)
                  ? Icon(Icons.person,
                      size: 20, color: theme.colorScheme.primary)
                  : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Luma Chat',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.search, color: theme.colorScheme.onSurface),
            onPressed: () => Navigator.pushNamed(context, '/global_search'),
          ),
          // ═══════════════════════════════════════════════════════════════
          // NEW WHATSAPP STYLE DROPDOWN MENU (Replaces Bottom Sheet)
          // ═══════════════════════════════════════════════════════════════
          PopupMenuButton<String>(
            color: isDark ? const Color(0xFF1F2C34) : Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            icon: Icon(Icons.more_vert, color: theme.colorScheme.onSurface),
            onSelected: (value) {
              if (value == 'new_group') {
                Navigator.pushNamed(context, '/create_group');
              } else if (value == 'settings') {
                setState(() => _bottomIndex = 3); // Go to Settings tab
              } else if (value == 'starred') {
                Navigator.pushNamed(context, '/saved_messages');
              } else if (value == 'linked_devices') {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Linked Devices coming soon')));
              } else if (value == 'new_broadcast') {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Broadcast lists coming soon')));
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'new_group',
                child: Text('New group', style: TextStyle(fontSize: 15)),
              ),
              const PopupMenuItem(
                value: 'new_broadcast',
                child: Text('New broadcast', style: TextStyle(fontSize: 15)),
              ),
              const PopupMenuItem(
                value: 'linked_devices',
                child: Text('Linked devices', style: TextStyle(fontSize: 15)),
              ),
              const PopupMenuItem(
                value: 'starred',
                child: Text('Starred messages', style: TextStyle(fontSize: 15)),
              ),
              const PopupMenuItem(
                value: 'settings',
                child: Text('Settings', style: TextStyle(fontSize: 15)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── Folder pills (Reduced to only "All Chats" + Custom Tab button) ───
  Widget _buildFolderPills() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final chats = context.watch<ChatProvider>().chats;

    return SizedBox(
      height: 44,
      child: ListView(
        controller: _folderScroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        children: [
          // All Chats Pill
          GestureDetector(
            onTap: () => setState(() => _folderIndex = 0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF2A3A52) : const Color(0xFFE8EDF2),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'All Chats',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${chats.length}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          
          // Telegram Style "Add Tab" Button
          GestureDetector(
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Custom Chat Folders coming soon!')));
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1A1A1A) : const Color(0xFFF1F1F1),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Icon(Icons.add, size: 20, color: theme.colorScheme.onSurface.withOpacity(0.6)),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Chat list ───
  Widget _buildChatsList() {
    final theme = Theme.of(context);

    return Consumer<ChatProvider>(
      builder: (context, chatProvider, _) {
        if (chatProvider.isLoading) {
          return Center(
            child:
                CircularProgressIndicator(color: theme.colorScheme.primary),
          );
        }

        final allChats = chatProvider.chats;
        final visible = allChats; // No more filtering by folders!

        if (visible.isEmpty) return _buildEmptyState();

        return ListView.builder(
          padding: const EdgeInsets.only(top: 4, bottom: 96),
          itemCount: visible.length,
          itemBuilder: (context, i) => _buildChatTile(visible[i]),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    final theme = Theme.of(context);
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
              'No chats yet',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              'Start a conversation by tapping the chat button.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Chat tile with SWIPE actions ───
  Widget _buildChatTile(Map<String, dynamic> chat) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final chatId = chat['id'] as String? ?? '';
    final chatType = chat['type'] as String? ?? 'direct';
    final isGroup = chatType == 'group';
    final isChannel = chatType == 'channel';
    final isBot = chatType == 'bot' || chat['is_bot'] == true;
    final isDirect = chatType == 'direct';
    final myUid = _myUid;

    String name;
    String? avatar;
    String? otherUserId;

    if (isDirect) {
      final participants = List<String>.from(chat['participants'] ?? []);
      otherUserId =
          participants.firstWhere((id) => id != myUid, orElse: () => '');
      if (otherUserId.isNotEmpty && !_userCache.containsKey(otherUserId)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _fetchOtherUser(otherUserId!);
        });
      }
      final cached = otherUserId.isNotEmpty ? _userCache[otherUserId] : null;
      if (cached != null) {
        name = cached['display_name'] as String? ?? 'User';
        avatar = cached['avatar_url'] as String?;
      } else {
        name = 'Loading…';
        avatar = null;
      }
    } else {
      name = (chat['name'] ?? chat['title'] ?? 'Unknown') as String;
      avatar = chat['avatar_url'] as String?;
    }

    final lastMessage = chat['last_message'] ?? '';
    final unread = (chat['unread_count'] as num?)?.toInt() ?? 0;

    final isPinned = chat['is_pinned'] == true;
    final participantsData =
        chat['participants_data'] as Map<String, dynamic>? ?? {};
    final myData = participantsData[myUid] as Map<String, dynamic>? ?? {};
    final isArchived = myData['is_archived'] == true;

    final mutedFor = List<String>.from(chat['muted_for'] ?? []);
    final isMuted = mutedFor.contains(myUid);

    final isBlockedByMe = isDirect &&
        otherUserId != null &&
        otherUserId.isNotEmpty &&
        _myBlockedUsers.contains(otherUserId);

    final route = isBot ? '/bot' : (isChannel ? '/channel' : '/chat');
    final routeArgs = isBot
        ? {'chatId': chatId, 'botName': name}
        : isChannel
            ? {'channelId': chatId, 'channelName': name}
            : {
                'chatId': chatId,
                'chatName': name,
                'chatAvatar': avatar,
                'isGroup': isGroup,
                'otherUserId': otherUserId,
              };

    final isSticker =
        lastMessage.toString().toLowerCase().contains('sticker');
    final previewText = isBlockedByMe
        ? 'Blocked'
        : isSticker
            ? '🌟 Sticker'
            : lastMessage;

    final tile = InkWell(
      onTap: () => Navigator.pushNamed(context, route, arguments: routeArgs),
      onLongPress: () => _showChatContextMenu(
        context: context,
        chat: chat,
        chatId: chatId,
        isDirect: isDirect,
        isGroup: isGroup,
        isChannel: isChannel,
        otherUserId: otherUserId,
        isPinned: isPinned,
        isMuted: isMuted,
        isBlockedByMe: isBlockedByMe,
        isArchived: isArchived,
        name: name,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Stack(
              children: [
                CircleAvatar(
                  radius: 27,
                  backgroundColor:
                      theme.colorScheme.primary.withOpacity(0.15),
                  backgroundImage: (avatar != null && avatar.isNotEmpty)
                      ? NetworkImage(avatar)
                      : null,
                  onBackgroundImageError: (_, __) {},
                  child: (avatar == null || avatar.isEmpty)
                      ? Icon(
                          isChannel
                              ? Icons.campaign
                              : isGroup
                                  ? Icons.group
                                  : isBot
                                      ? Icons.smart_toy
                                      : Icons.person,
                          color: theme.colorScheme.primary,
                          size: 24,
                        )
                      : null,
                ),
                if (isChannel)
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
                          color: isDark
                              ? const Color(0xFF000000)
                              : Colors.white,
                          width: 2,
                        ),
                      ),
                      child: const Icon(Icons.check,
                          size: 10, color: Colors.white),
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
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      if (isMuted) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.notifications_off,
                            size: 14,
                            color: theme.colorScheme.onSurface
                                .withOpacity(0.4)),
                      ],
                      if (isPinned) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.push_pin,
                            size: 14,
                            color: theme.colorScheme.onSurface
                                .withOpacity(0.4)),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    previewText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: isBlockedByMe
                          ? theme.colorScheme.error
                          : unread > 0
                              ? theme.colorScheme.onSurface
                                  .withOpacity(0.75)
                              : theme.colorScheme.onSurface
                                  .withOpacity(0.55),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _formatChatTime(chat['last_message_at']),
                  style: TextStyle(
                    fontSize: 12,
                    color: unread > 0
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface.withOpacity(0.4),
                    fontWeight:
                        unread > 0 ? FontWeight.w500 : FontWeight.normal,
                  ),
                ),
                if (unread > 0) ...[
                  const SizedBox(height: 4),
                  Container(
                    constraints: const BoxConstraints(minWidth: 22),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Text(
                      unread > 999 ? '999+' : '$unread',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );

    // Wrap in Slidable for swipe actions
    return Slidable(
      key: ValueKey(chatId),
      startActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.5,
        children: [
          SlidableAction(
            onPressed: (_) => _togglePin(chatId, isPinned),
            backgroundColor: const Color(0xFF4FAE4F),
            foregroundColor: Colors.white,
            icon: isPinned ? Icons.push_pin_outlined : Icons.push_pin,
            label: isPinned ? 'Unpin' : 'Pin',
          ),
          SlidableAction(
            onPressed: (_) => _toggleMute(chatId, !isMuted),
            backgroundColor: const Color(0xFFE0954A),
            foregroundColor: Colors.white,
            icon: isMuted
                ? Icons.notifications_active_outlined
                : Icons.notifications_off_outlined,
            label: isMuted ? 'Unmute' : 'Mute',
          ),
        ],
      ),
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.5,
        children: [
          SlidableAction(
            onPressed: (_) => _toggleArchive(chatId, isArchived),
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: Colors.white,
            icon: isArchived
                ? Icons.unarchive_outlined
                : Icons.archive_outlined,
            label: isArchived ? 'Unarchive' : 'Archive',
          ),
          SlidableAction(
            onPressed: (_) =>
                context.read<ChatProvider>().deleteChat(chatId),
            backgroundColor: theme.colorScheme.error,
            foregroundColor: Colors.white,
            icon: Icons.delete_outline,
            label: 'Delete',
          ),
        ],
      ),
      child: tile,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // FIRESTORE ACTIONS
  // ═══════════════════════════════════════════════════════════════════════

  Future<void> _togglePin(String chatId, bool currentlyPinned) async {
    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatId)
          .update({'is_pinned': !currentlyPinned});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(currentlyPinned ? 'Unpinned' : 'Pinned'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        context.read<ChatProvider>().loadChats();
      }
    } catch (_) {}
  }

  Future<void> _toggleArchive(String chatId, bool currentlyArchived) async {
    try {
      final provider = context.read<ChatProvider>();
      if (currentlyArchived) {
        await provider.unarchiveChat(chatId);
      } else {
        await provider.archiveChat(chatId);
      }
    } catch (_) {}
  }

  Future<void> _toggleMute(String chatId, bool mute) async {
    final myUid = _myUid;
    try {
      await FirebaseFirestore.instance.collection('chats').doc(chatId).update({
        'muted_for': mute
            ? FieldValue.arrayUnion([myUid])
            : FieldValue.arrayRemove([myUid]),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(mute ? 'Muted' : 'Unmuted'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        context.read<ChatProvider>().loadChats();
      }
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════════════════════════
  // LONG-PRESS MENU
  // ═══════════════════════════════════════════════════════════════════════

  Future<void> _showChatContextMenu({
    required BuildContext context,
    required Map<String, dynamic> chat,
    required String chatId,
    required bool isDirect,
    required bool isGroup,
    required bool isChannel,
    required String? otherUserId,
    required bool isPinned,
    required bool isMuted,
    required bool isBlockedByMe,
    required bool isArchived,
    required String name,
  }) async {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;

    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(Offset.zero, ancestor: overlay),
        box.localToGlobal(box.size.bottomRight(Offset.zero),
            ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );

    final selected = await showMenu<String>(
      context: context,
      position: position,
      color: isDark ? const Color(0xFF1F2C34) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        PopupMenuItem(
          value: 'pin',
          child: _menuRow(
            icon: isPinned ? Icons.push_pin_outlined : Icons.push_pin,
            label: isPinned ? 'Unpin' : 'Pin',
            theme: theme,
          ),
        ),
        PopupMenuItem(
          value: 'mute',
          child: _menuRow(
            icon: isMuted
                ? Icons.notifications_active_outlined
                : Icons.notifications_off_outlined,
            label: isMuted ? 'Unmute' : 'Mute',
            theme: theme,
          ),
        ),
        PopupMenuItem(
          value: 'read',
          child: _menuRow(
            icon: Icons.mark_chat_read_outlined,
            label: 'Mark as read',
            theme: theme,
          ),
        ),
        if (isDirect)
          PopupMenuItem(
            value: 'block',
            child: _menuRow(
              icon: isBlockedByMe ? Icons.block_flipped : Icons.block,
              label: isBlockedByMe ? 'Unblock' : 'Block user',
              theme: theme,
              danger: !isBlockedByMe,
            ),
          ),
        PopupMenuItem(
          value: 'archive',
          child: _menuRow(
            icon: isArchived
                ? Icons.unarchive_outlined
                : Icons.archive_outlined,
            label: isArchived ? 'Unarchive' : 'Archive',
            theme: theme,
          ),
        ),
        PopupMenuItem(
          value: 'clear',
          child: _menuRow(
            icon: Icons.cleaning_services_outlined,
            label: 'Clear history',
            theme: theme,
          ),
        ),
        if (isGroup || isChannel)
          PopupMenuItem(
            value: 'leave',
            child: _menuRow(
              icon: Icons.exit_to_app,
              label: isChannel ? 'Leave channel' : 'Exit group',
              theme: theme,
              danger: true,
            ),
          ),
        PopupMenuItem(
          value: 'delete',
          child: _menuRow(
            icon: Icons.delete_outline,
            label: 'Delete chat',
            theme: theme,
            danger: true,
          ),
        ),
      ],
    );

    if (!mounted || selected == null) return;

    final provider = context.read<ChatProvider>();

    switch (selected) {
      case 'pin':
        await provider.togglePinChat(chatId);
        break;
      case 'mute':
        await _toggleMute(chatId, !isMuted);
        break;
      case 'read':
        await provider.markMessagesAsRead(chatId);
        break;
      case 'block':
        if (otherUserId != null && otherUserId.isNotEmpty) {
          if (isBlockedByMe) {
            await provider.unblockUser(otherUserId);
          } else {
            await provider.blockUser(otherUserId);
          }
        }
        break;
      case 'archive':
        if (isArchived) {
          await provider.unarchiveChat(chatId);
        } else {
          await provider.archiveChat(chatId);
        }
        break;
      case 'clear':
        await _confirmClearMessages(chatId);
        break;
      case 'leave':
        await _confirmExitGroup(chatId, isChannel);
        break;
      case 'delete':
        await provider.deleteChat(chatId);
        break;
    }
  }

  Widget _menuRow({
    required IconData icon,
    required String label,
    required ThemeData theme,
    bool danger = false,
  }) {
    final color =
        danger ? theme.colorScheme.error : theme.colorScheme.onSurface;
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 14),
        Text(label, style: TextStyle(fontSize: 15, color: color)),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // CONFIRMATIONS
  // ═══════════════════════════════════════════════════════════════════════

  Future<void> _confirmClearMessages(String chatId) async {
    final myUid = _myUid;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text('Messages will be removed for you only.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await FirebaseFirestore.instance.collection('chats').doc(chatId).update({
        'cleared_at.$myUid': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  Future<void> _confirmExitGroup(String chatId, bool isChannel) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isChannel ? 'Leave channel?' : 'Exit group?'),
        content: Text(isChannel
            ? 'You will stop receiving posts.'
            : 'You will no longer be a member.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Leave')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await context.read<ChatProvider>().leaveChat(chatId);
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════════════════════════
  // SHEETS
  // ═══════════════════════════════════════════════════════════════════════

  void _showNewChatOptions(BuildContext context) {
    _showFlatSheet(
      context: context,
      children: [
        _sheetTile(
          icon: Icons.person_add_outlined,
          label: 'New Chat',
          onTap: () {
            Navigator.pop(context);
            Navigator.pushNamed(context, '/global_search');
          },
        ),
        _sheetTile(
          icon: Icons.group_add_outlined,
          label: 'New Group',
          onTap: () {
            Navigator.pop(context);
            Navigator.pushNamed(context, '/create_group');
          },
        ),
        _sheetTile(
          icon: Icons.campaign_outlined,
          label: 'New Channel',
          onTap: () {
            Navigator.pop(context);
            Navigator.pushNamed(context, '/create_channel');
          },
        ),
      ],
    );
  }

  void _showFlatSheet({
    required BuildContext context,
    required List<Widget> children,
  }) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: theme.brightness == Brightness.dark
          ? const Color(0xFF1F2C34)
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
              ...children,
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final theme = Theme.of(context);
    final color =
        danger ? theme.colorScheme.error : theme.colorScheme.onSurface;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color, fontSize: 15)),
      onTap: onTap,
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData active;
  final String label;
  const _NavItem(
      {required this.icon, required this.active, required this.label});
}
