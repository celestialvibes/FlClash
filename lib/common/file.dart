import 'dart:io';

extension FileExt on File {
  Future<void> writeValidatedBytes(
    List<int> bytes, {
    required Future<String> Function(String path) validate,
  }) async {
    await parent.create(recursive: true);
    final staging = await parent.createTemp('.profile-');
    try {
      final pending = File('${staging.path}/config.yaml');
      await pending.writeAsBytes(bytes, flush: true);
      final message = await validate(pending.path);
      if (message.isNotEmpty) throw message;
      await pending.rename(path);
    } finally {
      await staging.delete(recursive: true);
    }
  }

  Future<void> safeCopy(String newPath) async {
    if (!await exists()) {
      await create(recursive: true);
      return;
    }
    final targetFile = File(newPath);
    if (!await targetFile.exists()) {
      await targetFile.create(recursive: true);
    }
    await copy(newPath);
  }

  Future<File> safeWriteAsString(String str) async {
    if (!await exists()) {
      await create(recursive: true);
    }
    return writeAsString(str);
  }

  Future<File> safeWriteAsBytes(List<int> bytes) async {
    if (!await exists()) {
      await create(recursive: true);
    }
    return writeAsBytes(bytes);
  }
}

extension FileSystemEntityExt on FileSystemEntity {
  Future<void> safeDelete({bool recursive = false}) async {
    if (!await exists()) {
      return;
    }
    await delete(recursive: recursive);
  }
}
