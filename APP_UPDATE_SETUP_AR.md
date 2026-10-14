# ربط شاشة التحديث في تطبيق Flutter

## 1) الحزم (pubspec.yaml → dependencies)
```yaml
  package_info_plus: ^8.0.0
  ota_update: ^6.0.0        # تنزيل الـ APK وتثبيته مع نسبة التقدم
  device_info_plus: ^10.1.0 # لمعرفة معمارية الجهاز واختيار الـ APK المناسب
  url_launcher: ^6.2.0      # بديل: فتح رابط التنزيل في المتصفح
  cloud_functions: ^5.0.0   # لو غير موجودة (أو استخدم نفس طريقة استدعاء /api/fn المستخدمة في المشروع)
```
وسجّل اللوجو: `assets/images/logo.png` (أو غيّر المسار داخل app_update_screen.dart).

## 2) AndroidManifest.xml
```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>
```
(ota_update يضيف الـ FileProvider تلقائيًا؛ راجع README الحزمة لو ظهر خطأ في الـ build.)

## 3) تغليف التطبيق بالبوابة (lib/main.dart)
```dart
import 'widgets/update_gate.dart';
// داخل MaterialApp.router:
builder: (context, child) => UpdateGate(child: child ?? const SizedBox()),
```

## 4) استدعاء دالة التنزيل
`AppUpdateService.downloadUrl` تستدعي `getAppUpdateDownloadUrl`. لو تطبيقك يستدعي دوال المنصة عبر
`https://www.fahemt.online/api/fn/<name>` (مثل باقي الدوال) استبدل الاستدعاء بنفس الدالة المساعدة الموجودة في
`services/api_functions.dart` — الدالة لا تحتاج تسجيل دخول.

## 5) رقم الإصدار
التطبيق يقارن رقم الـ build (الرقم بعد `+` في `version: 1.0.0+5` داخل pubspec.yaml) مع «رقم الإصدار» الذي تكتبه في لوحة التحكم.
عند إصدار APK جديد ارفع رقم الـ build في pubspec ثم اكتب نفس الرقم في صفحة «تحديثات التطبيق».
