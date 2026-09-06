import 'dart:convert';

/// Token 预估工具
///
/// 在请求发送前预估 Token 消耗，用于智能选择器判断剩余配额。
class TokenEstimator {
  /// 安全系数，避免低估
  static const double safetyFactor = 1.1;

  /// 每个字符平均 token 数（中文约 1.5-2 字符/token，英文约 3-4 字符/token）
  static const double charsPerToken = 3.5;

  /// 预估 Chat/Completion 请求的 token 消耗
  ///
  /// [body] 请求体 JSON 字符串
  /// [model] 模型名（用于特殊模型调整）
  static int estimateChatTokens(String body, {String model = ''}) {
    int total = 0;

    // 估算输入 token
    final inputTokens = _estimateInputTokens(body);
    total += inputTokens;

    // 估算输出 token（取 max_tokens 或默认值）
    final outputTokens = _estimateOutputTokens(body, model);
    total += outputTokens;

    // 乘以安全系数
    return (total * safetyFactor).round();
  }

  /// 预估 Embedding 请求的 token 消耗
  static int estimateEmbeddingTokens(String body) {
    final input = _extractInput(body);
    // 按字符数 / 4 估算
    final tokens = (input.length / charsPerToken).ceil();
    return (tokens * safetyFactor).round();
  }

  /// 从响应体提取实际 token 消耗
  static int extractActualTokens(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map) return 0;
      final usage = json['usage'];
      if (usage is Map) {
        final total = usage['total_tokens'];
        if (total is int) return total;
        // 也支持 prompt_tokens + completion_tokens
        final prompt = usage['prompt_tokens'] as int? ?? 0;
        final completion = usage['completion_tokens'] as int? ?? 0;
        if (prompt > 0 || completion > 0) return prompt + completion;
      }
    } catch (_) {}
    return 0;
  }

  /// 提取响应中的 completion_tokens（用于后续记账）
  static int extractCompletionTokens(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map) return 0;
      final usage = json['usage'];
      if (usage is Map) {
        return (usage['completion_tokens'] as int?) ?? 0;
      }
    } catch (_) {}
    return 0;
  }

  // ————————————————————————————————————————————
  // 内部实现
  // ————————————————————————————————————————————

  /// 估算输入 token 数
  static int _estimateInputTokens(String body) {
    final input = _extractInput(body);
    // 按字符数 / 3.5 估算
    return (input.length / charsPerToken).ceil();
  }

  /// 估算输出 token 数
  static int _estimateOutputTokens(String body, String model) {
    try {
      final json = jsonDecode(body);
      if (json is! Map) return 128; // 默认值

      // 优先取 max_tokens
      final maxTokens = json['max_tokens'];
      if (maxTokens is int && maxTokens > 0) {
        return maxTokens;
      }
      if (maxTokens is double && maxTokens > 0) {
        return maxTokens.round();
      }

      // 也支持 max_completion_tokens (O1 系列)
      final maxCompletionTokens = json['max_completion_tokens'];
      if (maxCompletionTokens is int && maxCompletionTokens > 0) {
        return maxCompletionTokens;
      }

      // 按模型默认值
      if (model.contains('o1') || model.contains('o3')) {
        return 4096;
      }
      return 1024; // 默认输出上限
    } catch (_) {
      return 128;
    }
  }

  /// 从请求体中提取用户输入文本
  static String _extractInput(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map) return '';

      // Chat: 提取 messages 中所有 content
      final messages = json['messages'];
      if (messages is List) {
        final sb = StringBuffer();
        for (final msg in messages) {
          if (msg is Map) {
            final content = msg['content'];
            if (content is String) {
              sb.write(content);
            } else if (content is List) {
              // 多模态消息：提取文本部分
              for (final part in content) {
                if (part is Map && part['type'] == 'text') {
                  sb.write(part['text'] as String? ?? '');
                }
              }
            }
          }
        }
        return sb.toString();
      }

      // Embedding: 提取 input
      final input = json['input'];
      if (input is String) return input;
      if (input is List) {
        return input.map((e) => e.toString()).join(' ');
      }

      return '';
    } catch (_) {
      return '';
    }
  }
}