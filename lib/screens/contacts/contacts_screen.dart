import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../providers/chat_provider.dart';
import 'add_contact_screen.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  bool _loading = true;
  bool _permissionDenied = false;

  // Phone contacts (from device)
  List<Contact> _deviceContacts = [];

  // Matched: phone contacts that ARE on Luma Chat
  final List<Map<String, dynamic>> _onLuma = [];

  // Not matched: phone contacts NOT on Luma Chat yet
  final List<Map<String, dynamic>> _toInvite = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadContacts());
  }

  String get _myUid {
    final auth = Provider.of<LumaAuthProvider>(context, listen: false);
    return auth.currentUserId ?? auth.mockUserId ?? '';
  }

  // ─── Load phone contacts + match against Firestore ───

  Future<void> _loadContacts() async {
    setState(() {
      _loading = true;
      _permissionDenied = false;
    });

    try {
      // 1. Request permission
      final status = await Permission.contacts.request();
      if (!status.isGranted) {
        if (!mounted) return;
        setState(() {
          _permissionDenied = true;
          _loading = false;
        });
        return;
      }

      // 2. Read phone contacts
      final contacts = await FlutterContacts.getContacts(
        withProperties: true,
        withPhoto: false,
      );

      // 3. Normalize numbers → E.164-ish
      final normalized = <String, Contact>{};
      for (final c in contacts) {
        for (final phone in c.phones) {
          final digits = phone.number.replaceAll(RegExp(r'\D'), '');
          if (digits.length < 6) continue;
          final withPlus = '+$digits';
          normalized[withPlus] = c;
        }
      }

      if (normalized.isEmpty) {
        if (!mounted) return;
        setState(() {
          _deviceContacts = contacts;
          _loading = false;
        });
        return;
      }

      // 4. Query Firestore for matching users (batch by 30 — Firestore IN limit)
      final keys = normalized.keys.toList();
      final matchedUsers = <String, Map<String, dynamic>>{};

      for (var i = 0; i < keys.length; i += 30) {
        final end = (i + 30 > keys.length) ? keys.length : i + 30;
        final chunk = keys.sublist(i, end);

        final snap = await FirebaseFirestore.instance
            .collection('users')
            .where('phone', whereIn: chunk)
            .get();

        for (final doc in snap.docs) {
          final data = doc.data();
          data['uid'] = doc.id;
          final phone = data['phone'] as String?;
          if (phone != null) {
            matchedUsers[phone] = data;
          }
        }
      }

      // 5. Split into onLuma vs toInvite
      final onLuma = <Map<String, dynamic>>[];
      final toInvite = <Map<String, dynamic>>[];

      final myUid = _myUid;

      for (final entry in normalized.entries) {
        final phone = entry.key;
        final contact = entry.value;
        final displayName = contact.displayName.isNotEmpty
            ? contact.displayName
            : phone;

        final match = matchedUsers[phone];

        if (match != null) {
          // Skip self
          if (match['uid'] == myUid) continue;
          onLuma.add({
            'uid': match['uid'],
            'phone': phone,
            'display_name':
                match['display_name'] ?? match['username'] ?? displayName,
            'username': match['username'] ?? '',
            'avatar_url': match['avatar_url'],
            'contact_name': displayName,
          });
        } else {
          toInvite.add({
            'phone': phone,
            'display_name': displayName,
          });
        }
      }

      onLuma.sort((a, b) =>
          (a['display_name'] as String).toLowerCase().compareTo(
              (b['display_name'] as String).toLowerCase()));
      toInvite.sort((a, b) =>
          (a['display_name'] as String).toLowerCase().compareTo(
              (b['display_name'] as String).toLowerCase()));

      if (!mounted) return;
      setState(() {
        _deviceContacts = contacts;
        _onLuma
          ..clear()
          ..addAll(onLuma);
        _toInvite
          ..clear()
          ..addAll(toInvite);
        _loading = false;
      });
    } catch (e) {
      debugPrint('Load contacts error: $e');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  // ─── Actions ───

  Future<void> _startChat(Map<String, dynamic> contact) async {
    final chatProvider = context.read<ChatProvider>();
    final uid = contact['uid'] as String?;
    if (uid == null) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final chat = await chatProvider.startDirectChat(uid);

    if (!mounted) return;
    Navigator.pop(context); // close loading

    if (chat != null) {
      Navigator.pushNamed(
        context,
        '/chat',
        arguments: {
          'chatId': chat['id'],
          'chatName': contact['display_name'],
          'chatAvatar': contact['avatar_url'],
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

  Future<void> _inviteContact(String phone) async {
    // Simple: show a snackbar. Replace with SMS intent later.
    await Clipboard.setData(ClipboardData(text: phone));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Phone copied: $phone')),
    );
  }

  // ─── BUILD ───

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // App bar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Contacts',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.search),
                    onPressed: () =>
                        Navigator.pushNamed(context, '/global_search'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: _loading ? null : _loadContacts,
                  ),
                ],
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
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(color: theme.colorScheme.primary),
      );
    }

    if (_permissionDenied) {
      return _permissionGate(theme);
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        // ── Top actions ──
        _actionTile(
          theme,
          icon: Icons.group_add_outlined,
          iconColor: theme.colorScheme.primary,
          label: 'New Group',
          onTap: () => Navigator.pushNamed(context, '/create_group'),
        ),
        _actionTile(
          theme,
          icon: Icons.campaign_outlined,
          iconColor: theme.colorScheme.primary,
          label: 'New Channel',
          onTap: () => Navigator.pushNamed(context, '/create_channel'),
        ),
        _actionTile(
          theme,
          icon: Icons.person_add_outlined,
          iconColor: theme.colorScheme.primary,
          label: 'New Chat',
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const AddContactScreen(),
              ),
            );
          },
        ),

        const SizedBox(height: 8),
        Divider(height: 0.5, color: theme.dividerColor),

        // ── On Luma Chat ──
        if (_onLuma.isNotEmpty) ...[
          _sectionHeader(theme, 'ON LUMA CHAT', _onLuma.length),
          ..._onLuma.map((c) => _contactTile(theme, c)),
        ],

        // ── Invite ──
        if (_toInvite.isNotEmpty) ...[
          _sectionHeader(theme, 'INVITE', _toInvite.length),
          ..._toInvite.map((c) => _inviteTile(theme, c)),
        ],

        // ── Empty state ──
        if (_onLuma.isEmpty && _toInvite.isEmpty) ...[
          const SizedBox(height: 60),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                children: [
                  Icon(
                    Icons.contacts_outlined,
                    size: 64,
                    color: theme.colorScheme.onSurface.withOpacity(0.15),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No contacts found',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Contacts from your phone will appear here.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withOpacity(0.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ─── Permission gate ───
  Widget _permissionGate(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.contacts_outlined,
              size: 72,
              color: theme.colorScheme.primary.withOpacity(0.4),
            ),
            const SizedBox(height: 20),
            Text(
              'Contacts permission needed',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'Luma Chat needs access to your phone contacts to find friends.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _loadContacts,
              child: const Text('Grant Permission'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => openAppSettings(),
              child: const Text('Open Settings'),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Section header ───
  Widget _sectionHeader(ThemeData theme, String label, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface.withOpacity(0.55),
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurface.withOpacity(0.4),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Top action tile ───
  Widget _actionTile(
    ThemeData theme, {
    required IconData icon,
    required Color iconColor,
    required String label,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: iconColor.withOpacity(0.15),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: iconColor, size: 22),
      ),
      title: Text(
        label,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
      onTap: onTap,
    );
  }

  // ─── On Luma Chat contact tile ───
  Widget _contactTile(ThemeData theme, Map<String, dynamic> c) {
    final name = c['display_name'] as String? ?? 'User';
    final username = c['username'] as String? ?? '';
    final avatar = c['avatar_url'] as String?;

    return ListTile(
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
        backgroundImage:
            (avatar != null && avatar.isNotEmpty) ? NetworkImage(avatar) : null,
        child: (avatar == null || avatar.isEmpty)
            ? Text(
                name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                  fontSize: 18,
                ),
              )
            : null,
      ),
      title: Text(
        name,
        style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 15),
      ),
      subtitle: username.isNotEmpty
          ? Text(
              '@$username',
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
            )
          : null,
      onTap: () => _startChat(c),
    );
  }

  // ─── Invite tile ───
  Widget _inviteTile(ThemeData theme, Map<String, dynamic> c) {
    final name = c['display_name'] as String? ?? 'Contact';
    final phone = c['phone'] as String? ?? '';

    return ListTile(
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: theme.colorScheme.onSurface.withOpacity(0.08),
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: TextStyle(
            color: theme.colorScheme.onSurface.withOpacity(0.6),
            fontWeight: FontWeight.w600,
            fontSize: 18,
          ),
        ),
      ),
      title: Text(
        name,
        style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 15),
      ),
      subtitle: Text(
        phone,
        style: TextStyle(
          fontSize: 13,
          color: theme.colorScheme.onSurface.withOpacity(0.5),
        ),
      ),
      trailing: TextButton(
        onPressed: () => _inviteContact(phone),
        child: Text(
          'Invite',
          style: TextStyle(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
