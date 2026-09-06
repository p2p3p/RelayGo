# RelayGo 构建环境配置文档

> 本文档详细记录 RelayGo 项目在太墟（TaiXu）沙箱环境中的完整构建配置，
> 涵盖工具链版本、SDK 组件、Gradle 配置、签名凭据与常见问题排查。
> 环境重置后可按本文档逐项恢复。

---

## 1. 工具链版本总览

| 组件 | 版本 | 路径 / 来源 |
|------|------|-------------|
| Flutter SDK | **3.47.1** (stable) | `/opt/flutter` |
| Dart SDK | **3.13.1** (stable) | 随 Flutter 内置 |
| JDK | **OpenJDK 17** (Temurin 17.0.20.1) | 系统全局 |
| Android SDK | API 34 + API 36 | `/opt/android-sdk` |
| Android Build-Tools | **35.0.0** | `/opt/android-sdk/build-tools/35.0.0` |
| Android NDK | **29.0.14206865** (r29) | `/opt/android-sdk/ndk/` |
| Gradle | **8.14.2** | Wrapper 自动下载 |
| Kotlin | **2.2.20** | Gradle 插件管理 |
| AGP (Android Gradle Plugin) | **8.11.1** | `settings.gradle` 声明 |
| CMake | **3.31.7** | `app/build.gradle` 声明 |
| 架构 | **aarch64** (ARM64) | PRoot 沙箱 |

---

## 2. 环境变量

```bash
# Flutter / Dart（太墟内置）
export PATH="/opt/flutter/bin:/opt/taixu/bin:$PATH"

# Android SDK
export ANDROID_HOME="/opt/android-sdk"
export ANDROID_SDK_ROOT="/opt/android-sdk"

# JDK 17
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-arm64"  # ARM64 设备
# x86_64 设备为 /usr/lib/jvm/java-17-openjdk-amd64

# 中国大陆镜像（可选，加速 pub 依赖下载）
export PUB_HOSTED_URL="https://pub.flutter-io.cn"
export FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
```

> **注意**：太墟沙箱中 `ANDROID_HOME` 和 `ANDROID_SDK_ROOT` 可能未全局设置。
> Gradle 通过 `android/local.properties` 中的 `sdk.dir` 定位 SDK，不依赖环境变量。

---

## 3. Android SDK 组件

### 3.1 已安装组件

```
/opt/android-sdk/
├── build-tools/
│   └── 35.0.0/              # AAPT2、D8、ZIPFLATE 等
├── platforms/
│   ├── android-34/          # compileSdk 34
│   └── android-36/          # 备用（部分依赖可能引用）
├── platform-tools/          # adb 等
├── licenses/                # 已接受许可
└── ndk/                     # NDK r29 (29.0.14206865)
```

### 3.2 如需补装组件

```bash
# 通过 sdkmanager 安装（需要 cmdline-tools）
sdkmanager "platforms;android-34"
sdkmanager "build-tools;35.0.0"
sdkmanager "ndk;29.0.14206865"
```

---

## 4. 项目关键配置文件

### 4.1 `android/local.properties`

```properties
flutter.buildMode=release
flutter.versionName=1.0.2
flutter.versionCode=2
sdk.dir=/opt/android-sdk
flutter.sdk=/opt/flutter
```

> 环境重置后需确认此文件存在且路径正确。

### 4.2 `android/gradle.properties`

关键配置项：

```properties
# JVM 内存分配（移动设备资源有限，需控制）
org.gradle.jvmargs=-Xmx4G -XX:MaxMetaspaceSize=2G -XX:+HeapDumpOnOutOfMemoryError
# 守护进程空闲超时 1 小时（避免长构建中途回收）
org.gradle.daemon.idletimeout=3600000
# 并行构建工作线程数
org.gradle.workers.max=2
org.gradle.parallel=true
org.gradle.caching=false

# Kotlin 编译守护进程内存限制
kotlin.daemon.jvmargs=-Xmx768M

# AndroidX 配置
android.useAndroidX=true
android.enableJetifier=false    # 关闭 Jetifier（项目已全部 AndroidX）

# 旧 DSL 兼容（Flutter 迁移器自动写入）
android.builtInKotlin=false
android.newDsl=false

# HTTP 超时（避免镜像连接挂起）
systemProp.org.gradle.internal.http.connectionTimeout=30000
systemProp.org.gradle.internal.http.socketTimeout=30000
systemProp.org.gradle.internal.http.connectionRequestTimeout=30000
```

### 4.3 `android/gradle/wrapper/gradle-wrapper.properties`

```properties
distributionUrl=https\://mirrors.cloud.tencent.com/gradle/gradle-8.14.2-bin.zip
```

> 使用腾讯云镜像加速 Gradle 下载。

### 4.4 `android/settings.gradle`

```groovy
pluginManagement {
    repositories {
        // 国内镜像优先
        maven { url 'https://maven.aliyun.com/repository/google' }
        maven { url 'https://maven.aliyun.com/repository/central' }
        maven { url 'https://maven.aliyun.com/repository/gradle-plugin' }
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id "dev.flutter.flutter-plugin-loader" version "1.0.0"
    id "com.android.application" version "8.11.1" apply false
    id "org.jetbrains.kotlin.android" version "2.2.20" apply false
}
```

### 4.5 `android/build.gradle` (root)

```groovy
allprojects {
    repositories {
        // 国内镜像优先
        maven { url 'https://maven.aliyun.com/repository/google' }
        maven { url 'https://maven.aliyun.com/repository/central' }
        maven { url 'https://maven.aliyun.com/repository/gradle-plugin' }
        google()
        mavenCentral()
    }
}

// 统一固定 NDK 版本
allprojects {
    plugins.withId("com.android.library") {
        android.ndkVersion = "29.0.14206865"
    }
    plugins.withId("com.android.application") {
        android.ndkVersion = "29.0.14206865"
    }
}
```

### 4.6 `android/app/build.gradle` (关键部分)

```groovy
android {
    namespace "com.relaygo.app"
    compileSdkVersion 34
    ndkVersion "29.0.14206865"

    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = '17'
    }

    defaultConfig {
        applicationId "com.relaygo.app"
        minSdkVersion flutter.minSdkVersion   // 由 Flutter 引擎决定，通常 21+
        targetSdkVersion 34
        ndk {
            abiFilters 'arm64-v8a'            // 仅保留 ARM64
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true         # 压缩 .so 减小 APK 体积
            exclude '**/libVkLayer_khronos_validation.so'
        }
    }

    buildTypes {
        release {
            signingConfig signingConfigs.release
            minifyEnabled = false             # 不混淆（Flutter/Hive 反射）
            shrinkResources = false
            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
        }
    }
}

// 依赖版本降级：适配 compileSdk 34
configurations.all {
    resolutionStrategy {
        force "androidx.core:core:1.13.1"
        force "androidx.core:core-ktx:1.13.1"
        force "androidx.browser:browser:1.8.0"
        force "androidx.annotation:annotation:1.8.1"
        force "androidx.annotation:annotation-jvm:1.8.1"
    }
}

// 禁用 AAR metadata 检查（AGP 8.11.1 兼容性）
gradle.projectsEvaluated {
    tasks.matching { it.name.contains('checkAarMetadata') }.configureEach {
        enabled = false
    }
}
```

---

## 5. 签名配置

### 5.1 密钥库文件

```
android/keystore/relaygo-release.jks    # 随仓库保留
```

### 5.2 `android/keystore.properties`（不入库，需手动恢复）

```properties
RELEASE_STORE_FILE=../keystore/relaygo-release.jks
RELEASE_STORE_PASSWORD=YOUR_STRONG_STORE_PASSWORD
RELEASE_KEY_ALIAS=relaygo
RELEASE_KEY_PASSWORD=YOUR_STRONG_KEY_PASSWORD
```

> **重要**：此文件已在 `.gitignore` 中。环境重置后需手动创建。
> 若缺失，Release 构建会自动回退 debug 签名（指纹会变，无法覆盖安装已发布的版本）。

### 5.3 生成新签名（如需）

```bash
keytool -genkey -v \
  -keystore android/keystore/relaygo-release.jks \
  -keyalg RSA -keysize 2048 -validity 36500 \
  -alias relaygo \
  -storepass YOUR_STRONG_STORE_PASSWORD \
  -keypass YOUR_STRONG_KEY_PASSWORD \
  -dname "CN=RelayGo, OU=Dev, O=RelayGo, L=CN, ST=CN, C=CN"
```

---

## 6. Flutter 依赖配置

### 6.1 `pubspec.yaml` 核心依赖

| 依赖 | 版本 | 用途 |
|------|------|------|
| flutter | SDK | 框架 |
| hive | ^2.2.3 | 本地加密存储 |
| hive_flutter | ^1.1.0 | Hive Flutter 初始化 |
| encrypt | 5.0.1 | AES-256 加密 |
| provider | ^6.0.5 | 状态管理 |
| http | ^0.13.5 | 网络请求 / SSE 转发 |
| crypto | ^3.0.2 | SHA-256 哈希 |
| intl | ^0.18.0 | 日期/数字格式化 |
| file_selector | ^0.9.5 | 文件选择器 |
| url_launcher | ^6.3.0 | 打开外部链接 |
| path_provider | ^2.1.6 | 应用文档目录 |

### 6.2 依赖覆盖（`dependency_overrides`）

```yaml
dependency_overrides:
  path_provider_windows: 2.3.0    # 修复 Win32 FFI 兼容
  path_provider: 2.1.6
  path_provider_android: 2.2.23   # 移除 v1 embedding 引用
```

### 6.3 安装依赖

```bash
cd /workspace/RelayGo
flutter pub get
```

---

## 7. AndroidManifest.xml 关键配置

```xml
<!-- Impeller 渲染引擎：release AOT 模式必须启用 -->
<meta-data
    android:name="io.flutter.embedding.android.EnableImpeller"
    android:value="true" />

<!-- 权限 -->
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC"/>
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
```

> **⚠️ 关键**：`EnableImpeller` 必须为 `true`。
> 在 Flutter 3.47.1 release AOT 模式下，禁用 Impeller 回退 Skia 会导致
> 渲染线程无法产出首帧，表现为启动后白屏/卡屏（debug 模式正常）。

---

## 8. Kotlin 源文件

```
android/app/src/main/kotlin/com/relaygo/app/
├── MainActivity.kt         # FlutterActivity + MethodChannel + 诊断日志
├── KeepAliveService.kt     # 前台服务（常驻通知 + 进程保活）
└── BootReceiver.kt         # 开机自启广播接收器
```

---

## 9. 构建命令

### 9.1 太墟内置构建脚本（推荐）

```bash
# Debug 构建
/opt/taixu/scripts/build_flutter.sh "/workspace/RelayGo" "apk --debug"

# Release 构建
/opt/taixu/scripts/build_flutter.sh "/workspace/RelayGo" "apk --release"
```

### 9.2 直接使用 Flutter 命令

```bash
cd /workspace/RelayGo

# 安装依赖
flutter pub get

# Debug APK（较快，约 5-10 分钟）
flutter build apk --debug

# Release APK（较慢，约 10-20 分钟）
flutter build apk --release
```

### 9.3 产物位置

```
build/app/outputs/flutter-apk/
├── app-debug.apk          # Debug 构建
└── app-release.apk        # Release 构建
```

### 9.4 安装到手机

```bash
# 复制到 Download 目录
cp -f build/app/outputs/flutter-apk/app-debug.apk /sdcard/Download/RelayGo.apk

# 通过太墟安装
taixu-host install-apk /sdcard/Download/RelayGo.apk

# 或通过 ADB
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

---

## 10. 资源文件

```
assets/logos/               # 提供商 Logo（24 个 PNG）
├── openai.png
├── anthropic.png
├── google.png
├── azure.png
├── deepseek.png
├── qwen.png
├── ... (共 24 个)
```

---

## 11. 构建优化配置

### 11.1 移动设备性能限制

太墟运行在 Android 手机上的 PRoot 沙箱中，CPU/IO 性能有限：

- **JVM 内存**：限制为 4G（`-Xmx4G`），避免 OOM
- **并行线程**：限制为 2（`org.gradle.workers.max=2`）
- **Kotlin 守护进程**：限制为 768M
- **构建超时**：建议设置 600 秒以上（`flutter build apk --debug` 约需 5-10 分钟）

### 11.2 ABI 过滤

仅保留 `arm64-v8a`，避免编译 x86/armeabi-v7a 的 `.so` 文件：

```groovy
ndk {
    abiFilters 'arm64-v8a'
}
```

### 11.3 .so 压缩

```groovy
packaging {
    jniLibs {
        useLegacyPackaging = true    # 压缩 .so，APK 从 ~57MB 降到 ~23MB
    }
}
```

---

## 12. 镜像配置

### 12.1 Gradle / Maven 镜像

| 镜像 | URL | 用途 |
|------|-----|------|
| 阿里云 Google | `https://maven.aliyun.com/repository/google` | AndroidX / Google 依赖 |
| 阿里云 Central | `https://maven.aliyun.com/repository/central` | Maven Central 依赖 |
| 阿里云 Gradle 插件 | `https://maven.aliyun.com/repository/gradle-plugin` | Gradle 插件 |
| 腾讯云 Gradle | `https://mirrors.cloud.tencent.com/gradle/` | Gradle 本体下载 |

### 12.2 Flutter / Pub 镜像

```bash
export PUB_HOSTED_URL="https://pub.flutter-io.cn"
export FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
```

---

## 13. 环境一键恢复脚本

项目内置 `scripts/setup_env.sh`，可在环境重置后一键恢复工具链：

```bash
sudo bash scripts/setup_env.sh
```

> **注意**：该脚本中的默认版本（Flutter 3.29.0、NDK 28.2 等）是旧版配置。
> 太墟沙箱已预装 Flutter 3.47.1 + NDK r29，通常无需重新运行此脚本。
> 仅在全新 Linux 环境中从零搭建时使用。

---

## 14. 常见问题排查

### 14.1 构建超时

**现象**：`flutter build apk` 超过 5 分钟未完成。

**解决**：
- 移动设备算力有限，Debug 构建约 5-10 分钟，Release 约 10-20 分钟
- 设置更长超时：`timeout_seconds=600`
- 确保没有其他重型进程同时运行
- 使用太墟构建脚本（内置工具链锁，避免并发冲突）

### 14.2 OOM (Java heap space)

**现象**：`java.lang.OutOfMemoryError: Java heap space`

**解决**：
- `gradle.properties` 中已设置 `-Xmx4G`
- 如仍 OOM，降低 `org.gradle.workers.max=1`
- 关闭并行构建 `org.gradle.parallel=false`

### 14.3 NDK 版本冲突

**现象**：`CXX1100` 或 NDK 版本不匹配错误。

**解决**：
- `settings.gradle` 会自动清理 `local.properties` 中的 `ndk.dir` 行
- `build.gradle` 中统一固定 NDK 版本为 `29.0.14206865`
- 确认 NDK 已安装：`ls /opt/android-sdk/ndk/`

### 14.4 AAR Metadata 检查失败

**现象**：依赖库要求的 `minCompileSdk` 高于 34。

**解决**：
- `app/build.gradle` 中已通过 `resolutionStrategy.force` 降级 AndroidX 依赖
- AAR metadata 检查任务已禁用（`gradle.projectsEvaluated` 块）

### 14.5 Release 白屏 / 卡屏

**现象**：Debug 构建正常，Release 构建启动后白屏。

**根因**：`AndroidManifest.xml` 中 `EnableImpeller=false` 时，Flutter 3.47.1
release AOT 模式回退 Skia 渲染，但渲染线程无法产出首帧。

**解决**：
```xml
<meta-data
    android:name="io.flutter.embedding.android.EnableImpeller"
    android:value="true" />
```

### 14.6 签名不匹配

**现象**：`INSTALL_FAILED_UPDATE_INCOMPATIBLE`

**解决**：
- 确认 `android/keystore.properties` 存在且密码正确
- 确认 `android/keystore/relaygo-release.jks` 是原始签名文件
- 如签名丢失，需先卸载旧版本再安装

### 14.7 Gradle 下载卡住

**现象**：Gradle wrapper 下载长时间无响应。

**解决**：
- 确认 `gradle-wrapper.properties` 使用腾讯云镜像
- 检查网络连接
- 手动下载 Gradle 放入 `~/.gradle/wrapper/dists/`

---

## 15. 项目目录结构

```
RelayGo/
├── lib/                        # Dart 源码
│   ├── main.dart               # 入口
│   ├── app.dart                # AppState 全局状态
│   ├── config/                 # 常量、主题
│   ├── database/               # Hive 初始化
│   ├── models/                 # 数据模型
│   ├── services/               # 代理、同步、密钥、限流等
│   │   └── providers/          # 各服务商适配
│   ├── screens/                # 页面
│   ├── widgets/                # 复用组件
│   ├── utils/                  # 加解密、校验、格式化
│   └── l10n/                   # 多语言
├── android/                    # Android 原生工程
│   ├── app/
│   │   ├── build.gradle        # 模块构建配置
│   │   ├── proguard-rules.pro  # 混淆规则
│   │   └── src/main/
│   │       ├── AndroidManifest.xml
│   │       ├── kotlin/com/relaygo/app/
│   │       │   ├── MainActivity.kt
│   │       │   ├── KeepAliveService.kt
│   │       │   └── BootReceiver.kt
│   │       └── res/            # 资源（主题、图标等）
│   ├── build.gradle            # 根构建配置
│   ├── settings.gradle         # 项目设置
│   ├── gradle.properties       # Gradle 属性
│   ├── keystore/               # 签名密钥库
│   │   └── relaygo-release.jks
│   ├── keystore.properties     # 签名配置（不入库）
│   └── local.properties        # SDK 路径（不入库）
├── assets/logos/               # 提供商 Logo（24 PNG）
├── scripts/setup_env.sh        # 环境恢复脚本
├── pubspec.yaml                # Flutter 依赖
├── analysis_options.yaml       # 代码分析规则
└── test/                       # 单元测试
```

---

## 16. 版本信息

- **应用版本**：1.0.2+2
- **包名**：`com.relaygo.app`
- **协议**：AGPL-3.0
- **文档生成时间**：2026-08-30

---

*© 2026 RelayGo Authors*
