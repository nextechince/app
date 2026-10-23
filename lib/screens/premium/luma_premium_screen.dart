import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../providers/auth_provider.dart' show LumaAuthProvider;

class LumaPremiumScreen extends StatefulWidget {
  const LumaPremiumScreen({super.key});

  @override
  State<LumaPremiumScreen> createState() => _LumaPremiumScreenState();
}

class _LumaPremiumScreenState extends State<LumaPremiumScreen> {
  bool _isPremium = false;
  bool _isLoading = true;
  int _selectedPlanIndex = 0; // 0 = Monthly, 1 = Yearly

  @override
  void initState() {
    super.initState();
    _checkPremiumStatus();
  }

  void _checkPremiumStatus() {
    final uid = Provider.of<LumaAuthProvider>(context, listen: false).user?.uid ??
        Provider.of<LumaAuthProvider>(context, listen: false).mockUserId;
    if (uid == null) return;

    FirebaseFirestore.instance.collection('users').doc(uid).snapshots().listen((doc) {
      if (mounted && doc.exists) {
        setState(() {
          _isPremium = doc.data()?['is_premium'] == true;
          _isLoading = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Luma Premium'),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 🌟 PREMIUM HEADER
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: isDark 
                            ? [const Color(0xFF2B2B2B), const Color(0xFF1A1A1A)]
                            : [const Color(0xFFF7F7F7), const Color(0xFFEAEAEA)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: const Color(0xFFD4A73A), width: 2), // Gold border
                    ),
                    child: Column(
                      children: [
                        const Icon(Icons.stars, color: Color(0xFFD4A73A), size: 64),
                        const SizedBox(height: 16),
                        Text(
                          _isPremium ? 'You are Premium!' : 'Unlock Luma Premium',
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _isPremium
                              ? 'Thank you for supporting Luma Chat.'
                              : 'Get exclusive features, AI tools, and higher limits.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: theme.colorScheme.onSurface.withOpacity(0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),

                  // 🚀 BENEFITS LIST (GROUPED)
                  _buildCategoryTitle(theme, 'Customization & Identity'),
                  _buildBenefitRow(Icons.badge, 'Golden Premium Badge', 'Stand out in chats with a golden star.'),
                  _buildBenefitRow(Icons.phonelink_setup, 'Custom App Icons', 'Change the Luma Chat logo on your home screen.'),
                  _buildBenefitRow(Icons.gif_box, 'Animated Profile Picture', 'Make your avatar a GIF instead of a static image.'),
                  _buildBenefitRow(Icons.palette, 'Premium Themes', 'Exclusive chat backgrounds, bubble colors, and fonts.'),

                  _buildCategoryTitle(theme, 'Speed & Limits'),
                  _buildBenefitRow(Icons.cloud_upload, '2GB File Uploads', 'Send massive files without compression.'),
                  _buildBenefitRow(Icons.speed, 'Faster Downloads', 'No speed limits when downloading media.'),
                  _buildBenefitRow(Icons.video_settings, '4K Video Quality', 'Upload videos in 4K instead of 720p.'),

                  _buildCategoryTitle(theme, 'AI & Smart Tools'),
                  _buildBenefitRow(Icons.auto_awesome, 'AI Message Summarizer', 'Tap a long message to get an instant AI summary.'),
                  _buildBenefitRow(Icons.record_voice_over, 'Voice Auto-Reply', 'Reads messages aloud and records your reply.'),
                  _buildBenefitRow(Icons.translate, 'AI Translation', 'Instantly translate any message into your language.'),
                  _buildBenefitRow(Icons.mic, 'Voice-to-Text', 'Convert incoming voice notes to text instantly.'),

                  _buildCategoryTitle(theme, 'Chat & Reactions'),
                  _buildBenefitRow(Icons.emoji_emotions, 'Unlimited Reactions', 'Access to 100+ custom emojis and reactions.'),
                  _buildBenefitRow(Icons.folder_special, 'Unlimited Chat Folders', 'Create unlimited custom folders.'),
                  _buildBenefitRow(Icons.schedule, 'Schedule Messages', 'Schedule messages to be sent at a specific time.'),
                  _buildBenefitRow(Icons.push_pin, 'Pin up to 10 Chats', 'Pin more chats to the top of your list.'),

                  const SizedBox(height: 32),

                  // 💳 SUBSCRIPTION PLANS
                  if (!_isPremium) ...[
                    Text(
                      'Choose your plan',
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: _buildPlanCard(
                            title: 'Monthly',
                            price: '\$4.99',
                            subtitle: 'per month',
                            isSelected: _selectedPlanIndex == 0,
                            onTap: () => setState(() => _selectedPlanIndex = 0),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildPlanCard(
                            title: 'Yearly',
                            price: '\$39.99',
                            subtitle: 'Save 33%',
                            isSelected: _selectedPlanIndex == 1,
                            onTap: () => setState(() => _selectedPlanIndex = 1),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: () => _handleSubscribe(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFD4A73A), // Gold Button
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: Text(
                        _selectedPlanIndex == 0 ? 'Subscribe for \$4.99/month' : 'Subscribe for \$39.99/year',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () {},
                      child: const Text('Restore Purchases', style: TextStyle(color: Colors.grey)),
                    ),
                  ] else ...[
                    ElevatedButton(
                      onPressed: () {},
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: const Text('Cancel Subscription'),
                    ),
                  ],
                  const SizedBox(height: 48),
                ],
              ),
            ),
    );
  }

  Widget _buildCategoryTitle(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 16),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: const Color(0xFFD4A73A),
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildBenefitRow(IconData icon, String title, String subtitle) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFD4A73A).withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: const Color(0xFFD4A73A), size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                const SizedBox(height: 4),
                Text(subtitle, style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlanCard({
    required String title,
    required String price,
    required String subtitle,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected 
              ? const Color(0xFFD4A73A).withOpacity(0.1) 
              : (isDark ? const Color(0xFF1A1A1A) : Colors.white),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? const Color(0xFFD4A73A) : Colors.grey.withOpacity(0.3),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            Text(price, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 24, color: Color(0xFFD4A73A))),
            const SizedBox(height: 4),
            Text(subtitle, style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 12)),
          ],
        ),
      ),
    );
  }

  void _handleSubscribe() {
    // TODO: When you have your Google Play Developer Account, you will replace this
    // with the actual in_app_purchase plugin logic.
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Google Play Billing will open here once your developer account is active.'),
      ),
    );
  }
}
