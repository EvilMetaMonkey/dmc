import 'package:path/path.dart' as p;

const int binaryProbeBytes = 1024;
const Set<String> knownBinaryExtensions = {
  '.exe',
  '.dll',
  '.so',
  '.dylib',
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
  '.ico',
  '.pdf',
  '.zip',
  '.tar',
  '.gz',
  '.7z',
  '.mp3',
  '.mp4',
  '.mov',
  '.avi',
  '.woff',
  '.woff2',
  '.ttf',
  '.otf',
  '.sqlite',
  '.db',
};

bool hasKnownBinaryExtension(String path) =>
    knownBinaryExtensions.contains(p.extension(path).toLowerCase());

bool hasBinaryProbe(List<int> bytes) =>
    bytes.take(binaryProbeBytes).contains(0);
