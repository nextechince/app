import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';

import '../../providers/chat_provider.dart';

class AddContactScreen extends StatefulWidget {
  const AddContactScreen({super.key});

  @override
  State<AddContactScreen> createState() => _AddContactScreenState();
}

class _AddContactScreenState extends State<AddContactScreen> {
  final _controller = TextEditingController();
  bool _searching = false;
  List<Map<String, dynamic>> _results = [];
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim().toLowerCase();
    if (query.isEmpty) {
      setState(() {
        _results = [];
        _error = null;
      });
      return;
    }

    setState(() {
      _searching = true;
      _error = null;
    });

    try {
      final firestore = FirebaseFirestore.instance;
      final results = <Map<String, dynamic>>[];

      // Search by username (exact match)
      final byUsername = await firestore
          .collection('users')
          .where('username', isEqualTo: query)
          .limit(5)
          .get();

      for (final doc in byUsername.docs) {
        final data = doc.data();
        data['uid'] = doc.id;
        results.add(data);
      }

      // Search by phone number
      final digits = query.replaceAll(RegExp(r'\D'), '');
      if (digits.length >= 6) {
        final byPhone = await firestore
            .collection('users')
            .where('phone', isGreaterThanOrEqualTo: '+$digits')
            .where('phone', isLessThan: '+$digits\uf8ff')
            .limit(5)
            .get();

        for (final doc in byPhone.docs) {
          if (!results.any((r) => r['uid'] == doc.id)) {
            final data = doc.data();
            data['uid'] = doc.id;
            results.add(data);
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _results = results;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Search failed: $e';
        _searching = false;
      });
    }
  }

  Future<void> _startChat(Map<String, dynamic> user) async {
    final uid = user['uid'] as String?;
    if (uid == null) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final chat = await context.read<ChatProvider>().startDirectChat(uid);

    if (!mounted) return;
    Navigator.pop(context);

    if (chat != null) {
      Navigator.pushReplacementNamed(
        context,
        '/chat',
        arguments: {
          'chatId': chat['id'],
          'chatName': user['display_name'] ?? user['username'] ?? 'User',
          'chatAvatar': user['avatar_url'],
          'isGroup': false,
          'otherUserId': uid,
        },
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not start chat')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('New Chat'),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _controller,
              autofocus: true,
              onChanged: (_) => _search(),
              decoration: InputDecoration(
                hintText: 'Username or phone number',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: theme.brightness == Brightness.dark
                    ? const Color(0xFF2A2A2A)
                    : const Color(0xFFF1F1F1),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: theme.colorScheme.primary,
                    width: 1.5,
                  ),
                ),
              ),
            ),
          ),

          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
              ),
            ),

          if (_searching)
            const Padding(
              padding: EdgeInsets.all(32),
              child: CircularProgressIndicator(),
            )
          else
            Expanded(
              child: _results.isEmpty
                  ? _emptyState(theme)
                  : ListView.builder(
                      itemCount: _results.length,
                      itemBuilder: (context, i) => _resultTile(theme, _results[i]),
                    ),
            ),
        ],
      ),
    );
  }

  Widget _emptyState(ThemeData theme) {
    final hasQuery = _controller.text.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              hasQuery ? Icons.person_search : Icons.search,
              size: 64,
              color: theme.colorScheme.onSurface.withOpacity(0.15),
            ),
            const SizedBox(height: 16),
            Text(
              hasQuery ? 'No users found' : 'Find people on Luma Chat',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hasQuery
                  ? 'Try a different username or phone number.'
                  : 'Search by @username or phone number.',
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

  Widget _resultTile(ThemeData theme, Map<String, dynamic> u) {
    final name = u['display_name'] ?? u['username'] ?? 'User';
    final username = u['username'] as String? ?? '';
    final avatar = u['avatar_url'] as String?;
    final bio = u['bio'] as String? ?? '';

    return ListTile(
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
        backgroundImage:
            (avatar != null && avatar.isNotEmpty) ? NetworkImage(avatar) : null,
        child: (avatar == null || avatar.isEmpty)
            ? Text(
                name.toString().isNotEmpty
                    ? name.toString()[0].toUpperCase()
                    : '?',
                style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                  fontSize: 18,
                ),
              )
            : null,
      ),
      title: Text(
        name.toString(),
        style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 15),
      ),
      subtitle: Text(
        username.isNotEmpty ? '@$username' : bio,
        style: TextStyle(
          fontSize: 13,
          color: theme.colorScheme.onSurface.withOpacity(0.5),
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Icon(
        Icons.chevron_right,
        color: theme.colorScheme.onSurface.withOpacity(0.4),
      ),
      onTap: () => _startChat(u),
    );
  }
}
