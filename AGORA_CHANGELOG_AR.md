# ملخص تعديلات Agora

- استبدال مسار الدخول من تطبيق Flutter إلى Jitsi/JaaS بمكالمة Agora RTC داخل التطبيق.
- إضافة شاشة `lib/screens/agora_meeting_room.dart` مع فيديو محلي وبعيد وأزرار الميكروفون والكاميرا والسماعة وإنهاء المكالمة.
- إضافة `agora_rtc_engine` و`permission_handler`.
- إضافة Firebase Callable Function باسم `getAgoraMeetingToken` إلى مجلد functions في المشروعين.
- الدالة تتحقق من المستخدم والمشاركة في المحاضرة والدفع والموعد، ثم تصدر توكن Agora لمدة ساعة.
- إضافة إعدادات سرية: `AGORA_APP_ID` كمتغير بيئة Functions، و`AGORA_APP_CERTIFICATE` كـ Firebase Secret.
- تمت إضافة `AGORA_SETUP_AR.md` لخطوات الإعداد والنشر.

تنبيه: لا يمكن اختبار الاتصال الفعلي قبل وضع بيانات مشروع Agora الصحيحة في Firebase Functions ونشر الدوال والتطبيق. وظائف تسجيل JaaS القديمة لا تتحول تلقائيًا إلى Agora Recording.
