import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../providers/auth_provider.dart' show LumaAuthProvider;

class SavedMessagesScreen extends StatefulWidget {
  const SavedMessagesScreen({super.key});

  @override
  State<SavedMessagesScreen> createState() => _SavedMessagesScreenState();
}

class _SavedMessagesScreenState extends State<SavedMessagesScreen> {
  final _searchController = TextEditingController();
  final _noteController = TextEditingController();

  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _filtered = [];
  String _filter = 'all';
  String _query = '';
  bool _loading = true;
  String? _userId;

  final List<Map<String, dynamic>> _filters = const [
    {'key': 'all', 'label': 'All', 'icon': Icons.layers_outlined},
    {'key': 'note', 'label': 'Notes', 'icon': Icons.edit_note},
    {'key': 'text', 'label': 'Text', 'icon': Icons.short_text},
    {'key': 'image', 'label': 'Photos', 'icon': Icons.image_outlined},
    {'key': 'video', 'label': 'Videos', 'icon': Icons.videocam_outlined},
    {
      'key': 'file',
      'label': 'Files',
      'icon': Icons.insert_drive_file_outlined
    },
    {'key': 'audio', 'label': 'Voice', 'icon': Icons.mic_none},
    {
      'key': 'location',
      'label': 'Locations',
      'icon': Icons.location_on_outlined
    },
    {
      'key': 'contact',
      'label': 'Contacts',
      'icon': Icons.contact_page_outlined
    },
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _searchController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _init() {
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    _userId = auth.user?.uid ?? auth.mockUserId;
    if (_userId == null) {
      setState(() => _loading = false);
      return;
    }
    FirebaseFirestore.instance
        .collection('users')
        .doc(_userId)
        .collection('saved')
        .orderBy('saved_at', descending: true)
        .limit(500)
        .snapshots()
        .listen((snap) {
      _items = snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
      _applyFilters();
      if (mounted) setState(() => _loading = false);
    }, onError: (e) {
      debugPrint('Saved messages load error: $e');
      if (mounted) setState(() => _loading = false);
    });
  }

  void _applyFilters() {
    _filtered = _items.where((item) {
      final type = (item['media_type'] ?? 'text') as String;
      if (_filter != 'all' && type != _filter) return false;
      if (_query.isNotEmpty) {
        final haystack = [
          item['text'] ?? '',
          item['from_sender'] ?? '',
          item['from_chat'] ?? '',
          item['file_name'] ?? '',
        ].join(' ').toLowerCase();
        if (!haystack.contains(_query.toLowerCase())) return false;
      }
      return true;
    }).toList();
    if (mounted) setState(() {});
  }

  String _formatTime(dynamic ts) {
    if (ts == null) return '';
    final d = ts is Timestamp ? ts.toDate() : DateTime.now();
    return DateFormat('HH:mm').format(d);
  }

  String _formatDate(dynamic ts) {
    if (ts == null) return '';
    final d = ts is Timestamp ? ts.toDate() : DateTime.now();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yest = today.subtract(const Duration(days: 1));
    final md = DateTime(d.year, d.month, d.day);
    if (md == today) return 'Today';
    if (md == yest) return 'Yesterday';
    return DateFormat('MMM d, yyyy').format(d);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _openNewNote() async {
    _noteController.clear();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) =>
          _noteDialog(title: 'New Note', controller: _noteController),
    );
    if (saved == true &&
        _noteController.text.trim().isNotEmpty &&
        _userId != null) {
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(_userId)
            .collection('saved')
            .add({
          'text': _noteController.text.trim(),
          'media_type': 'note',
          'saved_at': FieldValue.serverTimestamp(),
        });
        _toast('Note saved');
      } catch (e) {
        _toast('Failed: $e');
      }
    }
  }

  Future<void> _openEditNote(Map<String, dynamic> item) async {
    _noteController.text = item['text'] ?? '';
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) =>
          _noteDialog(title: 'Edit Note', controller: _noteController),
    );
    if (saved == true &&
        _noteController.text.trim().isNotEmpty &&
        _userId != null) {
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(_userId)
            .collection('saved')
            .doc(item['id'])
            .update({
          'text': _noteController.text.trim(),
          'updated_at': FieldValue.serverTimestamp(),
        });
        _toast('Note updated');
      } catch (e) {
        _toast('Failed: $e');
      }
    }
  }

  Widget _noteDialog({
    required String title,
    required TextEditingController controller,
  }) {
    return AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        maxLines: 5,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'Type your note, thought, or link...',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Save'),
        ),
      ],
    );
  }

  void _copyItem(Map<String, dynamic> item) {
    final type = item['media_type'] ?? 'text';
    String text;
    if (type == 'location') {
      text =
          'https://www.google.com/maps/search/?api=1&query=${item['location_lat']},${item['location_lng']}';
    } else {
      text = (item['text'] ?? '') as String;
    }
    if (text.isEmpty) {
      _toast('Nothing to copy');
      return;
    }
    Clipboard.setData(ClipboardData(text: text));
    _toast('Copied');
  }

  Future<void> _deleteItem(Map<String, dynamic> item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete saved item?'),
        content: const Text('This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm == true && _userId != null) {
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(_userId)
            .collection('saved')
            .doc(item['id'])
            .delete();
        _toast('Deleted');
      } catch (e) {
        _toast('Failed: $e');
      }
    }
  }

  Future<void> _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all saved?'),
        content:
            const Text('All saved messages will be permanently deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );
    if (confirm == true && _userId != null) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('users')
            .doc(_userId)
            .collection('saved')
            .get();
        final batch = FirebaseFirestore.instance.batch();
        for (final d in snap.docs) {
          batch.delete(d.reference);
        }
        await batch.commit();
        _toast('All cleared');
      } catch (e) {
        _toast('Failed: $e');
      }
    }
  }

  Future<void> _openForward(Map<String, dynamic> item) async {
    if (_userId == null) return;
    final theme = Theme.of(context);
    final chatsSnap = await FirebaseFirestore.instance
        .collection('chats')
        .where('participants', arrayContains: _userId)
        .get();
    if (!mounted) return;

    final targetChatId = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: theme.brightness == Brightness.dark
          ? const Color(0xFF1F1F1F)
          : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              decoration: BoxDecoration(
                color: theme.dividerColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Forward to',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            Flexible(
              child: chatsSnap.docs.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        'No chats found',
                        style: TextStyle(
                          color: theme.colorScheme.onSurface
                              .withOpacity(0.4),
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: chatsSnap.docs.length,
                      itemBuilder: (context, i) {
                        final doc = chatsSnap.docs[i];
                        final data = doc.data();
                        final isGroup = data['type'] == 'group';
                        final isChannel = data['type'] == 'channel';
                        String name =
                            (data['name'] ?? data['title'] ?? 'Chat')
                                as String;
                        if (!isGroup && !isChannel) {
                          final participants = List<String>.from(
                              data['participants'] ?? []);
                          final otherId = participants.firstWhere(
                              (id) => id != _userId,
                              orElse: () => '');
                          final pData =
                              data['participants_data']?[otherId];
                          if (pData != null) {
                            name = pData['username'] ??
                                pData['name'] ??
                                name;
                          }
                        }
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: theme.colorScheme.primary
                                .withOpacity(0.15),
                            child: Icon(
                              isGroup
                                  ? Icons.group
                                  : isChannel
                                      ? Icons.campaign
                                      : Icons.person,
                              color: theme.colorScheme.primary,
                              size: 20,
                            ),
                          ),
                          title: Text(name),
                          onTap: () => Navigator.pop(ctx, doc.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
    if (targetChatId != null) {
      await _forwardTo(item, targetChatId);
    }
  }

  Future<void> _forwardTo(
      Map<String, dynamic> item, String targetChatId) async {
    try {
      final ref = FirebaseFirestore.instance
          .collection('chats')
          .doc(targetChatId)
          .collection('messages')
          .doc();
      final type = item['media_type'] ?? 'text';
      await ref.set({
        'id': ref.id,
        'sender_id': _userId,
        'type': type == 'note' ? 'text' : type,
        'content': item['text'],
        'media_url': item['media_url'],
        'file_name': item['file_name'],
        'file_size': item['file_size'],
        'location_lat': item['location_lat'],
        'location_lng': item['location_lng'],
        'location_label': item['location_label'],
        'contact': item['contact'],
        'poll': item['poll'],
        'forwarded_from': item['from_sender'] ?? 'Saved Messages',
        'created_at': FieldValue.serverTimestamp(),
        'is_read': false,
        'is_edited': false,
        'deleted_for_everyone': false,
        'deleted_for': [],
        'reactions': {},
      });
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(targetChatId)
          .update({
        'last_message': '📤 Forwarded from Saved',
        'last_message_at': FieldValue.serverTimestamp(),
      });
      _toast('Forwarded');
    } catch (e) {
      _toast('Forward failed: $e');
    }
  }

  Future<void> _openLocation(double lat, double lng) async {
    final uri = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    try {
      final launched =
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) _toast('Could not open map');
    } catch (e) {
      _toast('Could not open map');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
        titleSpacing: 0,
        title: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.primary.withOpacity(0.15),
              ),
              child: Icon(Icons.bookmark,
                  color: theme.colorScheme.primary, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Saved Messages',
                    style:
                        TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                  Text(
                    '${_items.length} item${_items.length != 1 ? 's' : ''}',
                    style: TextStyle(
                      color: theme.colorScheme.onSurface.withOpacity(0.4),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.add, color: theme.colorScheme.primary),
            onPressed: _openNewNote,
          ),
          IconButton(
            icon: Icon(Icons.more_vert,
                color: theme.colorScheme.onSurface.withOpacity(0.7)),
            onPressed: () {
              showModalBottomSheet(
                context: context,
                backgroundColor: theme.brightness == Brightness.dark
                    ? const Color(0xFF1F1F1F)
                    : Colors.white,
                shape: const RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.vertical(top: Radius.circular(16)),
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
                        ListTile(
                          leading: const Icon(Icons.edit_note,
                              color: Color(0xFFD4A73A)),
                          title: const Text('New Note'),
                          onTap: () {
                            Navigator.pop(ctx);
                            _openNewNote();
                          },
                        ),
                        ListTile(
                          leading: Icon(Icons.delete_forever,
                              color: theme.colorScheme.error),
                          title: Text(
                            'Clear All Saved',
                            style: TextStyle(
                                color: theme.colorScheme.error),
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            _clearAll();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: TextField(
              controller: _searchController,
              style: TextStyle(
                  color: theme.colorScheme.onSurface, fontSize: 13),
              onChanged: (v) {
                _query = v;
                _applyFilters();
              },
              decoration: InputDecoration(
                hintText: 'Search saved messages...',
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () {
                          _searchController.clear();
                          _query = '';
                          _applyFilters();
                        },
                      )
                    : null,
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
          SizedBox(
            height: 40,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _filters.length,
              itemBuilder: (context, i) {
                final f = _filters[i];
                final selected = _filter == f['key'];
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _filter = f['key']);
                      _applyFilters();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: selected
                            ? theme.colorScheme.primary.withOpacity(0.15)
                            : theme.colorScheme.onSurface
                                .withOpacity(0.05),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: selected
                              ? theme.colorScheme.primary
                                  .withOpacity(0.4)
                              : Colors.transparent,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            f['icon'],
                            size: 14,
                            color: selected
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface
                                    .withOpacity(0.55),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            f['label'],
                            style: TextStyle(
                              fontSize: 12,
                              color: selected
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurface
                                      .withOpacity(0.55),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? Center(
                    child: CircularProgressIndicator(
                        color: theme.colorScheme.primary))
                : _items.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(30),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.bookmark_border,
                                size: 54,
                                color: theme.colorScheme.primary
                                    .withOpacity(0.3),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'No saved messages yet',
                                style: TextStyle(
                                  color: theme.colorScheme.onSurface
                                      .withOpacity(0.6),
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Long-press any message in a chat and tap Save, or tap + above to create a note.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: theme.colorScheme.onSurface
                                      .withOpacity(0.4),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : _filtered.isEmpty
                        ? Center(
                            child: Text(
                              'No matches',
                              style: TextStyle(
                                color: theme.colorScheme.onSurface
                                    .withOpacity(0.4),
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(
                                12, 0, 12, 20),
                            itemCount: _filtered.length,
                            itemBuilder: (context, index) {
                              final item = _filtered[index];
                              final showDate = index == 0 ||
                                  _formatDate(item['saved_at']) !=
                                      _formatDate(
                                          _filtered[index - 1]['saved_at']);
                              return Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.stretch,
                                children: [
                                  if (showDate)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 10),
                                      child: Center(
                                        child: Text(
                                          _formatDate(item['saved_at']),
                                          style: TextStyle(
                                            color: theme
                                                .colorScheme.onSurface
                                                .withOpacity(0.35),
                                            fontSize: 11,
                                          ),
                                        ),
                                      ),
                                    ),
                                  _buildSavedItem(theme, item),
                                  const SizedBox(height: 6),
                                ],
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }

  Widget _buildSavedItem(ThemeData theme, Map<String, dynamic> item) {
    final type = (item['media_type'] ?? 'text') as String;
    final isNote = type == 'note';

    Widget content;
    switch (type) {
      case 'note':
      case 'text':
        content = Text(
          item['text'] ?? '',
          style: const TextStyle(fontSize: 13, height: 1.4),
        );
        break;
      case 'image':
        content = ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: CachedNetworkImage(
            imageUrl: item['media_url'] ?? '',
            height: 160,
            fit: BoxFit.cover,
            width: double.infinity,
            errorWidget: (_, __, ___) => Container(
              height: 160,
              color: theme.colorScheme.onSurface.withOpacity(0.05),
              child: const Icon(Icons.broken_image, size: 32),
            ),
          ),
        );
        break;
      case 'video':
        content = Container(
          height: 140,
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Center(
            child: Icon(Icons.play_circle_fill,
                color: Colors.white70, size: 40),
          ),
        );
        break;
      case 'file':
        content = Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.insert_drive_file,
                color: theme.colorScheme.primary, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              item['file_name'] ?? 'File',
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]);
        break;
      case 'audio':
        content = Row(children: [
          Icon(Icons.mic,
              color: theme.colorScheme.primary, size: 18),
          const SizedBox(width: 10),
          const Text('Voice message', style: TextStyle(fontSize: 12)),
        ]);
        break;
      case 'location':
        content = GestureDetector(
          onTap: () => _openLocation(
            (item['location_lat'] ?? 0).toDouble(),
            (item['location_lng'] ?? 0).toDouble(),
          ),
          child: Row(children: [
            Icon(Icons.location_on,
                color: theme.colorScheme.primary, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                item['location_label'] ?? 'Shared location',
                style: const TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
        );
        break;
      case 'contact':
        final c = Map<String, dynamic>.from(item['contact'] ?? {});
        content = Row(children: [
          CircleAvatar(
            radius: 16,
            backgroundColor:
                theme.colorScheme.primary.withOpacity(0.2),
            backgroundImage: c['avatar_url'] != null
                ? NetworkImage(c['avatar_url'])
                : null,
            child: c['avatar_url'] == null
                ? Text(
                    (c['display_name'] ?? 'U')[0].toString().toUpperCase(),
                    style: TextStyle(
                      color: theme.colorScheme.primary,
                      fontSize: 12,
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              c['display_name'] ?? c['username'] ?? 'Contact',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ]);
        break;
      default:
        content = Text(
          item['text'] ?? '',
          style: const TextStyle(fontSize: 13),
        );
    }

    return Container(
      decoration: BoxDecoration(
        color: isNote
            ? const Color(0xFFD4A73A).withOpacity(0.05)
            : theme.colorScheme.onSurface.withOpacity(0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.onSurface.withOpacity(0.06),
        ),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: (isNote
                          ? const Color(0xFFD4A73A)
                          : theme.colorScheme.primary)
                      .withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isNote ? Icons.edit : Icons.bookmark,
                  size: 10,
                  color: isNote
                      ? const Color(0xFFD4A73A)
                      : theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 8),
              if (isNote)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD4A73A).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'NOTE',
                    style: TextStyle(
                      color: Color(0xFFD4A73A),
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                )
              else ...[
                if (item['from_sender'] != null)
                  Flexible(
                    child: Text(
                      item['from_sender'],
                      style: TextStyle(
                        color: theme.colorScheme.onSurface
                            .withOpacity(0.7),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (item['from_chat'] != null) ...[
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      '· ${item['from_chat']}',
                      style: TextStyle(
                        color: theme.colorScheme.onSurface
                            .withOpacity(0.4),
                        fontSize: 10,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
              const Spacer(),
              Text(
                _formatTime(item['saved_at']),
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withOpacity(0.4),
                  fontSize: 10,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          content,
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: theme.colorScheme.onSurface.withOpacity(0.06),
                ),
              ),
            ),
            child: Row(
              children: [
                if (isNote)
                  _actionBtn(theme, Icons.edit, 'Edit',
                      () => _openEditNote(item)),
                _actionBtn(theme, Icons.copy, 'Copy',
                    () => _copyItem(item)),
                _actionBtn(theme, Icons.share, 'Forward',
                    () => _openForward(item)),
                _actionBtn(theme, Icons.delete, 'Delete',
                    () => _deleteItem(item),
                    color: theme.colorScheme.error),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionBtn(
    ThemeData theme,
    IconData icon,
    String label,
    VoidCallback onTap, {
    Color? color,
  }) {
    final c = color ?? theme.colorScheme.primary;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: c),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
