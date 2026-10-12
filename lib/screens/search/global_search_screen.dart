import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../utils/verified_badge.dart';
import '../../services/online_status_service.dart';

class GlobalSearchScreen extends StatefulWidget {
  const GlobalSearchScreen({super.key});

  @override
  State<GlobalSearchScreen> createState() => _GlobalSearchScreenState();
}

class _GlobalSearchScreenState extends State<GlobalSearchScreen> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  bool _isLoading = false;
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _groups = [];
  List<Map<String, dynamic>> _channels = [];
  String? _error;
  List<String> _recentSearches = [];
  final String _recentSearchesKey = 'global_search_recent';
  StreamSubscription? _onlineStatusSubscription;
  Map<String, bool> _onlineStatus = {};
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadRecentSearches();
    _subscribeToOnlineStatus();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _onlineStatusSubscription?.cancel();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════════
  // RECENT SEARCHES
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _loadRecentSearches() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _recentSearches = prefs.getStringList(_recentSearchesKey) ?? [];
    });
  }

  Future<void> _saveRecentSearches() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_recentSearchesKey, _recentSearches);
  }

  Future<void> _addRecentSearch(String query) async {
    if (query.trim().isEmpty) return;
    final trimmed = query.trim();
    setState(() {
      _recentSearches.remove(trimmed);
      _recentSearches.insert(0, trimmed);
      if (_recentSearches.length > 10) {
        _recentSearches = _recentSearches.sublist(0, 10);
      }
    });
    await _saveRecentSearches();
  }

  Future<void> _clearRecentSearches() async {
    setState(() => _recentSearches.clear());
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_recentSearchesKey);
  }

  Future<void> _removeRecentSearch(String query) async {
    setState(() => _recentSearches.remove(query));
    await _saveRecentSearches();
  }

  // ═══════════════════════════════════════════════════════════════════════
  // ONLINE STATUS
  // ═══════════════════════════════════════════════════════════════════════
  void _subscribeToOnlineStatus() {
    _onlineStatusSubscription = FirebaseFirestore.instance
        .collection('users')
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;
      final updated = <String, bool>{};
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final lastSeen = data['last_seen'] as Timestamp?;
        updated[doc.id] = OnlineStatusService.isUserOnline(lastSeen);
      }
      setState(() => _onlineStatus = updated);
    });
  }

  // ═══════════════════════════════════════════════════════════════════════
  // SEARCH
  // ═══════════════════════════════════════════════════════════════════════
  void _onSearchChanged(String value) {
    setState(() {});
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        _users = [];
        _groups = [];
        _channels = [];
        _error = null;
        _isLoading = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _searchUsers(value);
    });
  }

  Future<void> _searchUsers(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;

    HapticFeedback.lightImpact();

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final firestore = FirebaseFirestore.instance;
      final authProvider =
          Provider.of<LumaAuthProvider>(context, listen: false);
      final currentUserId =
          authProvider.user?.uid ?? authProvider.mockUserId;

      final searchTerm = trimmed.toLowerCase();
      final searchEnd = '$searchTerm\uf8ff';

      // ── Users: search by username and display_name (2 queries) ──
      final results = <String, Map<String, dynamic>>{};

      final usernameSnap = await firestore
          .collection('users')
          .where('username', isGreaterThanOrEqualTo: searchTerm)
          .where('username', isLessThanOrEqualTo: searchEnd)
          .limit(20)
          .get();

      for (final doc in usernameSnap.docs) {
        final data = doc.data();
        data['id'] = doc.id;
        results[doc.id] = data;
      }

      final displayNameSnap = await firestore
          .collection('users')
          .where('display_name', isGreaterThanOrEqualTo: searchTerm)
          .where('display_name', isLessThanOrEqualTo: searchEnd)
          .limit(20)
          .get();

      for (final doc in displayNameSnap.docs) {
        final data = doc.data();
        data['id'] = doc.id;
        results[doc.id] = data;
      }

      final filtered = results.values
          .where((u) => u['id'] != currentUserId)
          .toList();

      // ── Groups ──
      final groupsSnap = await firestore
          .collection('chats')
          .where('type', isEqualTo: 'group')
          .where('name', isGreaterThanOrEqualTo: searchTerm)
          .where('name', isLessThanOrEqualTo: searchEnd)
          .limit(10)
          .get();

      final groups = groupsSnap.docs
          .map((doc) => {'id': doc.id, ...doc.data()})
          .toList();

      // ── Channels ──
      final channelsSnap = await firestore
          .collection('chats')
          .where('type', isEqualTo: 'channel')
          .where('name', isGreaterThanOrEqualTo: searchTerm)
          .where('name', isLessThanOrEqualTo: searchEnd)
          .limit(10)
          .get();

      final channels = channelsSnap.docs
          .map((doc) => {'id': doc.id, ...doc.data()})
          .toList();

      if (!mounted) return;
      setState(() {
        _users = filtered;
        _groups = groups;
        _channels = channels;
        _isLoading = false;
      });

      await _addRecentSearch(trimmed);
    } catch (e) {
      debugPrint('Search error: $e');
      if (!mounted) return;
      setState(() {
        _error = 'Search failed. Try again.';
        _isLoading = false;
      });
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // ACTIONS
  // ═══════════════════════════════════════════════════════════════════════
  Future<void> _startChat(Map<String, dynamic> user) async {
    setState(() => _isLoading = true);

    try {
      final firestore = FirebaseFirestore.instance;
      final authProvider =
          Provider.of<LumaAuthProvider>(context, listen: false);
      final currentUserId =
          authProvider.user?.uid ?? authProvider.mockUserId;
      if (currentUserId == null) throw Exception('Not authenticated');

      final targetUserId = user['id'] as String;

      // Check for existing direct chat
      final chatSnap = await firestore
          .collection('chats')
          .where('type', isEqualTo: 'direct')
          .where('participants', arrayContains: currentUserId)
          .get();

      String? existingChatId;
      for (final doc in chatSnap.docs) {
        final participants = doc.data()['participants'] as List<dynamic>;
        if (participants.contains(targetUserId)) {
          existingChatId = doc.id;
          break;
        }
      }

      if (!mounted) return;

      if (existingChatId != null) {
        Navigator.pushNamed(
          context,
          '/chat',
          arguments: {
            'chatId': existingChatId,
            'chatName':
                user['display_name'] ?? user['username'] ?? 'Chat',
            'chatAvatar': user['avatar_url'],
            'isGroup': false,
            'otherUserId': targetUserId,
          },
        );
        return;
      }

      // Create new direct chat
      final chatRef = firestore.collection('chats').doc();
      final chatId = chatRef.id;

      await chatRef.set({
        'id': chatId,
        'name': null,
        'type': 'direct',
        'participants': [currentUserId, targetUserId],
        'participants_data': {
          currentUserId: {
            'role': 'member',
            'joined_at': FieldValue.serverTimestamp()
          },
          targetUserId: {
            'role': 'member',
            'joined_at': FieldValue.serverTimestamp()
          },
        },
        'created_by': currentUserId,
        'created_at': FieldValue.serverTimestamp(),
        'updated_at': FieldValue.serverTimestamp(),
        'last_message_at': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      Navigator.pushNamed(
        context,
        '/chat',
        arguments: {
          'chatId': chatId,
          'chatName':
              user['display_name'] ?? user['username'] ?? 'Chat',
          'chatAvatar': user['avatar_url'],
          'isGroup': false,
          'otherUserId': targetUserId,
        },
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not start chat'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _joinGroup(Map<String, dynamic> group) async {
    final authProvider =
        Provider.of<LumaAuthProvider>(context, listen: false);
    final userId = authProvider.user?.uid ?? authProvider.mockUserId;
    if (userId == null) return;

    try {
      final firestore = FirebaseFirestore.instance;
      final groupId = group['id'];

      await firestore.collection('chats').doc(groupId).update({
        'participants': FieldValue.arrayUnion([userId]),
        'participants_data.$userId': {
          'role': 'member',
          'joined_at': FieldValue.serverTimestamp(),
        },
        'member_count': FieldValue.increment(1),
      });

      await firestore
          .collection('chats')
          .doc(groupId)
          .collection('messages')
          .add({
        'type': 'system',
        'content': 'A new member joined',
        'created_at': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Joined ${group['name'] ?? 'group'}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not join'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _joinChannel(Map<String, dynamic> channel) async {
    final authProvider =
        Provider.of<LumaAuthProvider>(context, listen: false);
    final userId = authProvider.user?.uid ?? authProvider.mockUserId;
    if (userId == null) return;

    try {
      final firestore = FirebaseFirestore.instance;
      final channelId = channel['id'];

      await firestore.collection('chats').doc(channelId).update({
        'participants': FieldValue.arrayUnion([userId]),
        'participants_data.$userId': {
          'role': 'subscriber',
          'joined_at': FieldValue.serverTimestamp(),
        },
        'member_count': FieldValue.increment(1),
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Subscribed to ${channel['name'] ?? 'channel'}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not subscribe'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _viewPublicProfile(Map<String, dynamic> user) {
    Navigator.pushNamed(
      context,
      '/public_profile',
      arguments: {
        'userId': user['id'],
        'username': user['username'],
        'display_name': user['display_name'],
        'avatar_url': user['avatar_url'],
        'avatarUrl': user['avatar_url'],
        'bio': user['bio'],
      },
    );
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _users = [];
      _groups = [];
      _channels = [];
      _error = null;
    });
  }

  bool _isUserOnline(String userId) => _onlineStatus[userId] ?? false;

  // ═══════════════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Discover'),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            // Search bar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocusNode,
                autofocus: true,
                style: TextStyle(
                  color: theme.colorScheme.onSurface,
                  fontSize: 16,
                ),
                onChanged: _onSearchChanged,
                decoration: InputDecoration(
                  hintText: 'Search by username...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: _clearSearch,
                        )
                      : null,
                ),
              ),
            ),

            // Body
            Expanded(child: _buildBody(theme)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    // Loading
    if (_isLoading &&
        _users.isEmpty &&
        _searchController.text.isNotEmpty) {
      return Center(
        child: CircularProgressIndicator(
            color: theme.colorScheme.primary),
      );
    }

    // Error
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline,
                  size: 48,
                  color: theme.colorScheme.error.withOpacity(0.7)),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color:
                      theme.colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
              const SizedBox(height: 20),
              TextButton.icon(
                onPressed: () => _searchUsers(_searchController.text),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    // Empty state (no query)
    if (_searchController.text.isEmpty) {
      return _buildEmptyState(theme);
    }

    // No results
    if (_users.isEmpty && _groups.isEmpty && _channels.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.person_search_outlined,
                  size: 60,
                  color:
                      theme.colorScheme.onSurface.withOpacity(0.2)),
              const SizedBox(height: 16),
              Text(
                'No results found',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Try a different search term',
                style: theme.textTheme.bodySmall?.copyWith(
                  color:
                      theme.colorScheme.onSurface.withOpacity(0.5),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Results
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (_users.isNotEmpty) ...[
          _sectionHeader(theme, 'USERS'),
          ..._users.map((u) => _userTile(theme, u)),
        ],
        if (_groups.isNotEmpty) ...[
          _sectionHeader(theme, 'GROUPS'),
          ..._groups.map((g) => _groupChannelTile(theme, g, isGroup: true)),
        ],
        if (_channels.isNotEmpty) ...[
          _sectionHeader(theme, 'CHANNELS'),
          ..._channels.map(
              (c) => _groupChannelTile(theme, c, isGroup: false)),
        ],
      ],
    );
  }

  Widget _sectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
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

  Widget _userTile(ThemeData theme, Map<String, dynamic> user) {
    final userId = user['id'] as String? ?? '';
    final username = user['username'] as String? ?? 'Unknown';
    final displayName =
        user['display_name'] as String? ?? username;
    final avatarUrl = user['avatar_url'] as String?;
    final bio = user['bio'] as String?;
    final email = user['email'] as String?;
    final isOnline = _isUserOnline(userId);

    return ListTile(
      onTap: () => _viewPublicProfile(user),
      leading: Stack(
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor:
                theme.colorScheme.primary.withOpacity(0.15),
            backgroundImage:
                (avatarUrl != null && avatarUrl.isNotEmpty)
                    ? NetworkImage(avatarUrl)
                    : null,
            child: (avatarUrl == null || avatarUrl.isEmpty)
                ? Text(
                    displayName.isNotEmpty
                        ? displayName[0].toUpperCase()
                        : '?',
                    style: TextStyle(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                      fontSize: 18,
                    ),
                  )
                : null,
          ),
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
        ],
      ),
      title: VerifiedUsername(
        username: displayName,
        email: email,
        style: const TextStyle(
          fontWeight: FontWeight.w500,
          fontSize: 15,
        ),
        badgeSize: 14,
        spacing: 4,
      ),
      subtitle: Text(
        bio != null && bio.isNotEmpty ? bio : '@$username',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: theme.colorScheme.onSurface.withOpacity(0.55),
          fontSize: 13,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.person_outline, size: 20),
            color: theme.colorScheme.onSurface.withOpacity(0.6),
            tooltip: 'View profile',
            onPressed: () => _viewPublicProfile(user),
          ),
          IconButton(
            icon: const Icon(Icons.chat_bubble_outline, size: 20),
            color: theme.colorScheme.primary,
            tooltip: 'Start chat',
            onPressed: () => _startChat(user),
          ),
        ],
      ),
    );
  }

  Widget _groupChannelTile(
    ThemeData theme,
    Map<String, dynamic> item, {
    required bool isGroup,
  }) {
    final name = item['name'] ?? 'Unknown';
    final description = item['description'] ?? '';
    final avatarUrl = item['avatar_url'] as String?;
    final memberCount = item['member_count'] ??
        (item['participants'] as List?)?.length ??
        0;

    return ListTile(
      leading: CircleAvatar(
        radius: 26,
        backgroundColor:
            theme.colorScheme.primary.withOpacity(0.15),
        backgroundImage:
            (avatarUrl != null && avatarUrl.isNotEmpty)
                ? NetworkImage(avatarUrl)
                : null,
        child: (avatarUrl == null || avatarUrl.isEmpty)
            ? Icon(
                isGroup ? Icons.group : Icons.campaign,
                color: theme.colorScheme.primary,
                size: 24,
              )
            : null,
      ),
      title: Row(
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withOpacity(0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              isGroup ? 'GROUP' : 'CHANNEL',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.primary,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              style: const TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 15,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      subtitle: Text(
        description.isNotEmpty
            ? '$memberCount member${memberCount == 1 ? '' : 's'} • $description'
            : '$memberCount member${memberCount == 1 ? '' : 's'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: theme.colorScheme.onSurface.withOpacity(0.55),
          fontSize: 13,
        ),
      ),
      trailing: TextButton(
        onPressed: () =>
            isGroup ? _joinGroup(item) : _joinChannel(item),
        style: TextButton.styleFrom(
          foregroundColor: theme.colorScheme.primary,
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
        child: Text(isGroup ? 'Join' : 'Subscribe'),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        if (_recentSearches.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'RECENT',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface
                        .withOpacity(0.55),
                    letterSpacing: 0.6,
                  ),
                ),
                TextButton(
                  onPressed: _clearRecentSearches,
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.primary,
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: const Text('Clear all'),
                ),
              ],
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _recentSearches.map((search) {
              return GestureDetector(
                onTap: () {
                  _searchController.text = search;
                  _searchUsers(search);
                },
                onLongPress: () => _removeRecentSearch(search),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface
                        .withOpacity(0.05),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.history,
                        size: 14,
                        color: theme.colorScheme.onSurface
                            .withOpacity(0.45),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        search,
                        style: TextStyle(
                          color: theme.colorScheme.onSurface
                              .withOpacity(0.75),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 32),
        ],

        // Hint
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: [
                Icon(
                  Icons.search,
                  size: 60,
                  color: theme.colorScheme.onSurface
                      .withOpacity(0.15),
                ),
                const SizedBox(height: 16),
                Text(
                  'Search for people, groups, and channels',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface
                        .withOpacity(0.5),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
