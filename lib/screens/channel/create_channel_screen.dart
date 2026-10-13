import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';
import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../providers/chat_provider.dart';
import '../../services/cloudinary_service.dart';
import '../../services/invitation_service.dart';

class CreateChannelScreen extends StatefulWidget {
  const CreateChannelScreen({super.key});

  @override
  State<CreateChannelScreen> createState() => _CreateChannelScreenState();
}

class _CreateChannelScreenState extends State<CreateChannelScreen> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _searchController = TextEditingController();
  final _inviteNameController = TextEditingController();

  String? _channelPhotoUrl;
  bool _isLoading = false;
  List<Map<String, dynamic>> _selectedMembers = [];
  List<Map<String, dynamic>> _searchResults = [];
  String? _generatedLink;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _searchController.dispose();
    _inviteNameController.dispose();
    super.dispose();
  }

  Future<void> _pickChannelPhoto() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile == null) return;

    setState(() => _isLoading = true);

    try {
      final authProvider =
          Provider.of<LumaAuthProvider>(context, listen: false);
      final userId = authProvider.user?.uid ?? authProvider.mockUserId;
      if (userId == null) throw Exception('Not authenticated');

      final imageUrl = await CloudinaryService.uploadImage(
        File(pickedFile.path),
        'luma/permanent/avatars/channels/$userId',
      );

      if (imageUrl == null) throw Exception('Upload failed');
      if (!mounted) return;
      setState(() => _channelPhotoUrl = imageUrl);
    } catch (e) {
      debugPrint('Photo upload failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Photo upload failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _searchUsers(String query) async {
    if (query.isEmpty) {
      setState(() => _searchResults = []);
      return;
    }

    try {
      final authProvider =
          Provider.of<LumaAuthProvider>(context, listen: false);
      final currentUserId =
          authProvider.user?.uid ?? authProvider.mockUserId;

      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .where('username', isGreaterThanOrEqualTo: query)
          .where('username', isLessThanOrEqualTo: '$query\uf8ff')
          .limit(20)
          .get();

      final filtered = snapshot.docs
          .map((doc) => {'id': doc.id, ...doc.data()})
          .where((u) => u['id'] != currentUserId)
          .toList();

      if (!mounted) return;
      setState(() => _searchResults = filtered);
    } catch (e) {
      debugPrint('Search error: $e');
    }
  }

  void _toggleMember(Map<String, dynamic> user) {
    setState(() {
      final index =
          _selectedMembers.indexWhere((m) => m['id'] == user['id']);
      if (index >= 0) {
        _selectedMembers.removeAt(index);
      } else {
        _selectedMembers.add(user);
      }
    });
  }

  Future<void> _createChannel() async {
    if (_nameController.text.trim().isEmpty) {
      _showError('Please enter a channel name');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final authProvider =
          Provider.of<LumaAuthProvider>(context, listen: false);
      final chatProvider =
          Provider.of<ChatProvider>(context, listen: false);
      final userId = authProvider.user?.uid ?? authProvider.mockUserId;
      final email = authProvider.email ?? '';

      if (userId == null) throw Exception('Not authenticated');

      final participants = [
        userId,
        ..._selectedMembers.map((m) => m['id'] as String),
      ];
      final participantsData = <String, dynamic>{};

      for (final id in participants) {
        participantsData[id] = {
          'role': id == userId ? 'owner' : 'subscriber',
          'joined_at': FieldValue.serverTimestamp(),
        };
      }

      final chatId = const Uuid().v4();

      await FirebaseFirestore.instance
          .collection('chats')
          .doc(chatId)
          .set({
        'id': chatId,
        'name': _nameController.text.trim(),
        'description': _descriptionController.text.trim().isNotEmpty
            ? _descriptionController.text.trim()
            : null,
        'avatar_url': _channelPhotoUrl,
        'type': 'channel',
        'created_by': userId,
        'created_by_email': email,
        'participants': participants,
        'participants_data': participantsData,
        'member_count': participants.length,
        'banned_users': [],
        'settings': {
          'chat_disabled': false,
          'file_sharing_disabled': false,
          'slow_mode_seconds': 0,
          'restrict_new_members_minutes': 0,
          'message_retention_days': 0,
          'welcome_message': 'Welcome to ${_nameController.text.trim()}!',
          'rules': 'Be respectful and kind to all members.',
          'announcements_only': true,
          'polls_enabled': true,
          'reactions_enabled': true,
          'forwarding_enabled': true,
          'voice_chat_enabled': false,
        },
        'pinned_messages': [],
        'created_at': FieldValue.serverTimestamp(),
        'updated_at': FieldValue.serverTimestamp(),
        'last_message_at': FieldValue.serverTimestamp(),
        'last_message': 'Channel created',
      });

      try {
        final inviteResult = await InvitationService.createInvitation(
          chatId: chatId,
          chatName: _nameController.text.trim(),
          chatType: 'channel',
          createdBy: userId,
          customName: _inviteNameController.text.trim().isNotEmpty
              ? _inviteNameController.text.trim()
              : null,
        );
        if (!mounted) return;
        setState(() => _generatedLink = inviteResult['link'] as String?);
      } catch (e) {
        debugPrint('Invitation creation failed: $e');
      }

      // FIX: Wait for Firestore to resolve serverTimestamp before loading.
      await Future.delayed(const Duration(milliseconds: 800));
      await chatProvider.loadChats();

      if (!mounted) return;
      setState(() => _isLoading = false);

      if (_generatedLink == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Channel created successfully!')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showError('Error: $e');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _copyLink() {
    if (_generatedLink == null) return;
    Clipboard.setData(ClipboardData(text: _generatedLink!));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Link copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.arrow_back,
                        color: theme.colorScheme.onSurface),
                    onPressed: () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: Text(
                      'New Channel',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (_isLoading)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    )
                  else if (_generatedLink == null)
                    TextButton(
                      onPressed: _createChannel,
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.primary,
                        textStyle: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                      child: const Text('Create'),
                    )
                  else
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.primary,
                        textStyle: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                      child: const Text('Done'),
                    ),
                ],
              ),
            ),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Photo upload
                    Center(
                      child: GestureDetector(
                        onTap: _generatedLink == null
                            ? _pickChannelPhoto
                            : null,
                        child: Stack(
                          children: [
                            _buildChannelAvatar(theme),
                            if (_generatedLink == null)
                              Positioned(
                                bottom: 0,
                                right: 0,
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primary,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: theme.scaffoldBackgroundColor,
                                      width: 2,
                                    ),
                                  ),
                                  child: const Icon(Icons.camera_alt,
                                      color: Colors.white, size: 14),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_generatedLink == null)
                      Center(
                        child: Text(
                          'Tap to add photo',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface
                                .withOpacity(0.5),
                          ),
                        ),
                      ),
                    const SizedBox(height: 32),

                    if (_generatedLink != null) ...[
                      _buildGeneratedLinkCard(theme),
                      const SizedBox(height: 24),
                    ] else ...[
                      _buildField(
                        theme,
                        label: 'Channel Name',
                        hint: 'Enter channel name',
                        icon: Icons.edit_outlined,
                        controller: _nameController,
                      ),
                      const SizedBox(height: 16),
                      _buildField(
                        theme,
                        label: 'Description',
                        hint: 'Add a description (optional)',
                        icon: Icons.description_outlined,
                        controller: _descriptionController,
                        maxLines: 2,
                      ),
                      const SizedBox(height: 16),
                      _buildField(
                        theme,
                        label: 'Invitation Link Name',
                        hint: 'e.g., my-awesome-channel (optional)',
                        icon: Icons.link,
                        controller: _inviteNameController,
                      ),
                      const SizedBox(height: 16),

                      // Info banner
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: theme.colorScheme.primary
                                .withOpacity(0.2),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary
                                    .withOpacity(0.15),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.campaign_outlined,
                                color: theme.colorScheme.primary,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'One-Way Messaging',
                                    style: theme.textTheme.titleSmall
                                        ?.copyWith(
                                            fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Only admins and owner can post messages',
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(
                                      color: theme.colorScheme.onSurface
                                          .withOpacity(0.6),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),

                      _buildField(
                        theme,
                        label: 'Add Subscribers',
                        hint: 'Search users to add... (optional)',
                        icon: Icons.search,
                        controller: _searchController,
                        onChanged: _searchUsers,
                      ),

                      if (_selectedMembers.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        SizedBox(
                          height: 92,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: _selectedMembers.length,
                            itemBuilder: (context, index) {
                              final member = _selectedMembers[index];
                              return Padding(
                                padding: const EdgeInsets.only(right: 12),
                                child: Column(
                                  children: [
                                    Stack(
                                      children: [
                                        _buildMemberAvatar(
                                          theme,
                                          member['avatar_url'],
                                          member['username'],
                                        ),
                                        Positioned(
                                          top: 0,
                                          right: 0,
                                          child: GestureDetector(
                                            onTap: () =>
                                                _toggleMember(member),
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.all(2),
                                              decoration: BoxDecoration(
                                                color: theme
                                                    .colorScheme.error,
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                  color: theme
                                                      .scaffoldBackgroundColor,
                                                  width: 2,
                                                ),
                                              ),
                                              child: const Icon(Icons.close,
                                                  size: 12,
                                                  color: Colors.white),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    SizedBox(
                                      width: 60,
                                      child: Text(
                                        member['username'] ?? 'Unknown',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(fontSize: 11),
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ],

                      if (_searchResults.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        ..._searchResults.map((user) {
                          final isSelected = _selectedMembers
                              .any((m) => m['id'] == user['id']);
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.onSurface
                                  .withOpacity(0.03),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: ListTile(
                              leading: _buildMemberAvatar(
                                theme,
                                user['avatar_url'],
                                user['username'],
                              ),
                              title: Text(
                                user['username'] ?? 'Unknown',
                                style: const TextStyle(fontSize: 15),
                              ),
                              subtitle: Text(
                                user['email'] ?? '',
                                style: TextStyle(
                                  color: theme.colorScheme.onSurface
                                      .withOpacity(0.5),
                                  fontSize: 13,
                                ),
                              ),
                              trailing: isSelected
                                  ? Icon(Icons.check_circle,
                                      color: theme.colorScheme.primary)
                                  : Icon(Icons.add_circle_outline,
                                      color: theme.colorScheme.onSurface
                                          .withOpacity(0.4)),
                              onTap: () => _toggleMember(user),
                            ),
                          );
                        }),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGeneratedLinkCard(ThemeData theme) {
    final name = _nameController.text.trim().isEmpty
        ? 'Channel'
        : _nameController.text.trim();
    final memberCount = _selectedMembers.length + 1;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.primary.withOpacity(0.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle,
                  color: Color(0xFF4FAE4F), size: 18),
              const SizedBox(width: 8),
              const Text(
                'Channel created',
                style: TextStyle(
                  color: Color(0xFF4FAE4F),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.primary.withOpacity(0.15),
                ),
                child: (_channelPhotoUrl != null &&
                        _channelPhotoUrl!.isNotEmpty)
                    ? ClipOval(
                        child: Image.network(_channelPhotoUrl!,
                            fit: BoxFit.cover))
                    : Icon(Icons.campaign,
                        color: theme.colorScheme.primary, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(children: [
                      Icon(Icons.campaign,
                          size: 11, color: theme.colorScheme.primary),
                      const SizedBox(width: 4),
                      Text(
                        'CHANNEL',
                        style: TextStyle(
                          color: theme.colorScheme.primary,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ]),
                    const SizedBox(height: 2),
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      '$memberCount subscriber${memberCount != 1 ? 's' : ''}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface
                            .withOpacity(0.55),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurface.withOpacity(0.05),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.link,
                    size: 14,
                    color: theme.colorScheme.onSurface.withOpacity(0.5)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _generatedLink ?? '',
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _copyLink,
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy Link'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.onSurface,
                    side: BorderSide(color: theme.dividerColor),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    Clipboard.setData(
                        ClipboardData(text: _generatedLink ?? ''));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content:
                            Text('Link copied — paste it anywhere to share'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.share, size: 16),
                  label: const Text('Share'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChannelAvatar(ThemeData theme) {
    if (_channelPhotoUrl != null && _channelPhotoUrl!.isNotEmpty) {
      return CircleAvatar(
        radius: 48,
        backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
        backgroundImage: NetworkImage(_channelPhotoUrl!),
        onBackgroundImageError: (_, __) {},
      );
    }
    return CircleAvatar(
      radius: 48,
      backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
      child: Icon(
        Icons.campaign,
        size: 48,
        color: theme.colorScheme.primary,
      ),
    );
  }

  Widget _buildMemberAvatar(
    ThemeData theme,
    String? avatarUrl,
    String? username,
  ) {
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      return CircleAvatar(
        radius: 28,
        backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
        backgroundImage: NetworkImage(avatarUrl),
        onBackgroundImageError: (_, __) {},
      );
    }
    return CircleAvatar(
      radius: 28,
      backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
      child: Text(
        (username ?? 'U')[0].toUpperCase(),
        style: TextStyle(
          fontSize: 20,
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildField(
    ThemeData theme, {
    required String label,
    required String hint,
    required IconData icon,
    required TextEditingController controller,
    int maxLines = 1,
    Function(String)? onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w500,
            color: theme.colorScheme.onSurface.withOpacity(0.7),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          maxLines: maxLines,
          onChanged: onChanged,
          style: TextStyle(
            color: theme.colorScheme.onSurface,
            fontSize: 16,
          ),
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: Icon(icon, color: theme.colorScheme.primary),
          ),
        ),
      ],
    );
  }
}
