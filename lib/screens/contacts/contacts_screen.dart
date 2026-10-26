import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../providers/auth_provider.dart' show LumaAuthProvider;

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  String? _currentUserId;
  bool _isLoading = true;
  bool _permissionDenied = false;
  List<Map<String, dynamic>> _lumaContacts = [];
  List<Map<String, dynamic>> _inviteContacts = [];
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _currentUserId = Provider.of<LumaAuthProvider>(context, listen: false).user?.uid ??
        Provider.of<LumaAuthProvider>(context, listen: false).mockUserId;
    _loadContacts();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    setState(() => _isLoading = true);
    
    try {
      // 1. Ask for permission
      final status = await Permission.contacts.request();
      if (status.isDenied) {
        setState(() {
          _permissionDenied = true;
          _isLoading = false;
        });
        return;
      }

      // 2. Fetch phone contacts
      final contacts = await FlutterContacts.getContacts(withProperties: true);
      
      // 3. Fetch Luma Users to match
      final lumaUsersSnap = await FirebaseFirestore.instance.collection('users').get();
      final lumaUsers = lumaUsersSnap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();

      final matched = <Map<String, dynamic>>[];
      final invites = <Map<String, dynamic>>[];
      final Set<String> processedNumbers = {};

      for (final c in contacts) {
        if (c.phones.isEmpty) continue;
        
        final phone = c.phones.first.number.replaceAll(RegExp(r'[^\d+]'), '');
        if (processedNumbers.contains(phone)) continue;
        processedNumbers.add(phone);

        final displayName = c.displayName ?? phone;

        // Find if this phone exists in Luma Chat
        final lumaUser = lumaUsers.firstWhere(
          (u) => (u['phone_number'] ?? '').toString().replaceAll(RegExp(r'[^\d+]'), '') == phone,
          orElse: () => {},
        );

        if (lumaUser.isNotEmpty) {
          matched.add({
            'id': lumaUser['id'],
            'name': lumaUser['display_name'] ?? displayName,
            'phone': phone,
            'avatar_url': lumaUser['avatar_url'],
            'is_on_luma': true,
          });
        } else {
          invites.add({
            'id': phone,
            'name': displayName,
            'phone': phone,
            'is_on_luma': false,
          });
        }
      }

      if (mounted) {
        setState(() {
          _lumaContacts = matched;
          _inviteContacts = invites;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Contact load error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // NEW CONTACT MODAL
  // ═══════════════════════════════════════════════════════════════════════
  void _showNewContactSheet() {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    bool isSaving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final isDark = theme.brightness == Brightness.dark;

        return StatefulBuilder(
          builder: (context, setState) {
            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: Container(
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF17212B) : Colors.white,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                ),
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2))),
                    const SizedBox(height: 16),
                    Text('New Contact', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface)),
                    const SizedBox(height: 24),
                    _buildInputField(theme, 'Contact Name', nameCtrl, Icons.person_outline),
                    const SizedBox(height: 12),
                    _buildInputField(theme, 'Phone Number', phoneCtrl, Icons.phone_outlined, keyboardType: TextInputType.phone),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        onPressed: isSaving ? null : () async {
                          if (phoneCtrl.text.trim().isEmpty) return;
                          setState(() => isSaving = true);
                          
                          try {
                            final phone = phoneCtrl.text.trim().replaceAll(RegExp(r'[^\d+]'), '');
                            final name = nameCtrl.text.trim().isEmpty ? phone : nameCtrl.text.trim();
                            
                            // Just save to your app's contacts list
                            await FirebaseFirestore.instance.collection('users').doc(_currentUserId).collection('contacts').add({
                              'display_name': name,
                              'phone_number': phone,
                              'created_at': FieldValue.serverTimestamp(),
                            });
                            
                            if (!mounted) return;
                            Navigator.pop(ctx);
                            _loadContacts();
                          } finally {
                            if (mounted) setState(() => isSaving = false);
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: theme.colorScheme.primary,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        child: isSaving ? const CircularProgressIndicator(color: Colors.white) : const Text('Save Contact'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildInputField(ThemeData theme, String hint, TextEditingController ctrl, IconData icon, {TextInputType? keyboardType}) {
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(color: isDark ? const Color(0xFF242F3D) : const Color(0xFFF1F1F1), borderRadius: BorderRadius.circular(12)),
      child: TextField(
        controller: ctrl,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: Icon(icon, color: theme.colorScheme.onSurface.withOpacity(0.5), size: 20),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
      ),
    );
  }

  void _showNewGroupSheet() {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.group),
              title: const Text('New Group'),
              onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/create_group');
              },
            ),
            ListTile(
              leading: const Icon(Icons.campaign),
              title: const Text('New Channel'),
              onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/create_channel');
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Contacts'),
        backgroundColor: theme.scaffoldBackgroundColor,
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_alt_1),
            onPressed: _showNewContactSheet,
          ),
          PopupMenuButton<String>(
            onSelected: (val) {
              if (val == 'group') _showNewGroupSheet();
              if (val == 'refresh') _loadContacts();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'group', child: Text('New Group / Channel')),
              const PopupMenuItem(value: 'refresh', child: Text('Refresh')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Search Bar
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _searchQuery = v.toLowerCase()),
              decoration: InputDecoration(
                hintText: 'Search contacts...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: theme.colorScheme.onSurface.withOpacity(0.05),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
          ),
          
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _permissionDenied
                    ? Center(child: TextButton(onPressed: _loadContacts, child: const Text('Grant Permission')))
                    : ListView(
                        children: [
                          if (_lumaContacts.isNotEmpty) ...[
                            _sectionHeader(theme, 'ON LUMA CHAT'),
                            ..._lumaContacts.where((c) => c['name'].toLowerCase().contains(_searchQuery)).map((c) => _contactTile(theme, c, true)),
                          ],
                          if (_inviteContacts.isNotEmpty) ...[
                            _sectionHeader(theme, 'INVITE TO LUMA CHAT'),
                            ..._inviteContacts.where((c) => c['name'].toLowerCase().contains(_searchQuery)).map((c) => _contactTile(theme, c, false)),
                          ],
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: theme.colorScheme.primary, letterSpacing: 1.1),
      ),
    );
  }

  Widget _contactTile(ThemeData theme, Map<String, dynamic> contact, bool isOnLuma) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primary.withOpacity(0.1),
        backgroundImage: isOnLuma && contact['avatar_url'] != null ? NetworkImage(contact['avatar_url']) : null,
        child: !isOnLuma || contact['avatar_url'] == null ? Icon(Icons.person, color: theme.colorScheme.primary) : null,
      ),
      title: Text(contact['name']),
      subtitle: Text(contact['phone']),
      trailing: isOnLuma
          ? const Icon(Icons.chat_bubble_outline, size: 20)
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(20)),
              child: const Text('Invite', style: TextStyle(color: Colors.white, fontSize: 12)),
            ),
      onTap: () {
        if (isOnLuma) {
          Navigator.pushNamed(context, '/chat', arguments: {
            'chatName': contact['name'],
            'chatAvatar': contact['avatar_url'],
            'isGroup': false,
            'otherUserId': contact['id'],
          });
        } else {
          // Send invite link
          final url = 'https://lumachat.app/invite?phone=${contact['phone']}';
          launchUrl(Uri.parse(url));
        }
      },
    );
  }
}
