import 'package:flutter_test/flutter_test.dart';

import 'package:pocket_inn/models/api_config.dart';

/// 供应商级自定义请求头：App 默认只发 `Accept` + `Authorization`，
/// 需要额外头的服务（如 OpenCode Go 的 `x-opencode-session`）此前完全不可用。
void main() {
  group('ApiConfig.customHeaders', () {
    test('从 JSON 解析（含旧配置缺字段的兼容）', () {
      final withHeaders = ApiConfig.fromJson({
        'id': 'p1',
        'name': 'Go',
        'baseUrl': 'https://opencode.ai/zen/go/v1',
        'apiKey': 'k',
        'models': <Object>[],
        'customHeaders': {'x-opencode-session': 'pocketinn'},
      });
      expect(withHeaders.customHeaders['x-opencode-session'], 'pocketinn');

      final legacy = ApiConfig.fromJson({
        'id': 'p2',
        'name': '老配置',
        'baseUrl': '',
        'apiKey': '',
        'models': <Object>[],
      });
      expect(legacy.customHeaders, isEmpty);
    });

    test('resolve() 把请求头透传给 ResolvedApiConfig', () {
      const config = ApiConfig(
        id: 'p1',
        name: 'Go',
        baseUrl: 'https://opencode.ai/zen/go/v1',
        apiKey: 'k',
        customHeaders: {'x-opencode-session': 'pocketinn'},
      );
      final resolved = config.resolve(
        const ApiModel(id: 'm1', modelId: 'deepseek-v4-flash', customBody: ''),
      );

      expect(resolved.customHeaders['x-opencode-session'], 'pocketinn');
      expect(resolved.model, 'deepseek-v4-flash');
    });

    test('copyWith 可独立替换请求头', () {
      const config = ApiConfig(id: 'p1', name: 'n', baseUrl: '', apiKey: '');
      final updated = config.copyWith(
        customHeaders: const {'x-opencode-session': 'abc'},
      );

      expect(updated.customHeaders['x-opencode-session'], 'abc');
      expect(updated.name, 'n');
      expect(config.customHeaders, isEmpty);
    });
  });
}
