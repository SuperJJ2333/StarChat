import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_media_shared_logic.dart';

/// 规格 #7/#8/#9 共享逻辑。
void main() {
  group('#7 月历', () {
    test('月导航与标题', () {
      const m = CalendarMonth(2026, 9);
      expect(m.title, '2026年9月');
      expect(m.previous, const CalendarMonth(2026, 8));
      expect(m.next, const CalendarMonth(2026, 10));
      expect(const CalendarMonth(2026, 1).previous, const CalendarMonth(2025, 12));
      expect(const CalendarMonth(2026, 12).next, const CalendarMonth(2027, 1));
      expect(m.daysInMonth, 30);
      expect(m.firstWeekdayMondayBased, DateTime(2026, 9, 1).weekday,
          reason: '周一开头排列');
    });

    test('验收：仅 1、3、10 日有消息，其余灰显禁用；扫描中日为独立状态',
        () {
      final withMessages = {
        DateTime(2026, 9, 1),
        DateTime(2026, 9, 3),
        DateTime(2026, 9, 10),
      };
      final scanning = <DateTime>{DateTime(2026, 9, 20)};
      for (var day = 1; day <= 30; day++) {
        final date = DateTime(2026, 9, day);
        final status = dayStatus(date,
            datesWithMessages: withMessages, scanningDates: scanning);
        if (withMessages.contains(date)) {
          expect(status, CalendarDayStatus.hasMessages);
        } else if (scanning.contains(date)) {
          expect(status, CalendarDayStatus.scanning,
              reason: '扫描中不得冒充无消息');
        } else {
          expect(status, CalendarDayStatus.noMessages,
              reason: '确认无消息才禁用灰显');
        }
      }
    });

    test('点击 9 月 3 日定位当天最早一条（非最后一条）', () {
      final dayMessages = <({String id, int order})>[
        (id: 'late', order: 103),
        (id: 'early', order: 101),
        (id: 'mid', order: 102),
      ];
      final earliest =
          earliestMessageOfDay(dayMessages, (m) => m.order);
      expect(earliest!.id, 'early');
    });

    test('月份导航限制在最早与最新可访问月份之间', () {
      const earliest = CalendarMonth(2025, 6);
      const latest = CalendarMonth(2026, 11);
      expect(
          const CalendarMonth(2026, 9).canNavigateTo(
              const CalendarMonth(2026, 9),
              earliest: earliest,
              latest: latest),
          isTrue);
      expect(
          const CalendarMonth(2025, 5).canNavigateTo(
              const CalendarMonth(2025, 5),
              earliest: earliest,
              latest: latest),
          isFalse);
      expect(
          const CalendarMonth(2026, 12).canNavigateTo(
              const CalendarMonth(2026, 12),
              earliest: earliest,
              latest: latest),
          isFalse);
      // 中间整月无消息可展示（月份本身可导航，日期由状态灰显）。
      expect(
          const CalendarMonth(2025, 7).canNavigateTo(
              const CalendarMonth(2025, 7),
              earliest: earliest,
              latest: latest),
          isTrue);
    });

    test('零点附近时间归当日（设备时区）', () {
      expect(calendarDayOf(DateTime(2026, 9, 3, 0, 0, 1)),
          DateTime(2026, 9, 3));
      expect(calendarDayOf(DateTime(2026, 9, 3, 23, 59, 59)),
          DateTime(2026, 9, 3));
    });
  });

  group('#8 链接与文件回退', () {
    test('解析 HTTP/HTTPS；同消息相同 URL 去重', () {
      const body = '看 https://a.test/x 和 http://b.test/y 再 https://a.test/x';
      final urls = dedupeUrlsInMessage(extractHttpLinks(body));
      expect(urls.map((u) => u.toString()).toList(),
          ['https://a.test/x', 'http://b.test/y']);
    });

    test('预览元数据缺失：域名作标题、URL 作摘要、无缩略图', () {
      final link = LinkPreviewModel(url: Uri.parse('https://news.example.test/article/12345?utm=x'));
      expect(link.displayTitle, 'news.example.test');
      expect(link.displaySummary, link.url.toString());
      expect(link.thumbnailUrl, isNull);
    });

    test('预览元数据存在：展示自带标题/摘要', () {
      final link = LinkPreviewModel(
        url: Uri.parse('https://x.test/1'),
        title: '标题',
        summary: '摘要',
      );
      expect(link.displayTitle, '标题');
      expect(link.displaySummary, '摘要');
    });

    test('文件名/大小未知不伪造', () {
      expect(FileDisplayFallback.fileName(null), '未命名文件');
      expect(FileDisplayFallback.fileName('  '), '未命名文件');
      expect(FileDisplayFallback.fileName('报告.pdf'), '报告.pdf');
      expect(FileDisplayFallback.sizeLabel(null), '大小未知');
      expect(FileDisplayFallback.sizeLabel(-1), '大小未知');
      expect(FileDisplayFallback.sizeLabel(512), '512 B');
      expect(FileDisplayFallback.sizeLabel(2048), '2.0 KB');
      expect(FileDisplayFallback.sizeLabel(5 * 1024 * 1024), '5.0 MB');
    });
  });

  group('#9 GIF 识别与门控', () {
    test('.jpg 扩展名但真实内容 GIF（多帧）→ 动画', () {
      final format = classifyImageFormat(
        signatureIsGif: true,
        frameCount: 12,
      );
      expect(format, DecodedImageFormat.gifAnimated);
    });

    test('单帧 GIF → 静态图', () {
      expect(
        classifyImageFormat(signatureIsGif: true, frameCount: 1),
        DecodedImageFormat.gifSingleFrame,
      );
    });

    test('非 GIF 由解码器格式判定', () {
      expect(
        classifyImageFormat(
            signatureIsGif: false, frameCount: 1, codecFormat: DecodedImageFormat.png),
        DecodedImageFormat.png,
      );
    });

    test('门控：离屏/后台/非当前画廊页/自动播放关闭/未获准下载 → 暂停或手动',
        () {
      bool play({
        bool auto = true,
        bool download = true,
        bool visible = true,
        bool foreground = true,
        bool galleryCurrent = true,
      }) =>
          shouldPlayGif(
            autoPlayEnabled: auto,
            mediaDownloadAllowed: download,
            isVisiblyOnScreen: visible,
            appInForeground: foreground,
            isCurrentGalleryPage: galleryCurrent,
          );

      expect(play(), isTrue);
      expect(play(auto: false), isFalse, reason: '自动播放关闭→播放按钮');
      expect(play(download: false), isFalse, reason: '未获准下载→点击加载');
      expect(play(visible: false), isFalse, reason: '离屏暂停（不持续解码）');
      expect(play(foreground: false), isFalse, reason: '后台暂停');
      expect(play(galleryCurrent: false), isFalse, reason: '画廊滑到其他页暂停');
    });

    test('遵循自带循环：有限循环不强制无限', () {
      const plan = GifPlaybackPlan(
          frameDelays: [40, 60, 80],
          repetitionMode: GifRepetitionMode.finite,
          finiteLoops: 2);
      expect(plan.frameCount, 3);
      expect(plan.loops, 2, reason: '播 2 轮后停，不改无限');
      const infinite =
          GifPlaybackPlan(frameDelays: [40], repetitionMode: GifRepetitionMode.infinite);
      expect(infinite.loops, isNull);
    });
  });
}
