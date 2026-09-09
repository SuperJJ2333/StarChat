import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/foundation/retained_image_cache_manager.dart';

class CachedImage extends Fake implements FileInfo {
  CachedImage(this.validTill);
  @override
  final DateTime validTill;
}

class UnusedFileSystem extends Fake implements FileSystem {}

class ExpiredLinkService extends FileService {
  @override
  Future<FileServiceResponse> get(String url,
          {Map<String, String>? headers}) async =>
      throw HttpExceptionWithStatus(404, 'Expired signed image link');
}

class TestCache extends RetainedImageCacheManager {
  TestCache(this.cached)
      : super(Config('retained-image-test',
            repo: NonStoringObjectProvider(),
            fileSystem: UnusedFileSystem(),
            fileService: ExpiredLinkService()));
  FileInfo? cached;
  FileInfo? replacement;
  int downloads = 0;
  bool removed = false;
  @override
  Future<FileInfo?> getFileFromCache(String key,
          {bool ignoreMemCache = false}) async =>
      cached;
  @override
  Future<FileInfo> downloadFile(String url,
      {String? key,
      Map<String, String>? authHeaders,
      bool force = false}) async {
    downloads++;
    if (replacement != null) return replacement!;
    throw HttpExceptionWithStatus(404, 'Expired signed image link');
  }

  @override
  Future<void> removeFile(String key) async {
    removed = true;
    cached = null;
  }
}

void main() {
  test('expired signed URL preserves an already cached image across entries',
      () async {
    final old = CachedImage(DateTime(2020));
    final cache = TestCache(old);
    addTearDown(cache.dispose);
    expect(await cache.getFileStream('https://example.test/expired').toList(),
        [old]);
    expect(cache.removed, isFalse);
    expect(await cache.getFileStream('https://example.test/expired').toList(),
        [old]);
  });
  test('cold missing image still reports the download failure', () async {
    final cache = TestCache(null);
    addTearDown(cache.dispose);
    await expectLater(cache.getFileStream('https://example.test/missing'),
        emitsError(isA<HttpExceptionWithStatus>()));
  });
  test('successful refresh emits old image before replacement', () async {
    final old = CachedImage(DateTime(2020));
    final next = CachedImage(DateTime(2100));
    final cache = TestCache(old)..replacement = next;
    addTearDown(cache.dispose);
    expect(await cache.getFileStream('https://example.test/fresh').toList(),
        [old, next]);
  });
  test('fresh cache does not request the image again', () async {
    final old = CachedImage(DateTime(2100));
    final cache = TestCache(old);
    addTearDown(cache.dispose);
    expect(await cache.getFileStream('https://example.test/image').toList(),
        [old]);
    expect(cache.downloads, 0);
  });
}
