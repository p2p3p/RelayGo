import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:relaygo/app.dart';
import 'package:relaygo/config/constants.dart';
import 'package:relaygo/database/database_helper.dart';
import 'package:relaygo/utils/encryption.dart';

/// 写入启动诊断日志（纯 logcat，零磁盘 IO，不阻塞首帧）
void _diagLog(String msg) {
  // ignore: avoid_print
  print('[RelayGo_diag] ${DateTime.now().toIso8601String()} $msg');
}

/// 显示错误页面（即使日志写不了，屏幕上也能看到）
void _showError(String title, dynamic e, [StackTrace? s]) {
  _diagLog('$title: $e\n$s');
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40),
              const Text('RelayGo 启动诊断',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              Text(title,
                  style: const TextStyle(fontSize: 16, color: Colors.red, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5F5F5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      '$e\n\n${s ?? ''}',
                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  ));
}

/// 通过 MethodChannel 通知 Kotlin 层 Dart 代码执行进度
/// （绕过文件写入，直接用 Kotlin 的 diagLog 输出到 logcat+文件）
void _nativeDiag(String msg) {
  try {
    const MethodChannel('relaygo/diag')
        .invokeMethod<bool>('diag', {'msg': msg});
  } catch (_) {}
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  _nativeDiag('DART_MAIN_START');
  _diagLog('=== main() start ===');

  try {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.white,
        statusBarIconBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
    );
    _diagLog('SystemChrome OK');
    _nativeDiag('DART_SYSTEMCHROME_OK');
  } catch (e, s) {
    _diagLog('SystemChrome ERROR: $e\n$s');
  }

  // 数据库初始化
  try {
    _diagLog('DatabaseHelper.init() start');
    await DatabaseHelper.init();
    _diagLog('DatabaseHelper.init() done');
    _nativeDiag('DART_DB_OK');
  } catch (e, s) {
    _showError('数据库初始化失败', e, s);
    return;
  }

  // 主密钥
  try {
    _diagLog('masterKey start');
    final vault = DatabaseHelper.vault;
    String masterKey;
    if (vault.containsKey(Constants.masterKeyName)) {
      masterKey = vault.get(Constants.masterKeyName) as String;
    } else {
      masterKey = EncryptionUtil.generateMasterKeyBase64();
      await vault.put(Constants.masterKeyName, masterKey);
    }
    EncryptionUtil.init(masterKey);
    _diagLog('masterKey done');
    _nativeDiag('DART_MASTERKEY_OK');
  } catch (e, s) {
    _showError('密钥初始化失败', e, s);
    return;
  }

  // 启动 App
  try {
    _diagLog('runApp() start');
    // 捕获 Flutter framework 级别的错误
    FlutterError.onError = (details) {
      _diagLog('FlutterError: ${details.exception}\n${details.stack}');
    };
    runApp(const MyApp());
    _diagLog('runApp() done');
    _nativeDiag('DART_RUNAPP_DONE');
  } catch (e, s) {
    _showError('应用启动失败', e, s);
  }
}
