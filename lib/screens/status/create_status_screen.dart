import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart' show LumaAuthProvider;
import '../../services/cloudinary_service.dart';

class CreateStatusScreen extends StatefulWidget {
  const CreateStatusScreen({super.key});

  @override
  State<CreateStatusScreen> createState() => _CreateStatusScreenState();
}

class _CreateStatusScreenState extends State<CreateStatusScreen> {
  final _textController = TextEditingController();
  final _captionController = TextEditingController();
  final _captionFocus = FocusNode();

  File? _selectedImage;
  bool _isLoading = false;

  // Telegram story colors — soft pastel gradient for text-only status
  static const List<List<Color>> _textGradients = [
    [Color(0xFF3390EC), Color(0xFF2B7CD3)], // blue
    [Color(0xFFE0954A), Color(0xFFC97A2F)], // orange
    [Color(0xFF8B7BB8), Color(0xFF6E5FA0)], // purple
    [Color(0xFF4FAE4F), Color(0xFF3D8B3D)], // green
    [Color(0xFFE53935), Color(0xFFC62828)], // red
  ];

  int _gradientIndex = 0;

  @override
  void dispose() {
    _textController.dispose();
    _captionController.dispose();
    _captionFocus.dispose();
    super.dispose();
  }

  // ─── Pickers ───

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );
    if (pickedFile != null) {
      setState(() => _selectedImage = File(pickedFile.path));
    }
  }

  Future<void> _takePhoto() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 80,
    );
    if (pickedFile != null) {
      setState(() => _selectedImage = File(pickedFile.path));
    }
  }

  void _clearMedia() {
    setState(() => _selectedImage = null);
  }

  // ─── Send ───

  Future<void> _createStatus() async {
    final hasText = _textController.text.trim().isNotEmpty;
    final hasImage = _selectedImage != null;

    if (!hasText && !hasImage) {
      _showError('Add some text or a photo first');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final auth = Provider.of<LumaAuthProvider>(context, listen: false);
      final userId = auth.user?.uid ?? auth.mockUserId;

      if (userId == null) throw Exception('Not authenticated');

      String? mediaUrl;
      String? cloudinaryPublicId;
      String type = hasImage ? 'image' : 'text';

      // Caption: if image → use caption field. If text-only → use main text field.
      final captionText = hasImage
          ? _captionController.text.trim()
          : _textController.text.trim();

      if (_selectedImage != null) {
        final uploadResult = await CloudinaryService.uploadImageWithId(
          _selectedImage!,
          'luma/statuses/$userId',
        );
        if (uploadResult == null) {
          throw Exception('Failed to upload image');
        }
        mediaUrl = uploadResult.secureUrl;
        cloudinaryPublicId = uploadResult.publicId;
      }

      final now = DateTime.now();
      final expiresAt = now.add(const Duration(hours: 24));

      await FirebaseFirestore.instance.collection('statuses').add({
        'user_id': userId,
        'caption': captionText.isNotEmpty ? captionText : null,
        'media_url': mediaUrl,
        'cloudinary_public_id': cloudinaryPublicId,
        'type': type,
        'gradient_index': _gradientIndex,
        'created_at': Timestamp.fromDate(now),
        'expires_at': Timestamp.fromDate(expiresAt),
        'view_count': 0,
        'likes': [],
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Status added — expires in 24h')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showError('Error: $e');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }

  bool get _canSend =>
      _textController.text.trim().isNotEmpty || _selectedImage != null;

  // ─── Build ───

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        // Always black — Telegram does this even in light theme
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              _buildTopBar(),
              const SizedBox(height: 8),
              Expanded(
                child: _selectedImage != null
                    ? _buildImagePreview()
                    : _buildTextEditor(),
              ),
              const SizedBox(height: 12),
              _buildBottomActions(),
              _buildExpiryHint(),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Top bar: ✕  New Story  [Send] ───
  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white, size: 26),
            onPressed: () => Navigator.pop(context),
          ),
          const Expanded(
            child: Text(
              'New Story',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          _isLoading
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF3390EC),
                    ),
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: TextButton(
                    onPressed: _canSend ? _createStatus : null,
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF3390EC),
                      disabledForegroundColor: Colors.white.withOpacity(0.3),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                    ),
                    child: const Text(
                      'Send',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
        ],
      ),
    );
  }

  // ─── Text editor (text-only status) ───
  Widget _buildTextEditor() {
    final gradient = _textGradients[_gradientIndex];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: gradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: TextField(
                  controller: _textController,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Type a status...',
                    hintStyle: TextStyle(
                      color: Colors.white.withOpacity(0.5),
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                    ),
                    border: InputBorder.none,
                  ),
                  maxLines: null,
                  textAlign: TextAlign.center,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ),
            // Gradient picker row
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_textGradients.length, (i) {
                final g = _textGradients[i];
                final selected = i == _gradientIndex;
                return GestureDetector(
                  onTap: () => setState(() => _gradientIndex = i),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: selected ? 26 : 22,
                    height: selected ? 26 : 22,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: g),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? Colors.white : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Image preview (image status) ───
  Widget _buildImagePreview() {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Image
        Positioned.fill(
          child: Image.file(
            _selectedImage!,
            fit: BoxFit.contain,
          ),
        ),

        // Caption overlay at bottom
        Positioned(
          bottom: 16,
          left: 16,
          right: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.5),
              borderRadius: BorderRadius.circular(24),
            ),
            child: TextField(
              controller: _captionController,
              focusNode: _captionFocus,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
              ),
              decoration: InputDecoration(
                hintText: 'Add a caption...',
                hintStyle: TextStyle(
                  color: Colors.white.withOpacity(0.6),
                  fontSize: 15,
                ),
                border: InputBorder.none,
                isDense: true,
              ),
              textAlign: TextAlign.center,
              maxLines: 3,
              minLines: 1,
            ),
          ),
        ),
      ],
    );
  }

  // ─── Bottom action pills ───
  Widget _buildBottomActions() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _actionPill(
            icon: Icons.camera_alt_outlined,
            label: 'Camera',
            active: false,
            onTap: _takePhoto,
          ),
          const SizedBox(width: 12),
          _actionPill(
            icon: Icons.photo_library_outlined,
            label: 'Gallery',
            active: _selectedImage != null,
            onTap: _pickImage,
          ),
          const SizedBox(width: 12),
          _actionPill(
            icon: Icons.text_fields,
            label: 'Text',
            active: _selectedImage == null,
            onTap: () => setState(() => _selectedImage = null),
          ),
          if (_selectedImage != null) ...[
            const SizedBox(width: 12),
            _actionPill(
              icon: Icons.delete_outline,
              label: 'Clear',
              active: false,
              danger: true,
              onTap: _clearMedia,
            ),
          ],
        ],
      ),
    );
  }

  Widget _actionPill({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final baseColor = danger
        ? const Color(0xFFE53935)
        : (active ? const Color(0xFF3390EC) : Colors.white);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: active
                ? const Color(0xFF3390EC).withOpacity(0.5)
                : Colors.transparent,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: baseColor, size: 20),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: baseColor,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── 24h expiry hint ───
  Widget _buildExpiryHint() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.timer_outlined,
            size: 14,
            color: Colors.white.withOpacity(0.5),
          ),
          const SizedBox(width: 6),
          Text(
            'Auto-deletes after 24 hours',
            style: TextStyle(
              color: Colors.white.withOpacity(0.5),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
