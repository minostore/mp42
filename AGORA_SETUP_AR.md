# إعداد Agora RTC لمحاضرات فهمني

## 1) إعدادات Firebase Functions
الدالة `getAgoraMeetingToken` تعمل داخل Firebase Functions (وليس متغيرات Vercel وحدها) وتتحقق من تسجيل الدخول، وعضوية المستخدم في المحاضرة، وحالة الدفع والموعد قبل إصدار التوكن.

1. أضف `AGORA_APP_ID` إلى ملف `functions/.env.<FIREBASE_PROJECT_ID>` (معرّف المشروع الحقيقي في Firebase):
   ```
   AGORA_APP_ID=ضع_هنا_App_ID
   ```
2. خزّن الشهادة كـ Secret، ولا تضعها في التطبيق أو Git:
   ```
   firebase functions:secrets:set AGORA_APP_CERTIFICATE
   ```
   ألصق قيمة Primary Certificate عند مطالبتك بها.
3. من جذر المشروع، ثبّت تبعيات الدوال وانشرها:
   ```
   cd functions
   npm install
   cd ..
   firebase deploy --only functions
   ```
   تأكد أن المشروع النشط في Firebase هو المشروع الصحيح قبل النشر.

## 2) تطبيق Flutter
التطبيق يستخدم `agora_rtc_engine`، ويطلب إذن الكاميرا والميكروفون عند دخول المحاضرة. لا يحتاج التطبيق إلى App Certificate؛ يحصل على توكن قصير الصلاحية من `getAgoraMeetingToken`.

## 3) ملاحظات
- استخدم App ID وPrimary Certificate من مشروع Agora نفسه.
- App Certificate سرّ حساس؛ لا تضفه إلى GitHub أو إعدادات Flutter أو ملف APK.
- هذه التعديلات تستبدل تشغيل الاجتماع داخل التطبيق بـ Agora RTC. وظائف التسجيل القديمة المرتبطة بـ JaaS لا تنتقل تلقائيًا إلى Agora وتحتاج إعداد تسجيل منفصل إذا كانت مطلوبة.
