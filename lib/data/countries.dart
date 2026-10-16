/// قائمة الدول وأطوال الأرقام (نفس قائمة منصة الويب).
class Country {
  final String code, name, flag, iso;
  final int length;
  final List<String> start;
  const Country(this.code, this.name, this.flag, this.length, this.start, this.iso);
}

const List<Country> kCountries = [
  Country('962', 'الأردن', '🇯🇴', 9, ['7'], 'JO'),
  Country('971', 'الإمارات', '🇦🇪', 9, ['5'], 'AE'),
  Country('973', 'البحرين', '🇧🇭', 8, ['3', '6'], 'BH'),
  Country('213', 'الجزائر', '🇩🇿', 9, ['5', '6', '7'], 'DZ'),
  Country('249', 'السودان', '🇸🇩', 9, ['9', '1'], 'SD'),
  Country('966', 'السعودية', '🇸🇦', 9, ['5'], 'SA'),
  Country('252', 'الصومال', '🇸🇴', 9, [], 'SO'),
  Country('964', 'العراق', '🇮🇶', 10, ['7'], 'IQ'),
  Country('965', 'الكويت', '🇰🇼', 8, ['5', '6', '9'], 'KW'),
  Country('212', 'المغرب', '🇲🇦', 9, ['6', '7'], 'MA'),
  Country('967', 'اليمن', '🇾🇪', 9, ['7'], 'YE'),
  Country('216', 'تونس', '🇹🇳', 8, ['2', '4', '5', '9'], 'TN'),
  Country('269', 'جزر القمر', '🇰🇲', 7, [], 'KM'),
  Country('253', 'جيبوتي', '🇩🇯', 8, [], 'DJ'),
  Country('963', 'سوريا', '🇸🇾', 9, ['9'], 'SY'),
  Country('968', 'عمان', '🇴🇲', 8, ['7', '9'], 'OM'),
  Country('970', 'فلسطين', '🇵🇸', 9, ['5'], 'PS'),
  Country('974', 'قطر', '🇶🇦', 8, ['3', '5', '6', '7'], 'QA'),
  Country('961', 'لبنان', '🇱🇧', 8, ['3', '7', '8'], 'LB'),
  Country('218', 'ليبيا', '🇱🇾', 9, ['9'], 'LY'),
  Country('20', 'مصر', '🇪🇬', 10, ['10', '11', '12', '15'], 'EG'),
  Country('222', 'موريتانيا', '🇲🇷', 8, ['2', '3', '4'], 'MR'),
  Country('1', 'أمريكا', '🇺🇸', 10, [], 'US'),
  Country('44', 'بريطانيا', '🇬🇧', 10, [], 'GB'),
  Country('90', 'تركيا', '🇹🇷', 10, ['5'], 'TR'),
  Country('33', 'فرنسا', '🇫🇷', 9, ['6', '7'], 'FR'),
  Country('49', 'ألمانيا', '🇩🇪', 11, ['1'], 'DE'),
];

/// يرجّع null لو الرقم صحيح، وإلا رسالة الخطأ (نفس قواعد الويب).
String? validatePhone(Country c, String num) {
  if (num.length != c.length) return 'في ${c.name}، يجب أن يتكون الرقم من ${c.length} أرقام بالضبط.';
  if (c.start.isNotEmpty && !c.start.any(num.startsWith)) {
    return 'في ${c.name}، يجب أن يبدأ الرقم بـ: ${c.start.join(' أو ')}.';
  }
  return null;
}
