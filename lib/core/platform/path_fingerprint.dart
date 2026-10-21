/// 62-bit FNV-1a fingerprint of a normalized path key.
///
/// Storing full lowercase keys for a million results costs ~100 MiB per set;
/// a masked fingerprint stays a Smi on the VM, and the collision probability
/// at one million items is about 1e-7.
int pathFingerprint(String key) {
  var hash = 0xcbf29ce484222325;
  for (var index = 0; index < key.length; index++) {
    final code = key.codeUnitAt(index);
    hash = (hash ^ (code & 0xff)) * 0x100000001b3;
    hash = (hash ^ (code >> 8)) * 0x100000001b3;
  }
  return hash & 0x3fffffffffffffff;
}
