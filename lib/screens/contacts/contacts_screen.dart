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

      // Search by username (exact)
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

      // Search by phone (contains digits)
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
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          _controller.text.isEmpty
                              ? 'Search by username or phone number'
                              : 'No users found',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color:
                                theme.colorScheme.onSurface.withOpacity(0.5),
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _results.length,
                      itemBuilder: (context, i) {
                        final u = _results[i];
                        final name =
                            u['display_name'] ?? u['username'] ?? 'User';
                        final username = u['username'] ?? '';
                        final avatar = u['avatar_url'] as String?;
                        return ListTile(
                          leading: CircleAvatar(
                            radius: 24,
                            backgroundColor: theme.colorScheme.primary
                                .withOpacity(0.15),
                            backgroundImage: (avatar != null &&
                                    avatar.isNotEmpty)
                                ? NetworkImage(avatar)
                                : null,
                            child: (avatar == null || avatar.isEmpty)
                                ? Text(
                                    name.toString().isNotEmpty
                                        ? name.toString()[0].toUpperCase()
                                        : '?',
                                    style: TextStyle(
                                      color: theme.colorScheme.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  )
                                : null,
                          ),
                          title: Text(name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w500)),
                          subtitle: username.isNotEmpty
                              ? Text('@$username')
                              : null,
                          onTap: () => _startChat(u),
                        );
                      },
                    ),
            ),
        ],
      ),
    );
  }
}
