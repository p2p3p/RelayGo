# RelayGo ProGuard / R8 保护规则
# ============================================================
# Dart/Flutter 引擎入口：R8 不会混淆 Dart 字节码，
# 但会混淆 Java/Kotlin 胶水层。以下规则保留反射/动态调用的类。

# ---- Flutter Engine 核心保留（MethodChannel 反射） ----
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.plugin.common.** { *; }
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.embedding.**

# ---- SQLite/Hive 序列化 ----
# Hive 通过 @HiveType/@HiveField 运行时反射读写对象
-keep @interface com.hive.** { *; }
-keepclassmembers class * {
    @com.hive.** <fields>;
}
-keep class * extends com.hive.** { *; }

# ---- 网络请求（http 包） ----
-keep class org.apache.** { *; }
-dontwarn org.apache.**
-dontwarn android.net.**

# ---- path_provider / file_selector / url_launcher 插件 ----
-keep class com.tekartik.sqflite.** { *; }
-dontwarn com.tekartik.sqflite.**
-keep class io.flutter.plugins.pathprovider.** { *; }
-keep class io.flutter.plugins.urllauncher.** { *; }
-keep class io.flutter.plugins.imagepicker.** { *; }

# ---- Dart 侧的 PlatformChannel 回调 ----
-keep class io.flutter.view.FlutterCallbackInformation { *; }
-keep class io.flutter.view.FlutterMain { *; }

# ---- 避免 R8 误删 Android 原生组件 ----
-keep class com.relaygo.app.** { *; }
-keep class * extends android.app.Service { *; }
-keep class * extends android.content.BroadcastReceiver { *; }
-keep class * extends android.content.ContentProvider { *; }

# ---- 通用保留 ----
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod
-keepattributes SourceFile, LineNumberTable        # 保留崩溃栈
-keepattributes Exceptions, InnerClasses

# ---- 资源缩减豁免 ----
# shrinkResources 默认按静态引用决定保留或移除。
# 若使用 Resources.getIdentifier() 等动态引用，需在此添加 -keep。
# RelayGo 未使用此类动态引用，无需额外保留。