import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../providers/chat_provider.dart';
import '../../utils/verified_badge.dart';

class PublicProfileScreen extends StatefulWidget {
  const PublicProfileScreen({super.key});

  @override
  State<PublicProfileScreen> createState() => _PublicProfileScreenState();
}

class _PublicProfileScreenState extends State<PublicProfileScreen> {
  bool _isBlocking = false;
  bool _isAddingContact = false;

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? theme.colorScheme.error : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final args = ModalRoute.of(context)?.settings.arguments
        as Map<String, dynamic>?;

    final userId = args?['userId'] as String?;
    final passedAvatarUrl =
        args?['avatarUrl'] as String? ?? args?['avatar_url'] as String?;

    final currentUserId =
        context.read<LumaAuthProvider>().user?.uid ??
            context.read<LumaAuthProvider>().mockUserId;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Profile'),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
        actions: [
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert,
                color: theme.colorScheme.onSurface.withOpacity(0.7)),
            onSelected: (value) {
              if (value == 'report') {
                _showReportDialog(context, userId, 'User');
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'report',
                child: Row(
                  children: [
                    Icon(Icons.flag_outlined,
                        color: Color(0xFFE0954A), size: 20),
                    SizedBox(width: 12),
                    Text('Report'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: userId == null || currentUserId == null
          ? _buildErrorState(theme, 'Invalid user')
          : StreamBuilder<DocumentSnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(userId)
                  .snapshots(),
              builder: (context, userSnapshot) {
                final liveData =
                    userSnapshot.data?.data() as Map<String, dynamic>?;

                final displayName = liveData?['display_name'] as String? ??
                    liveData?['name'] as String? ??
                    liveData?['username'] as String? ??
                    'Unknown';

                final userUsername = liveData?['username'] as String?;
                final rawAvatarUrl =
                    liveData?['avatar_url'] as String? ?? passedAvatarUrl;
                final email = liveData?['email'] as String?;
                final bio =
                    liveData?['bio'] as String? ?? args?['bio'] as String?;

                return StreamBuilder<DocumentSnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('user_settings')
                      .doc(userId)
                      .snapshots(),
                  builder: (context, settingsSnapshot) {
                    final settingsData = settingsSnapshot.data?.data()
                        as Map<String, dynamic>?;

                    final profilePhotoVisible =
                        settingsData?['profile_photo_visible'] as bool? ??
                            true;
                    final phoneNumberVisible =
                        settingsData?['phone_number_visible'] as bool? ??
                            true;
                    final lastSeenVisible =
                        settingsData?['last_seen_visible'] as bool? ?? true;
                    final voiceVideoCallsVisible =
                        settingsData?['voice_video_calls_visible']
                                as bool? ??
                            true;

                    final avatarUrl =
                        profilePhotoVisible ? rawAvatarUrl : null;
                    final phoneNumber = phoneNumberVisible
                        ? (liveData?['phone_number'] as String?)
                        : null;
                    final lastSeen = lastSeenVisible
                        ? (liveData?['last_seen'] as Timestamp?)
                        : null;

                    return StreamBuilder<DocumentSnapshot>(
                      stream: FirebaseFirestore.instance
                          .collection('users')
                          .doc(currentUserId)
                          .snapshots(),
                      builder: (context, currentUserSnapshot) {
                        final currentUserData = currentUserSnapshot.data
                            ?.data() as Map<String, dynamic>?;
                        final blockedList = List<String>.from(
                            currentUserData?['blocked_users'] ?? []);
                        final contactsList = List<String>.from(
                            currentUserData?['contacts'] ?? []);
                        final isBlocked = blockedList.contains(userId);
                        final isContact = contactsList.contains(userId);

                        return SingleChildScrollView(
                          child: Column(
                            children: [
                              const SizedBox(height: 24),

                              // Avatar
                              Center(
                                child: _buildAvatar(
                                    theme, avatarUrl, displayName),
                              ),

                              const SizedBox(height: 20),

                              // Name with verified badge
                              VerifiedUsername(
                                username: displayName,
                                email: email,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                ),
                                badgeSize: 18,
                                spacing: 8,
                              ),

                              const SizedBox(height: 4),

                              if (userUsername != null &&
                                  userUsername.isNotEmpty)
                                Text(
                                  '@$userUsername',
                                  style: theme.textTheme.bodyMedium
                                      ?.copyWith(
                                    color: theme.colorScheme.onSurface
                                        .withOpacity(0.55),
                                    fontSize: 14,
                                  ),
                                ),

                              // Phone number
                              if (phoneNumber != null &&
                                  phoneNumber.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                    phoneNumber,
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(
                                      color: theme.colorScheme.onSurface
                                          .withOpacity(0.5),
                                    ),
                                  ),
                                ),

                              // Last seen
                              if (lastSeen != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    'Last seen ${_formatLastSeen(lastSeen.toDate())}',
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(
                                      color: theme.colorScheme.onSurface
                                          .withOpacity(0.45),
                                    ),
                                  ),
                                ),

                              const SizedBox(height: 20),

                              // Bio
                              if (bio != null && bio.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 32),
                                  child: Container(
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.onSurface
                                          .withOpacity(0.05),
                                      borderRadius:
                                          BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      bio,
                                      textAlign: TextAlign.center,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                        color: theme.colorScheme.onSurface
                                            .withOpacity(0.75),
                                        height: 1.5,
                                      ),
                                    ),
                                  ),
                                ),

                              const SizedBox(height: 28),

                              // Primary actions
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 32),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: _buildPrimaryButton(
                                        theme,
                                        icon: Icons.message_outlined,
                                        label: 'Message',
                                        onTap: isBlocked
                                            ? () => _toast(
                                                'Unblock user to send messages',
                                                error: true)
                                            : () async {
                                                final chatProvider =
                                                    Provider.of<ChatProvider>(
                                                        context,
                                                        listen: false);
                                                final chat =
                                                    await chatProvider
                                                        .startDirectChat(
                                                            userId);
                                                if (chat != null &&
                                                    mounted) {
                                                  Navigator.pushNamed(
                                                    context,
                                                    '/chat',
                                                    arguments: {
                                                      'chatId': chat['id'],
                                                      'chatName':
                                                          displayName,
                                                      'chatAvatar':
                                                          avatarUrl,
                                                      'isGroup': false,
                                                      'otherUserId': userId,
                                                    },
                                                  );
                                                }
                                              },
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: _buildPrimaryButton(
                                        theme,
                                        icon: Icons.call_outlined,
                                        label: 'Call',
                                        onTap: isBlocked
                                            ? () => _toast(
                                                'Unblock user to call',
                                                error: true)
                                            : !voiceVideoCallsVisible
                                                ? () => _toast(
                                                    'This user does not accept calls',
                                                    error: true)
                                                : () => _toast(
                                                    'Call feature coming soon'),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              const SizedBox(height: 12),

                              // Secondary actions
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 32),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: _buildSecondaryButton(
                                        theme,
                                        icon: isContact
                                            ? Icons.person_remove_outlined
                                            : Icons.person_add_outlined,
                                        label: isContact
                                            ? 'Remove'
                                            : 'Add Contact',
                                        color: isContact
                                            ? const Color(0xFFE0954A)
                                            : const Color(0xFF4FAE4F),
                                        isLoading: _isAddingContact,
                                        onTap: () => _toggleContact(
                                            currentUserId,
                                            userId,
                                            isContact),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: _buildSecondaryButton(
                                        theme,
                                        icon: isBlocked
                                            ? Icons.lock_open
                                            : Icons.block,
                                        label: isBlocked
                                            ? 'Unblock'
                                            : 'Block',
                                        color: isBlocked
                                            ? theme.colorScheme.onSurface
                                                .withOpacity(0.6)
                                            : theme.colorScheme.error,
                                        isLoading: _isBlocking,
                                        onTap: () => _toggleBlock(
                                          currentUserId,
                                          userId,
                                          isBlocked,
                                          displayName,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              const SizedBox(height: 32),
                            ],
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
    );
  }

  String _formatLastSeen(DateTime date) {
    final diff = DateTime.now().difference(date);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${date.day}/${date.month}/${date.year}';
  }

  Future<void> _toggleBlock(
    String currentUserId,
    String targetUserId,
    bool isBlocked,
    String displayName,
  ) async {
    setState(() => _isBlocking = true);

    try {
      final userRef =
          FirebaseFirestore.instance.collection('users').doc(currentUserId);

      if (isBlocked) {
        await userRef.set({
          'blocked_users': FieldValue.arrayRemove([targetUserId]),
          'updated_at': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        _toast('Unblocked $displayName');
      } else {
        await userRef.set({
          'blocked_users': FieldValue.arrayUnion([targetUserId]),
          'contacts': FieldValue.arrayRemove([targetUserId]),
          'updated_at': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        _toast('Blocked $displayName', error: true);
      }
    } catch (e) {
      _toast('Error: $e', error: true);
    } finally {
      if (mounted) setState(() => _isBlocking = false);
    }
  }

  Future<void> _toggleContact(
    String currentUserId,
    String targetUserId,
    bool isContact,
  ) async {
    setState(() => _isAddingContact = true);

    try {
      final userRef =
          FirebaseFirestore.instance.collection('users').doc(currentUserId);

      if (isContact) {
        await userRef.set({
          'contacts': FieldValue.arrayRemove([targetUserId]),
          'updated_at': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        _toast('Contact removed');
      } else {
        await userRef.set({
          'contacts': FieldValue.arrayUnion([targetUserId]),
          'updated_at': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        _toast('Contact added');
      }
    } catch (e) {
      _toast('Error: $e', error: true);
    } finally {
      if (mounted) setState(() => _isAddingContact = false);
    }
  }

  void _showReportDialog(
    BuildContext context,
    String? reportedUserId,
    String reportedDisplayName,
  ) {
    final reasonController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Report $reportedDisplayName?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'This will be reviewed by our team. False reports may result in account suspension.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: reasonController,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: 'Reason for reporting (optional)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final currentUserId =
                  context.read<LumaAuthProvider>().user?.uid ??
                      context.read<LumaAuthProvider>().mockUserId;
              if (currentUserId == null || reportedUserId == null) return;

              Navigator.pop(ctx);

              try {
                await FirebaseFirestore.instance
                    .collection('reports')
                    .add({
                  'reporter_id': currentUserId,
                  'reported_user_id': reportedUserId,
                  'reported_username': reportedDisplayName,
                  'reason': reasonController.text.trim().isEmpty
                      ? 'No reason provided'
                      : reasonController.text.trim(),
                  'status': 'pending',
                  'created_at': FieldValue.serverTimestamp(),
                });

                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Report submitted. Thank you.'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Failed to report: $e'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              }
            },
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFE0954A),
            ),
            child: const Text('Report'),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(
    ThemeData theme,
    String? avatarUrl,
    String displayName,
  ) {
    final initial =
        displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';
    const size = 110.0;

    if (avatarUrl == null || avatarUrl.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: theme.colorScheme.primary.withOpacity(0.15),
        ),
        child: Center(
          child: Text(
            initial,
            style: TextStyle(
              color: theme.colorScheme.primary,
              fontSize: 44,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      );
    }

    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: avatarUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (context, url) => Container(
          width: size,
          height: size,
          color: theme.colorScheme.primary.withOpacity(0.1),
          child: const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
        errorWidget: (context, url, error) {
          debugPrint('PublicProfile avatar error: $error');
          return Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: theme.colorScheme.primary.withOpacity(0.15),
            ),
            child: Center(
              child: Text(
                initial,
                style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontSize: 44,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPrimaryButton(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSecondaryButton(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required Color color,
    required bool isLoading,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: isLoading ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: isLoading
            ? Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: color, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildErrorState(ThemeData theme, String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            color: theme.colorScheme.onSurface.withOpacity(0.3),
            size: 48,
          ),
          const SizedBox(height: 16),
          Text(
            message,
            style: TextStyle(
              color: theme.colorScheme.onSurface.withOpacity(0.5),
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}
