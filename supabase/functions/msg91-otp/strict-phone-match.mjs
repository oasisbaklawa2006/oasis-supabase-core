// Strict whole-number comparison after removing formatting, with an explicit India country-code policy.
// Never accept a matching suffix embedded in a longer phone number.
export function canonicalIndianPhone(raw) {
  if (typeof raw !== "string") return null;
  const digits = raw.replace(/\D/g, "");
  if (digits.length === 10 && /^[6-9]/.test(digits)) return `91${digits}`;
  if (digits.length === 11 && digits.startsWith("0") && /^[6-9]/.test(digits.slice(1))) return `91${digits.slice(1)}`;
  if (digits.length === 12 && digits.startsWith("91") && /^[6-9]/.test(digits.slice(2))) return digits;
  return null;
}
export function phoneEquals(candidate, verified) {
  const expected = canonicalIndianPhone(verified);
  return expected !== null && canonicalIndianPhone(candidate) === expected;
}
export function anyPhoneEquals(values, verified) {
  return Array.isArray(values) && values.some((value) => phoneEquals(value, verified));
}
