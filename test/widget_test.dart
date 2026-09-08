import 'package:flutter_test/flutter_test.dart';
import 'package:plant_growth/models/plant_species.dart';
import 'package:plant_growth/services/plant_repository.dart';

void main() {
  group('PlantSpecies', () {
    test('fromJson 完整解析', () {
      final p = PlantSpecies.fromJson(const {
        'id': 'sunflower',
        'name': '向日葵',
        'totalDays': 90,
        'videoUrl': 'https://cdn.example.com/a.mp4',
        'videoDurationMs': 18200,
        'sampleCount': 90,
        'frameWidth': 720,
        'coverUrl': 'https://cdn.example.com/a.jpg',
      });
      expect(p.id, 'sunflower');
      expect(p.totalDays, 90);
      expect(p.effectiveSampleCount, 90);
      expect(p.frameWidth, 720);
      expect(p.coverUrl, isNotNull);
    });

    test('fromJson 默认值与缺省字段', () {
      final p = PlantSpecies.fromJson(const {
        'id': 'bean',
        'name': '绿豆芽',
        'totalDays': 7,
        'videoUrl': 'x.mp4',
      });
      expect(p.sampleCount, isNull);
      expect(p.effectiveSampleCount, 7);
      expect(p.frameWidth, 720);
    });

    test('totalDays 非法时抛出 FormatException', () {
      expect(
        () => PlantSpecies.fromJson(const {
          'id': 'bad',
          'name': '坏数据',
          'totalDays': 0,
          'videoUrl': 'x.mp4',
        }),
        throwsFormatException,
      );
    });

    test('frameIndexForDay 首末天与单调递增', () {
      // 7 天 -> 7 帧
      final bean = PlantSpecies.fromJson(const {
        'id': 'bean',
        'name': '绿豆芽',
        'totalDays': 7,
        'videoUrl': 'x.mp4',
      });
      expect(bean.frameIndexForDay(1), 0);
      expect(bean.frameIndexForDay(7), 6);

      // 随天数推进，帧序号不回退
      var prev = -1;
      for (var d = 1; d <= 7; d++) {
        final idx = bean.frameIndexForDay(d);
        expect(idx, greaterThanOrEqualTo(prev));
        prev = idx;
      }
    });

    test('timeMsForDay 不越过视频末尾', () {
      final bean = PlantSpecies.fromJson(const {
        'id': 'bean',
        'name': '绿豆芽',
        'totalDays': 7,
        'videoUrl': 'x.mp4',
        'videoDurationMs': 10500,
      });
      for (var d = 1; d <= 7; d++) {
        final t = bean.timeMsForDay(d, 10500);
        expect(t, inInclusiveRange(0, 10500 - 1));
      }
    });
  });

  group('PlantConfig', () {
    const jsonObject = '''
    {
      "version": 1,
      "plants": [
        {"id": "a", "name": "A", "totalDays": 10, "videoUrl": "x.mp4"},
        {"id": "b", "name": "B", "totalDays": 20, "videoUrl": "y.mp4"}
      ]
    }
    ''';

    test('对象形式解析', () {
      final cfg = PlantConfig.fromJsonString(jsonObject);
      expect(cfg.version, 1);
      expect(cfg.plants.length, 2);
      expect(cfg.byId('b')?.name, 'B');
    });

    test('顶层数组形式兼容', () {
      final cfg = PlantConfig.fromJsonString('''
        [
          {"id": "c", "name": "C", "totalDays": 5, "videoUrl": "z.mp4"}
        ]
      ''');
      expect(cfg.plants.length, 1);
      expect(cfg.byId('c'), isNotNull);
    });
  });
}
