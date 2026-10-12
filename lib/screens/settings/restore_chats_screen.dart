import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../providers/auth_provider.dart' show LumaAuthProvider;

class RestoreChatsScreen extends StatefulWidget {
  const RestoreChatsScreen({super.key});

  @override
  State<RestoreChatsScreen> createState() => _RestoreChatsScreenState();
}

class _RestoreChatsScreenState extends State<RestoreChatsScreen> {
  bool _isRestoring = false;
  String _statusMessage = '';
  double _progress = 0;
  int _totalChats = 0;
  int _restoredChats = 0;
  int _restoredMessages = 0;

  Future<void> _pickBackupFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return;

      final filePath = result.files.single.path;
      if (filePath == null) return;

      final file = File(filePath);
      if (!await file.exists()) {
        _showError('Backup file not found');
        return;
      }

      final jsonString = await file.readAsString();
      final backupData = jsonDecode(jsonString) as Map<String, dynamic>;

      if (!backupData.containsKey('chats') ||
          !backupData.containsKey('user_id')) {
        _showError('Invalid backup file format');
        return;
      }

      final authProvider =
          Provider.of<LumaAuthProvider>(context, listen: false);
      final currentUserId =
          authProvider.user?.uid ?? authProvider.mockUserId;

      if (currentUserId == null) {
        _showError('Not authenticated');
        return;
      }

      final backupUserId = backupData['user_id'] as String?;
      if (backupUserId != null && backupUserId != currentUserId) {
        final proceed = await _showDifferentAccountDialog();
        if (proceed != true) return;
      }

      final chats = backupData['chats'] as List<dynamic>;
      if (chats.isEmpty) {
        _showError('No chats found in backup');
        return;
      }

      setState(() {
        _isRestoring = true;
        _statusMessage = 'Preparing restore...';
        _totalChats = chats.length;
        _restoredChats = 0;
        _restoredMessages = 0;
        _progress = 0;
      });

      await _restoreChats(chats, currentUserId);
    } catch (e) {
      _showError('Failed to read backup: $e');
    }
  }

  Future<void> _restoreChats(List<dynamic> chats, String userId) async {
    final firestore = FirebaseFirestore.instance;

    try {
      for (int i = 0; i < chats.length; i++) {
        final chat = chats[i] as Map<String, dynamic>;
        final chatId = chat['chat_id'] as String? ??
            'restored_${DateTime.now().millisecondsSinceEpoch}_$i';
        final participants =
            (chat['participants'] as List<dynamic>?)?.cast<String>() ??
                [userId];

        if (!participants.contains(userId)) {
          participants.add(userId);
        }

        final chatRef = firestore.collection('chats').doc(chatId);
        await chatRef.set({
          'participants': participants,
          'restored_at': FieldValue.serverTimestamp(),
          'is_restored': true,
          'created_at': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        final messages = chat['messages'] as List<dynamic>? ?? [];
        var batch = firestore.batch();
        int batchCount = 0;
        const maxBatchSize = 400;

        for (final msg in messages) {
          final msgData = msg as Map<String, dynamic>;
          final msgRef = chatRef.collection('messages').doc();

          // FIX: Backup writes 'timestamp' but new code writes 'created_at'.
          // Handle both so restored messages land on the right date.
          final rawTs = msgData['created_at'] ?? msgData['timestamp'];
          final timestamp = rawTs != null
              ? Timestamp.fromDate(
                  rawTs is Timestamp
                      ? rawTs.toDate()
                      : DateTime.parse(rawTs.toString()),
                )
              : Timestamp.now();

          batch.set(msgRef, {
            'sender_id': msgData['sender_id'] ?? userId,
            'text': msgData['text'] ?? '',
            'content': msgData['text'] ?? '',
            'type': msgData['type'] ?? 'text',
            'media_url': msgData['media_url'],
            'created_at': timestamp,
            'restored': true,
            'is_read': true,
            'deleted_for_everyone': false,
            'deleted_for': [],
            'reactions': {},
          });
          batchCount++;

          if (batchCount >= maxBatchSize) {
            await batch.commit();
            batch = firestore.batch();
            batchCount = 0;
          }

          _restoredMessages++;
        }

        if (batchCount > 0) {
          await batch.commit();
        }

        _restoredChats++;

        if (mounted) {
          setState(() {
            _progress = _restoredChats / _totalChats;
            _statusMessage =
                'Restoring chat $_restoredChats of $_totalChats...';
          });
        }
      }

      if (!mounted) return;
      setState(() {
        _isRestoring = false;
        _statusMessage = 'Restore complete!';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Restored $_restoredChats chats with $_restoredMessages messages'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isRestoring = false;
        _statusMessage = 'Restore failed';
      });
      _showError('Restore failed: $e');
    }
  }

  Future<bool?> _showDifferentAccountDialog() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Different Account'),
        content: const Text(
            'This backup belongs to a different account. Restore anyway?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFE0954A),
            ),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Restore Chats'),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // ── Info card ──
          Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.06),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: theme.colorScheme.primary.withOpacity(0.2),
                ),
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withOpacity(0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.restore_page_outlined,
                      size: 32,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Restore from Backup',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Select a JSON backup file to restore your chat history. '
                    'The file should be one you previously exported from Luma Chat.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color:
                          theme.colorScheme.onSurface.withOpacity(0.6),
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── How it works ──
          _sectionTitle(theme, 'HOW IT WORKS'),
          _stepTile(
            theme,
            number: '1',
            title: 'Select Backup File',
            description:
                'Choose the .json file from your device storage or email downloads.',
          ),
          _stepTile(
            theme,
            number: '2',
            title: 'Verify & Restore',
            description:
                'We\'ll validate the backup and restore all chats and messages.',
          ),
          _stepTile(
            theme,
            number: '3',
            title: 'Done',
            description:
                'Your restored chats will appear in your chat list.',
          ),

          const SizedBox(height: 24),

          // ── Action or progress ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _isRestoring
                ? _buildProgressCard(theme)
                : _actionCard(theme),
          ),

          const SizedBox(height: 24),

          // ── Warning ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFE0954A).withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: const Color(0xFFE0954A).withOpacity(0.25),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    color: Color(0xFFE0954A),
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Important',
                          style: TextStyle(
                            color: Color(0xFFE0954A),
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Restoring will merge backup chats with your existing chats. '
                          'Messages with the same content may appear duplicated. '
                          'Media files (photos, videos) are not included in the backup.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface
                                .withOpacity(0.6),
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _actionCard(ThemeData theme) {
    return GestureDetector(
      onTap: _pickBackupFile,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: theme.colorScheme.primary.withOpacity(0.25),
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.folder_open_outlined,
                color: theme.colorScheme.primary,
                size: 24,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Select Backup File',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Browse for .json backup file',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color:
                          theme.colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: theme.colorScheme.onSurface.withOpacity(0.4),
              size: 22,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressCard(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withOpacity(0.04),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor:
                  AlwaysStoppedAnimation(theme.colorScheme.primary),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            _statusMessage,
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            '$_restoredChats / $_totalChats chats • $_restoredMessages messages',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withOpacity(0.5),
            ),
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: _progress,
              backgroundColor:
                  theme.colorScheme.onSurface.withOpacity(0.08),
              valueColor:
                  AlwaysStoppedAnimation(theme.colorScheme.primary),
              minHeight: 6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String title) {
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

  Widget _stepTile(
    ThemeData theme, {
    required String number,
    required String title,
    required String description,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                number,
                style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.6),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
