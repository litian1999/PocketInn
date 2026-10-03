import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pocket_inn/models/chat_variables.dart';
import 'package:pocket_inn/services/status_extraction_service.dart';
import 'package:pocket_inn/services/storage_service.dart';

import 'helpers/test_env.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = setUpPathProviderMocks();
    SharedPreferences.setMockInitialValues({});
    await StorageService.instance.initialize();
  });

  tearDownAll(() async {
    tearDownPathProviderMocks(tempDir);
  });

  group('parseVariableOps 容错解析', () {
    test('标准 JSON 输出', () {
      final ops = parseVariableOps(
        '{"ops": [{"op": "add", "var": "好感度", "value": 5, "reason": "帮忙"},'
        ' {"op": "set", "var": "心情", "value": "开心"}]}',
      );
      expect(ops.length, 2);
      expect(ops[0].kind, VariableOpKind.add);
      expect(ops[0].variable, '好感度');
      expect(ops[0].value, '5');
      expect(ops[1].kind, VariableOpKind.set);
      expect(ops[1].value, '开心');
    });

    test('剥离 Markdown 围栏与杂文', () {
      final ops = parseVariableOps(
        '好的，以下是变化：\n```json\n{"ops": [{"op": "add", "var": "金币", "value": -3}]}\n```\n以上。',
      );
      expect(ops.length, 1);
      expect(ops[0].value, '-3');
    });

    test('接受裸数组输出', () {
      final ops = parseVariableOps('[{"op": "set", "name": "状态", "value": "疲惫"}]');
      expect(ops.length, 1);
      expect(ops[0].variable, '状态');
    });

    test('空 ops 与无变化输出', () {
      expect(parseVariableOps('{"ops": []}'), isEmpty);
      expect(parseVariableOps('没有发生变化。'), isEmpty);
      expect(parseVariableOps(''), isEmpty);
    });

    test('非法条目被过滤，其余保留', () {
      final ops = parseVariableOps(
        '{"ops": [{"op": "unknown", "var": "x", "value": 1},'
        ' {"op": "set", "var": "金币", "value": 9},'
        ' {"op": "add", "var": "", "value": 1}]}',
      );
      expect(ops.length, 1);
      expect(ops[0].variable, '金币');
    });

    test('JSON 前的孤立花括号不干扰解析', () {
      final ops = parseVariableOps(
        '变量{1}保持不变。真正的输出：{"ops": [{"op": "add", "var": "好感度", "value": 1}]}',
      );
      expect(ops.length, 1);
      expect(ops[0].variable, '好感度');
    });
  });

  group('buildStatusExtractionPrompt', () {
    VariableState stateWithHint() => VariableState.fromVariables({
      '好感度': const ChatVariable(
        name: '好感度',
        type: ChatVariableType.number,
        value: '10',
        metadata: ChatVariableMetadata(minValue: 0, maxValue: 100),
        changeHint: '帮她做事 +5，被冷落 -3',
      ),
      '心情': const ChatVariable(
        name: '心情',
        type: ChatVariableType.enumType,
        value: '平静',
        metadata: ChatVariableMetadata(enumOptions: ['平静', '心动']),
      ),
    });

    test('注入变量状态、约束与变化说明', () {
      final prompt = buildStatusExtractionPrompt(state: stateWithHint());

      expect(prompt, contains('"好感度": "10"'));
      expect(prompt, contains('"心情": "平静"'));
      expect(prompt, contains('数值范围（越界会被钳制）：好感度 0~100'));
      expect(prompt, contains('枚举取值（仅允许下列选项）：心情 平静/心动'));
      expect(prompt, contains('变量变化说明'));
      expect(prompt, contains('好感度：帮她做事 +5，被冷落 -3'));
    });

    test('无变化说明时不追加该段落', () {
      final prompt = buildStatusExtractionPrompt(
        state: VariableState.fromVariables({
          '好感度': const ChatVariable(
            name: '好感度',
            type: ChatVariableType.number,
            value: '10',
          ),
        }),
      );

      expect(prompt, isNot(contains('变量变化说明')));
    });

    test('自定义提示词同样把约束排到 {{state}} 之前（前缀缓存友好）', () {
      final prompt = buildStatusExtractionPrompt(
        state: stateWithHint(),
        customPrompt: '只输出 JSON。当前 {{state}}',
      );

      // ★ 这条断言曾经反过来（要求状态 JSON 紧跟自定义词），
      //   等于把"自定义词拿不到前缀缓存"这个缺陷固化成了规范。
      //   实测（真实 DeepSeek·自定义词 597 字+约束段）：被挡住时命中 0%，
      //   走同一段排布算法后命中 68%。内容一字不差，只是顺序不同。
      final stateIndex = prompt.indexOf('"好感度": "10"');
      expect(stateIndex, greaterThan(0), reason: '状态 JSON 应被注入');
      expect(prompt.indexOf('只输出 JSON。'), lessThan(stateIndex));
      expect(prompt.indexOf('好感度：帮她做事 +5，被冷落 -3'), lessThan(stateIndex),
          reason: '约束段必须排在每轮都会变的状态之前');
      // 状态之后不再有固定段落
      expect(prompt.substring(stateIndex), isNot(contains('好感度：帮她做事 +5，被冷落 -3')));
    });

    test('自定义提示词里没有 {{state}} 时兜底追加', () {
      final prompt = buildStatusExtractionPrompt(
        state: stateWithHint(),
        customPrompt: '只输出 JSON。',
      );

      expect(prompt, startsWith('只输出 JSON。'));
      expect(prompt, contains('好感度：帮她做事 +5，被冷落 -3'));
      // 没有标记 → 状态只能落在最后
      expect(prompt.indexOf('"好感度": "10"'),
          greaterThan(prompt.indexOf('好感度：帮她做事 +5，被冷落 -3')));
    });

    test('内置默认把状态 JSON 放在最后（前缀缓存友好）', () {
      final prompt = buildStatusExtractionPrompt(state: stateWithHint());
      final stateIndex = prompt.indexOf('"好感度": "10"');

      expect(stateIndex, greaterThan(0), reason: '状态 JSON 应被注入');
      // 约束与变化说明都必须排在状态之前，否则每轮都会变的状态会作废它们
      expect(prompt.indexOf('数值范围'), lessThan(stateIndex));
      expect(prompt.indexOf('变量变化说明'), lessThan(stateIndex));
      expect(prompt.indexOf('当前状态变量（JSON）：'), lessThan(stateIndex));
      // 状态之后不再有别的段落
      expect(prompt.substring(stateIndex), isNot(contains('数值范围')));
      expect(prompt.substring(stateIndex), isNot(contains('变量变化说明')));
    });
  });

  group('StatusExtractionConfig', () {
    test('默认间隔为 1（与加入「提取间隔」之前的行为一致）', () {
      const config = StatusExtractionConfig();
      expect(config.interval, 1);
      expect(config.copyWith(interval: 5).interval, 5);
    });

    test('copyWith 不改动未传入的字段', () {
      const config = StatusExtractionConfig(
        enabled: true,
        recentMessages: 8,
        interval: 3,
      );
      final next = config.copyWith(interval: 2);

      expect(next.enabled, isTrue);
      expect(next.recentMessages, 8);
      expect(next.interval, 2);
    });
  });

  group('applyCardChangeHints', () {
    final state = VariableState.fromVariables({
      '好感度': const ChatVariable(
        name: '好感度',
        type: ChatVariableType.number,
        value: '10',
        changeHint: '旧说明',
      ),
      '心情': const ChatVariable(
        name: '心情',
        type: ChatVariableType.text,
        value: '平静',
        changeHint: '卡未声明，保留',
      ),
    });

    test('用角色卡声明覆盖同名说明，且不改动取值', () {
      final merged = applyCardChangeHints(state, {
        'data': {
          'extensions': {
            'variables': {
              '好感度': {
                'type': 'number',
                'value': '0',
                'changeHint': '新说明',
              },
            },
          },
        },
      });

      expect(merged['好感度']?.changeHint, '新说明');
      expect(merged['好感度']?.value, '10');
      expect(merged['心情']?.changeHint, '卡未声明，保留');
    });

    test('卡中变量未声明说明时清空旧说明', () {
      final merged = applyCardChangeHints(state, {
        'data': {
          'extensions': {
            'variables': {
              '好感度': {'type': 'number', 'value': '0'},
            },
          },
        },
      });

      expect(merged['好感度']?.changeHint, isNull);
    });

    test('空卡或无声明时原样返回', () {
      expect(applyCardChangeHints(state, {}), same(state));
      expect(
        applyCardChangeHints(state, {'data': {'extensions': {}}}),
        same(state),
      );
    });
  });

  group('StatusExtractionConfig', () {
    test('默认关闭，条数被钳制到合法区间', () {
      expect(statusExtractionNotifier.value.enabled, isFalse);

      updateStatusExtractionConfig(
        enabled: true,
        recentMessages: 999,
        extractionModelId: 'model-a',
      );
      var config = statusExtractionNotifier.value;
      expect(config.enabled, isTrue);
      expect(
        config.recentMessages,
        kStatusExtractionRecentMessagesMax,
      );
      expect(config.extractionModelId, 'model-a');

      updateStatusExtractionConfig(recentMessages: -5);
      expect(
        statusExtractionNotifier.value.recentMessages,
        kStatusExtractionRecentMessagesMin,
      );
    });

    test('配置持久化与重新加载往返', () async {
      updateStatusExtractionConfig(
        enabled: true,
        recentMessages: 12,
        customPrompt: '自定义 {{state}}',
      );

      // 模拟应用重启：重置为默认后从持久化加载。
      statusExtractionNotifier.value = const StatusExtractionConfig();
      await initializeStatusExtractionConfig();

      final config = statusExtractionNotifier.value;
      expect(config.enabled, isTrue);
      expect(config.recentMessages, 12);
      expect(config.customPrompt, '自定义 {{state}}');
    });

    tearDown(() {
      updateStatusExtractionConfig(
        enabled: false,
        extractionModelId: null,
        recentMessages: 6,
        customPrompt: '',
      );
    });
  });
}
