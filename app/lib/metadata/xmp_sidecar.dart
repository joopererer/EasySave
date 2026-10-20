// Copyright 2026 EasySave. All rights reserved.
// XMP sidecar file (.xmp) reading and writing for video/audio files.

import 'dart:io';
import 'package:easysave/metadata/xmp_jpeg.dart';
import 'package:easysave/metadata/xmp_model.dart';

/// Reads XMP provenance from a sidecar .xmp file.
/// Returns null if the file does not exist or contains no valid XMP.
XmpProvenance? readSidecarXmp(File xmpFile) {
  if (!xmpFile.existsSync()) {
    return null;
  }

  final content = xmpFile.readAsStringSync();
  return parseXmpXml(content);
}

/// Writes XMP provenance to a sidecar .xmp file.
/// Creates or replaces the file.
void writeSidecarXmp(File xmpFile, XmpProvenance xmp) {
  final xmpXml = buildXmpXml(xmp);
  xmpFile.writeAsStringSync(xmpXml);
}
