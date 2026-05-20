/// Centralized UI strings. All hardcoded text lives here, switched by
/// `auth.language` (`en` | `ur` | `roman_ur`). Add new keys here, never
/// inline a translated literal in a screen.
class T {
  final String lang;
  T(this.lang);

  String _pick(String en, String ru, String ur) => switch (lang) {
        'ur' => ur,
        'roman_ur' => ru,
        _ => en,
      };

  // ─── Top-level / brand ───
  String get appTagline => _pick(
        'Just tap — AI does everything',
        'Bas tap karo — AI sab kar dega',
        'بس ٹیپ کریں — AI سب کر دے گا',
      );

  // ─── Bottom nav ───
  String get navHome => _pick('Home', 'Home', 'ہوم');
  String get navBookings => _pick('Bookings', 'Bookings', 'بکنگز');
  String get navAskAi => _pick('Ask AI', 'Ask AI', 'AI سے پوچھیں');
  String get navInbox => _pick('Inbox', 'Inbox', 'انباکس');
  String get navProfile => _pick('Profile', 'Profile', 'پروفائل');
  String get navJobs => _pick('Jobs', 'Jobs', 'کام');
  String get navMessages => _pick('Messages', 'Messages', 'پیغامات');

  // ─── Home ───
  String get homePoweredByAi => _pick('Powered by AI', 'Powered by AI', 'AI سے چلتا ہے');
  String get homeHeroTitle => _pick(
        'What service\ndo you need today?',
        'Aaj aapko\nkya chahiye?',
        'آج آپ کو\nکیا چاہیے؟',
      );
  String get homeHeroSubtitle => _pick(
        'Speak or type in Urdu, Roman Urdu, or English.\nAI will find the right person.',
        'Urdu, Roman Urdu, ya English mein bolen ya likhen.\nAI sahi banda dhoond lega.',
        'اردو، رومن اردو، یا انگریزی میں بولیں یا لکھیں۔\nAI صحیح بندہ ڈھونڈ لے گا۔',
      );
  String get homeTapToAsk => _pick('Tap to ask', 'Bolo', 'بولیں');
  String get homeQuickServices => _pick('Quick services', 'Quick services', 'فوری سروسز');
  String get homeRecent => _pick('Recent', 'Recent', 'حال ہی میں');
  String get homeNoBookings => _pick(
        'No bookings yet — tap any service to start.',
        'Abhi koi booking nahin — koi service tap karein.',
        'ابھی کوئی بکنگ نہیں — کوئی سروس ٹیپ کریں۔',
      );

  // ─── Bookings tab ───
  String get bookingsTitle => _pick('Bookings', 'Bookings', 'بکنگز');
  String get bookingsEmptyTitle => _pick(
        'No bookings yet',
        'Abhi koi booking nahin',
        'ابھی کوئی بکنگ نہیں',
      );
  String get bookingsEmptySubtitle => _pick(
        'Tap the ✨ Ask AI button to book your first service.',
        '✨ Ask AI tap karein aur apni pehli service book karein.',
        'پہلی سروس بک کرنے کے لیے ✨ Ask AI پر ٹیپ کریں۔',
      );
  String get bookingsLoadFailed => _pick(
        'Could not load bookings',
        'Bookings load nahin ho saki',
        'بکنگز لوڈ نہیں ہو سکیں',
      );
  String get bookingsAskAi => _pick('Ask AI', 'Ask AI', 'AI سے پوچھیں');
  String get retry => _pick('Retry', 'Dobara', 'دوبارہ');

  // ─── Inbox tab ───
  String get inboxTitle => _pick('Inbox', 'Inbox', 'انباکس');
  String get inboxEmptyTitle => _pick(
        "You're all caught up",
        'Sab kuch dekha hua hai',
        'سب کچھ دیکھا ہوا ہے',
      );
  String get inboxEmptySubtitle => _pick(
        'Booking reminders & provider messages will land here.',
        'Booking reminders aur provider messages yahan aayenge.',
        'بکنگ یاددہانیاں اور پرووائڈر پیغامات یہاں آئیں گے۔',
      );
  String get inboxLoadFailed => _pick(
        'Could not load inbox',
        'Inbox load nahin ho saka',
        'انباکس لوڈ نہیں ہو سکا',
      );

  // ─── Profile tab ───
  String get profileTitle => _pick('Profile', 'Profile', 'پروفائل');
  String get profileCustomerMode => _pick('CUSTOMER MODE', 'CUSTOMER MODE', 'کسٹمر موڈ');
  String get profileProviderMode => _pick('PROVIDER MODE', 'PROVIDER MODE', 'پرووائڈر موڈ');
  String get profileSectionAccount => _pick('Account', 'Account', 'اکاؤنٹ');
  String get profileSectionApp => _pick('App', 'App', 'ایپ');
  String get profileLanguage => _pick('Language', 'Language', 'زبان');
  String get profileSavedAddresses => _pick('Saved addresses', 'Saved addresses', 'محفوظ پتے');
  String get profilePaymentMethods => _pick('Payment methods', 'Payment methods', 'ادائیگی کے طریقے');
  String get profileComingSoon => _pick('Coming soon', 'Aane wala hai', 'جلد آرہا ہے');
  String get profileNotifications => _pick('Notifications', 'Notifications', 'نوٹیفکیشنز');
  String get profileOn => _pick('On', 'On', 'آن');
  String get profileHelp => _pick('Help & support', 'Help & support', 'مدد اور سپورٹ');
  String get profileAbout => _pick('About TapKar AI', 'About TapKar AI', 'TapKar AI کے بارے میں');
  String get profileLogout => _pick('Log out', 'Log out', 'لاگ آؤٹ');
  String get profileLogoutTitle => _pick('Log out?', 'Log out karna hai?', 'لاگ آؤٹ کریں؟');
  String get profileLogoutSubtitle => _pick(
        'Your bookings will stay safe on the server. Log back in any time.',
        'Aap ki bookings server par safe rahengi. Kabhi bhi wapas log in kar sakte hain.',
        'آپ کی بکنگز سرور پر محفوظ رہیں گی۔ کبھی بھی واپس لاگ ان کر سکتے ہیں۔',
      );
  String get cancel => _pick('Cancel', 'Cancel', 'منسوخ');
  String get profileFooter => _pick(
        'Made for AI SEEKHO · Phase 2 · 2026',
        'Made for AI SEEKHO · Phase 2 · 2026',
        'Made for AI SEEKHO · Phase 2 · 2026',
      );

  // ─── Provider switch ───
  String get providerEarnTitle => _pick(
        'Earn as a provider',
        'Provider ban kar kamao',
        'پرووائڈر بن کر کمائیں',
      );
  String get providerEarnSubtitle => _pick(
        'Sign in as a provider to accept bookings on TapKar.',
        'Provider ban kar bookings accept karein TapKar par.',
        'TapKar پر بکنگز قبول کرنے کے لیے پرووائڈر بنیں۔',
      );
  String get providerSwitchTo => _pick('Switch to provider', 'Provider ban jao', 'پرووائڈر بنیں');
  String get providerSwitchBackTitle => _pick(
        'Switch back to customer',
        'Customer ban jao wapis',
        'واپس کسٹمر بنیں',
      );
  String get providerSwitchBackSubtitle => _pick(
        'Go back to booking services — your provider account stays linked.',
        'Wapas service book karne ke liye — aap ka provider account linked rahega.',
        'دوبارہ سروس بک کرنے کے لیے — آپ کا پرووائڈر اکاؤنٹ منسلک رہے گا۔',
      );
  String get providerSwitchBackCta => _pick(
        'Switch to customer mode',
        'Customer mode mein jao',
        'کسٹمر موڈ پر جائیں',
      );
  String get providerBadge => _pick('PROVIDER', 'PROVIDER', 'پرووائڈر');
  String get providerNoJobsTitle => _pick(
        'No incoming jobs',
        'Abhi koi job nahin',
        'ابھی کوئی کام نہیں',
      );
  String get providerNoJobsSubtitle => _pick(
        'When customers book your service, jobs will land here.\nTry booking yourself in customer mode to see the flow.',
        'Jab customer aap ki service book karenge, jobs yahan aayengi.\nCustomer mode mein khud book kar ke try karein.',
        'جب کسٹمر آپ کی سروس بک کریں گے، کام یہاں آئیں گے۔\nکسٹمر موڈ میں خود بک کر کے دیکھیں۔',
      );
  String get providerNoMessagesTitle => _pick(
        "You're all caught up",
        'Sab kuch dekha hua hai',
        'سب کچھ دیکھا ہوا ہے',
      );
  String get providerNoMessagesSubtitle => _pick(
        'Customer messages will appear here.',
        'Customer messages yahan aayenge.',
        'کسٹمر پیغامات یہاں نظر آئیں گے۔',
      );

  // ─── Chat / Ask AI ───
  String get chatInputHint => _pick(
        'Type or tap mic…',
        'Likhen ya mic tap karein…',
        'لکھیں یا مائیک ٹیپ کریں…',
      );
  String get agentTrace => _pick('Agent trace', 'Agent trace', 'ایجنٹ ٹریس');
}
