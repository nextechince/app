import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/chat_provider.dart';

class ArchivedChatsScreen extends StatelessWidget {
  const ArchivedChatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chats = context.watch<ChatProvider>().chats;

    // Filter only archived chats
    final archived = chats.where((c) {
      final myUid = ''; // You need to fetch your UID here
      final parts = c['participants_data'] as Map<String, dynamic>? ?? {};
      return parts[myUid]?['is_archived'] == true;
    }).toList();

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(title: const Text('Archived Chats'), backgroundColor: theme.scaffoldBackgroundColor),
      body: archived.isEmpty
          ? const Center(child: Text('No archived chats.'))
          : ListView.builder(
              itemCount: archived.length,
              itemBuilder: (context, i) {
                final chat = archived[i];
                return ListTile(
                  title: Text(chat['name'] ?? 'Chat'),
                  subtitle: Text(chat['last_message'] ?? ''),
                  onTap: () {
                    // Open chat
                  },
                );
              },
            ),
    );
  }
}
