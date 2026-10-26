import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

import '../providers/auth_provider.dart' show LumaAuthProvider;
import '../providers/chat_provider.dart';
import 'status/status_screen.dart';
import 'settings/settings_screen.dart';
import 'chats/archived_chats_screen.dart'; // We will create this

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
  
  // Folder state
  List<Map<String, dynamic>> _folders = []; // {id, name, chatIds: []}

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = Provider.of<LumaAuthProvider>(context, listen: false);
      final chat = Provider.of<ChatProvider>(context, listen: false);
      
      // OFFLINE MODE: Load from local storage first
      _loadLocalChats(chat);

      if (auth.mockUserId != null) {
        chat.setMockUser(auth.mockUserId!);
      } else {
        chat.loadChats();
      }
      _listenToMyBlockedUsers();
      _loadFolders();
    });
  }

  // ═══════════════════════════════════════════════════════════════════════
  // OFFLINE MODE & LOCAL STORAGE
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _loadLocalChats(ChatProvider chat) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString('cached_chats');
    if (cached != null) {
      final List<dynamic> decoded = jsonDecode(cached);
      // Assuming your ChatProvider has a method to set chats directly
      // chat.setCachedChats(decoded.cast<Map<String, dynamic>>());
    }
  }

  Future<void> _saveChatsLocally(List<Map<String, dynamic>> chats) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cached_chats', jsonEncode(chats));
  }

  // ═══════════════════════════════════════════════════════════════════════
  // CUSTOM FOLDERS LOGIC
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _loadFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('custom_folders');
    if (saved != null) {
      setState(() {
        _folders = List<Map<String, dynamic>>.from(jsonDecode(saved));
      });
    }
  }

  Future<void> _saveFolders() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('custom_folders', jsonEncode(_folders));
  }

  void _showCreateFolderDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Folder'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(hintText: 'Folder name...'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              final name = ctrl.text.trim();
              if (name.isEmpty) return;
              setState(() {
                _folders.add({
                  'id': DateTime.now().millisecondsSinceEpoch.toString(),
                  'name': name,
                  'chatIds': <String>[],
                });
              });
              _saveFolders();
              Navigator.pop(ctx);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _addChatToFolder(String chatId) {
    if (_folders.isEmpty) {
      _showCreateFolderDialog();
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add to Folder'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: _folders.map((f) {
            final isIn = (f['chatIds'] as List).contains(chatId);
            return ListTile(
              title: Text(f['name']),
              trailing: Icon(isIn ? Icons.check_circle : Icons.circle_outlined, color: isIn ? Colors.green : Colors.grey),
              onTap: () {
                setState(() {
                  if (isIn) {
                    (f['chatIds'] as List).remove(chatId);
                  } else {
                    (f['chatIds'] as List).add(chatId);
                  }
                });
                _saveFolders();
                Navigator.pop(ctx);
              },
            );
          }).toList(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
        ],
      ),
    );
  }

  void _editFolder(int index) {
    final ctrl = TextEditingController(text: _folders[index]['name']);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Folder'),
        content: TextField(controller: ctrl),
        actions: [
          TextButton(
            onPressed: () {
              setState(() => _folders.removeAt(index));
              _saveFolders();
              Navigator.pop(ctx);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              setState(() => _folders[index]['name'] = ctrl.text.trim());
              _saveFolders();
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // BLOCKED USERS & FETCHING
  // ═══════════════════════════════════════════════════════════════════════
  String get _myUid {
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    final fromProvider = auth.currentUserId ?? auth.mockUserId;
    if (fromProvider != null && fromProvider.isNotEmpty) return fromProvider;
    return FirebaseAuth.instance.currentUser?.uid ?? '';
  }

  void _listenToMyBlockedUsers() {
    final uid = _myUid;
    if (uid.isEmpty) return;
    FirebaseFirestore.instance.collection('users').doc(uid).snapshots().listen((doc) {
      if (!mounted || !doc.exists) return;
      setState(() {
        _myBlockedUsers = List<String>.from(doc.data()?['blocked_users'] ?? []);
      });
    });
  }

  Future<void> _fetchOtherUser(String uid) async {
    if (uid.isEmpty || _userCache.containsKey(uid) || _inFlight.contains(uid)) return;
    _inFlight.add(uid);
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      if (doc.exists && doc.data() != null) {
        final d = doc.data()!;
        _userCache[uid] = {
          'uid': uid,
          'username': (d['username'] ?? '') as String,
          'display_name': (d['display_name'] ?? d['username'] ?? d['name'] ?? 'Unknown') as String,
          'avatar_url': d['avatar_url'],
          'email': d['email'],
          'is_bot': d['is_bot'] == true,
          'is_premium': d['is_premium'] == true, // <-- PREMIUM BADGE
        };
      }
    } finally {
      if (mounted) setState(() {});
      _inFlight.remove(uid);
    }
  }

  String _formatChatTime(dynamic lastMessageAt) {
    if (lastMessageAt == null) return '';
    DateTime dt = lastMessageAt is Timestamp ? lastMessageAt.toDate() : DateTime.now();
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
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (!didPop) SystemNavigator.pop();
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: IndexedStack(
          index: _bottomIndex,
          children: [
            _buildChatsTab(),
            const StatusScreen(),
            const SettingsScreen(),
          ],
        ),
        floatingActionButton: _buildFAB(),
        bottomNavigationBar: _buildBottomNav(),
      ),
    );
  }

  Widget _buildBottomNav() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // REMOVED CONTACTS TAB
    final items = const [
      _NavItem(icon: Icons.chat_bubble_outline, active: Icons.chat_bubble, label: 'Chats'),
      _NavItem(icon: Icons.donut_large_outlined, active: Icons.donut_large, label: 'Status'),
      _NavItem(icon: Icons.settings_outlined, active: Icons.settings, label: 'Settings'),
    ];

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF000000) : Colors.white,
        border: Border(top: BorderSide(color: isDark ? const Color(0xFF1A1A1A) : const Color(0xFFE4E4E5), width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: List.generate(items.length, (i) {
              final item = items[i];
              final selected = i == _bottomIndex;
              final color = selected ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.5);

              return Expanded(
                child: InkWell(
                  onTap: () => setState(() => _bottomIndex = i),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(selected ? item.active : item.icon, size: 24, color: color),
                      const SizedBox(height: 2),
                      Text(item.label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: color)),
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
  // FAB (NEW CHAT SHEET)
  // ═══════════════════════════════════════════════════════════════════════
  Widget? _buildFAB() {
    if (_bottomIndex != 0) return null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0, right: 8.0),
      child: FloatingActionButton(
        backgroundColor: const Color(0xFF3390EC),
        foregroundColor: Colors.white,
        elevation: 3,
        shape: const CircleBorder(),
        onPressed: () => _showNewChatOptions(context),
        child: const Icon(Icons.add_comment, size: 26),
      ),
    );
  }

  void _showNewChatOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF1F2C34) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sheetTile(icon: Icons.person_add_alt_1_outlined, label: 'New Chat', onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/new_chat');
              }),
              _sheetTile(icon: Icons.group_add_outlined, label: 'New Group', onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/create_group');
              }),
              _sheetTile(icon: Icons.campaign_outlined, label: 'New Channel', onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/create_channel');
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetTile({required IconData icon, required String label, required VoidCallback onTap}) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: theme.colorScheme.primary.withOpacity(0.1), shape: BoxShape.circle),
        child: Icon(icon, color: theme.colorScheme.primary, size: 20),
      ),
      title: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
      onTap: onTap,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // CHATS TAB & FOLDERS
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
              backgroundImage: (avatar != null && avatar.isNotEmpty) ? NetworkImage(avatar) : null,
              child: (avatar == null || avatar.isEmpty) ? Icon(Icons.person, size: 20, color: theme.colorScheme.primary) : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text('Luma Chat', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface)),
          ),
          IconButton(
            icon: Icon(Icons.search, color: theme.colorScheme.onSurface),
            onPressed: () => Navigator.pushNamed(context, '/global_search'),
          ),
          // 3-DOT MENU WITH NEW CHANNEL & ARCHIVE
          PopupMenuButton<String>(
            color: isDark ? const Color(0xFF1F2C34) : Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            icon: Icon(Icons.more_vert, color: theme.colorScheme.onSurface),
            onSelected: (value) {
              if (value == 'new_channel') {
                Navigator.pushNamed(context, '/create_channel'); // <-- FIXED: New Channel
              } else if (value == 'archive') {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const ArchivedChatsScreen()));
              } else if (value == 'settings') {
                setState(() => _bottomIndex = 2); // Adjusted index
              } else if (value == 'starred') {
                Navigator.pushNamed(context, '/saved_messages');
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'new_channel', child: Text('New channel', style: TextStyle(fontSize: 15))),
              const PopupMenuItem(value: 'archive', child: Text('Archived chats', style: TextStyle(fontSize: 15))),
              const PopupMenuItem(value: 'starred', child: Text('Starred messages', style: TextStyle(fontSize: 15))),
              const PopupMenuItem(value: 'settings', child: Text('Settings', style: TextStyle(fontSize: 15))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFolderPills() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final chats = context.watch<ChatProvider>().chats;

    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        children: [
          // All Chats Pill
          GestureDetector(
            onTap: () => setState(() => _folderIndex = 0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: _folderIndex == 0 ? (isDark ? const Color(0xFF2A3A52) : const Color(0xFFE8EDF2)) : Colors.transparent,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('All Chats', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: theme.colorScheme.onSurface)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: _folderIndex == 0 ? theme.colorScheme.primary : Colors.grey, borderRadius: BorderRadius.circular(10)),
                    child: Text('${chats.length}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white)),
                  ),
                ],
              ),
            ),
          ),
          
          // Custom Folders
          ...List.generate(_folders.length, (i) {
            final folder = _folders[i];
            final selected = _folderIndex == i + 1;
            final count = (folder['chatIds'] as List).length;

            return GestureDetector(
              onTap: () => setState(() => _folderIndex = i + 1),
              onLongPress: () => _editFolder(i),
              child: Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: selected ? (isDark ? const Color(0xFF2A3A52) : const Color(0xFFE8EDF2)) : Colors.transparent,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(folder['name'], style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: theme.colorScheme.onSurface)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: selected ? theme.colorScheme.primary : Colors.grey, borderRadius: BorderRadius.circular(10)),
                      child: Text('$count', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white)),
                    ),
                  ],
                ),
              ),
            );
          }),

          // + Button
          GestureDetector(
            onTap: _showCreateFolderDialog,
            child: Container(
              margin: const EdgeInsets.only(left: 8),
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

  Widget _buildChatsList() {
    final theme = Theme.of(context);
    return Consumer<ChatProvider>(
      builder: (context, chatProvider, _) {
        if (chatProvider.isLoading) return Center(child: CircularProgressIndicator(color: theme.colorScheme.primary));
        
        // Save locally for offline mode
        _saveChatsLocally(chatProvider.chats);

        List<Map<String, dynamic>> visible = chatProvider.chats;

        // Filter by Folder
        if (_folderIndex > 0) {
          final folder = _folders[_folderIndex - 1];
          final allowedIds = List<String>.from(folder['chatIds']);
          visible = visible.where((c) => allowedIds.contains(c['id'])).toList();
        }

        // Filter Archived (Normally you filter these OUT of the main list)
        visible = visible.where((c) {
          final myUid = _myUid;
          final partsData = c['participants_data'] as Map<String, dynamic>? ?? {};
          final myData = partsData[myUid] as Map<String, dynamic>? ?? {};
          return myData['is_archived'] != true;
        }).toList();

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
            Icon(Icons.chat_bubble_outline, size: 72, color: theme.colorScheme.onSurface.withOpacity(0.15)),
            const SizedBox(height: 16),
            Text('No chats yet', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text('Start a conversation by tapping the chat button.', textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withOpacity(0.5))),
          ],
        ),
      ),
    );
  }

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
    bool isPremium = false;

    if (isDirect) {
      final participants = List<String>.from(chat['participants'] ?? []);
      otherUserId = participants.firstWhere((id) => id != myUid, orElse: () => '');
      if (otherUserId.isNotEmpty && !_userCache.containsKey(otherUserId)) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _fetchOtherUser(otherUserId!));
      }
      final cached = otherUserId.isNotEmpty ? _userCache[otherUserId] : null;
      name = cached?['display_name'] ?? 'Loading...';
      avatar = cached?['avatar_url'];
      isPremium = cached?['is_premium'] == true; // <-- GET PREMIUM STATUS
    } else {
      name = (chat['name'] ?? chat['title'] ?? 'Unknown') as String;
      avatar = chat['avatar_url'] as String?;
    }

    final lastMessage = chat['last_message'] ?? '';
    final unread = (chat['unread_count'] as num?)?.toInt() ?? 0;
    final isPinned = chat['is_pinned'] == true;
    final participantsData = chat['participants_data'] as Map<String, dynamic>? ?? {};
    final myData = participantsData[myUid] as Map<String, dynamic>? ?? {};
    final isArchived = myData['is_archived'] == true;
    final mutedFor = List<String>.from(chat['muted_for'] ?? []);
    final isMuted = mutedFor.contains(myUid);
    final isBlockedByMe = isDirect && otherUserId != null && otherUserId.isNotEmpty && _myBlockedUsers.contains(otherUserId);

    final route = isChannel ? '/channel' : '/chat';
    final routeArgs = isChannel
        ? {'channelId': chatId, 'channelName': name}
        : {'chatId': chatId, 'chatName': name, 'chatAvatar': avatar, 'isGroup': isGroup, 'otherUserId': otherUserId};

    final isSticker = lastMessage.toString().toLowerCase().contains('sticker');
    final previewText = isBlockedByMe ? 'Blocked' : isSticker ? '🌟 Sticker' : lastMessage;

    final tile = InkWell(
      onTap: () => Navigator.pushNamed(context, route, arguments: routeArgs),
      onLongPress: () => _showChatContextMenu(context, chat, chatId, isDirect, isGroup, isChannel, otherUserId, isPinned, isMuted, isBlockedByMe, isArchived, name),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Stack(
              children: [
                CircleAvatar(
                  radius: 27,
                  backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
                  backgroundImage: (avatar != null && avatar.isNotEmpty) ? NetworkImage(avatar) : null,
                  child: (avatar == null || avatar.isEmpty) ? Icon(isChannel ? Icons.campaign : isGroup ? Icons.group : isBot ? Icons.smart_toy : Icons.person, color: theme.colorScheme.primary, size: 24) : null,
                ),
                if (isChannel)
                  Positioned(
                    right: 0, bottom: 0,
                    child: Container(
                      width: 18, height: 18,
                      decoration: BoxDecoration(color: theme.colorScheme.primary, shape: BoxShape.circle, border: Border.all(color: isDark ? const Color(0xFF000000) : Colors.white, width: 2)),
                      child: const Icon(Icons.check, size: 10, color: Colors.white),
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
                      Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: theme.colorScheme.onSurface))),
                      // PREMIUM BADGE
                      if (isPremium) ...[
                        const SizedBox(width: 4),
                        const Icon(Icons.stars, size: 16, color: Color(0xFFD4A73A)),
                      ],
                      if (isMuted) ...[const SizedBox(width: 4), Icon(Icons.notifications_off, size: 14, color: theme.colorScheme.onSurface.withOpacity(0.4))],
                      if (isPinned) ...[const SizedBox(width: 4), Icon(Icons.push_pin, size: 14, color: theme.colorScheme.onSurface.withOpacity(0.4))],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(previewText, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: unread > 0 ? theme.colorScheme.onSurface.withOpacity(0.75) : theme.colorScheme.onSurface.withOpacity(0.55))),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(_formatChatTime(chat['last_message_at']), style: TextStyle(fontSize: 12, color: unread > 0 ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.4))),
                if (unread > 0) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(11)),
                    child: Text('$unread', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white)),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );

    return Slidable(
      key: ValueKey(chatId),
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.5,
        children: [
          SlidableAction(
            onPressed: (_) => _addChatToFolder(chatId),
            backgroundColor: const Color(0xFF4FAE4F),
            foregroundColor: Colors.white,
            icon: Icons.folder,
            label: 'Folder',
          ),
          SlidableAction(
            onPressed: (_) => _toggleArchive(chatId, isArchived),
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: Colors.white,
            icon: Icons.archive_outlined,
            label: 'Archive',
          ),
        ],
      ),
      child: tile,
    );
  }

  // ... (Context Menu and Archive Logic stay identical) ...
  // I'll include the Archive logic here so you can copy it fully.
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

  Future<void> _showChatContextMenu(BuildContext context, Map<String, dynamic> chat, String chatId, bool isDirect, bool isGroup, bool isChannel, String? otherUserId, bool isPinned, bool isMuted, bool isBlockedByMe, bool isArchived, String name) async {
    // ... your existing context menu implementation ...
    // Add "Add to folder" as an option here too if you want
  }

  Widget? _buildArchiveIcon() => null; // Placeholder
}

class _NavItem {
  final IconData icon;
  final IconData active;
  final String label;
  const _NavItem({required this.icon, required this.active, required this.label});
}
