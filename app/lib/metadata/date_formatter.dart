// Copyright 2026 EasySave. All rights reserved.
// Date/time formatting utilities for provenance metadata.
// All dates in XMP must be in ISO 8601 format with timezone per SPEC §5.

/// Formats a DateTime to ISO 8601 string with timezone.
/// Uses the local timezone offset (e.g., +02:00 for Central European Time).
/// This is required by SPEC §5 for all provenance date fields.
String formatDateTimeWithTimezone(DateTime dt) {
  // Ensure we have timezone information
  final local = dt.toLocal();
  
  // Calculate timezone offset
  final offset = local.timeZoneOffset;
  final hours = offset.inHours.abs();
  final minutes = (offset.inMinutes.abs() % 60);
  final sign = offset.isNegative ? '-' : '+';
  
  // Format: 2026-10-21T02:12:48+02:00
  final datePart = '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  final timePart = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}';
  
  return '$datePart\T$timePart$sign${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}';
}

/// Formats a DateTime to ISO 8601 UTC string (with Z suffix).
/// Use this when the original timestamp has no timezone info and should be
/// stored as UTC per SPEC §2.2.
String formatDateTimeUtc(DateTime dt) {
  final utc = dt.toUtc();
  return '${utc.year}-${utc.month.toString().padLeft(2, '0')}-${utc.day.toString().padLeft(2, '0')}T'
         '${utc.hour.toString().padLeft(2, '0')}:${utc.minute.toString().padLeft(2, '0')}:'
         '${utc.second.toString().padLeft(2, '0')}Z';
}
