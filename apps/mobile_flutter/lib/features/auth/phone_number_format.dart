/// Returns a canonical mainland mobile number for authentication requests.
/// Formatting characters and the optional country code are accepted in the UI.
String? normalizeMainlandPhone(String raw) {
  var value = raw.replaceAll(RegExp(r'[ \-\(\)]'), '');
  if (value.startsWith('+86')) {
    value = value.substring(3);
  } else if (value.startsWith('86') && value.length == 13) {
    value = value.substring(2);
  }
  return RegExp(r'^1[3-9][0-9]{9}$').hasMatch(value) ? value : null;
}
