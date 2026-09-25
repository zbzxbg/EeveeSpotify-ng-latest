TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = Spotify
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = EeveeSpotify

REPO_SLUG ?= $(shell git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$$|\1|')
REPO_SLUG_FINAL := $(if $(REPO_SLUG),$(REPO_SLUG),zbzxbg/EeveeSpotify-ng-latest)

BRANCH_NAME ?= $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null)
BRANCH_NAME_FINAL := $(if $(BRANCH_NAME),$(BRANCH_NAME),Master)

$(shell mkdir -p Sources/EeveeSpotify/Generated)
$(shell printf 'enum GeneratedConfig {\n    static let repoSlug = "%s"\n    static let branchName = "%s"\n}\n' "$(REPO_SLUG_FINAL)" "$(BRANCH_NAME_FINAL)" > Sources/EeveeSpotify/Generated/RepoSlug.swift)

EeveeSpotify_FILES = $(shell find Sources/EeveeSpotify -name '*.swift') $(shell find Sources/EeveeSpotifyC -name '*.m' -o -name '*.c' -o -name '*.mm' -o -name '*.cpp')
EeveeSpotify_SWIFTFLAGS = -ISources/EeveeSpotifyC/include -Osize
EeveeSpotify_EXTRA_FRAMEWORKS = EeveeSwiftProtobuf
EeveeSpotify_CFLAGS = -fobjc-arc -ISources/EeveeSpotifyC/include -Os

# ── 越狱路径支持（libroot / roothide）───────────────────────────────────────
# RootHide's compatibility implementation of libroot resolves jailbreak paths
# through libroothide at runtime. Rootless builds continue to use libroot.
#
# NO_JBROOT=1 把这块整个关掉 —— 见下面「无越狱路径依赖」一节。
NO_JBROOT ?= 0

ifeq ($(NO_JBROOT),1)
EeveeSpotify_CFLAGS += -DNO_JBROOT
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
EeveeSpotify_SWIFTFLAGS += -D ROOTHIDE
EeveeSpotify_LDFLAGS += -lroothide -Xlinker -rpath -Xlinker @loader_path/.jbroot/Library/Frameworks
else
EeveeSpotify_LDFLAGS += -lroot
endif

# ── 无越狱路径依赖：NO_JBROOT=1 ─────────────────────────────────────────────
#     make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless NO_JBROOT=1
#
# 为什么需要：IPA 里注入的那份 EeveeSpotify.dylib 是从这个 deb 里掏出来的，
# 而 TrollStore / 侧载设备上的 Spotify **不在**越狱环境里 —— 没有 /var/jb。
# libroot 是**加载期**依赖（LC_LOAD_DYLIB /var/jb/usr/lib/libroot.dylib），
# dyld 解析不到就 dlopen 失败：注入完 App 直接起不来，日志里往往只有一句
# dlerror，极难定位。实测 rootless 方案打出来的 IPA 就是这个下场。
#
# 关掉之后 EeveeJBRootPath() 退化成原样返回（Sources/EeveeSpotifyC/Tweak.m）。
# 功能不受影响：BundleHelper 先找 main bundle，只有找不到才去越狱路径兜底。
#
# ⚠️ 这样编出来的 deb **不能**给越狱用户装（少了 libroot 的路径解析）。
#    工作流里它只当「dylib 的来源」，不发布；越狱包由 builddeb.yml 另出。
# ⚠️ 同理，roothide 方案（-lroothide）也不能拿来出 IPA。

# Sideload compatibility (keychain redirect, group containers, CloudKit) is
# handled out-of-process by modules/zxPluginsInject — LC-injected via ipapatch
# in build-ipa-local.sh and the GitHub workflow. No flags needed here.

include $(THEOS_MAKE_PATH)/tweak.mk

internal-stage::
	# Bundle EeveeSwiftProtobuf.framework into the package. Renamed from
	# SwiftProtobuf so the @objc class names don't collide with the
	# SwiftProtobuf statically embedded in SpotifyShared.framework.
	mkdir -p $(THEOS_STAGING_DIR)/Library/Frameworks
	cp -r $(THEOS)/lib/iphone/$(or $(THEOS_PACKAGE_SCHEME),rootless)/EeveeSwiftProtobuf.framework $(THEOS_STAGING_DIR)/Library/Frameworks/

# Build EeveeSwiftProtobuf.framework from apple/swift-protobuf source. Run
# this once before `make package`. Re-run if SWIFTPROTOBUF_VERSION changes
# or `swift --version` jumps a major.
build-eeveeswiftprotobuf:
	bash Tools/SwiftProtobufBuild/build-eeveeswiftprotobuf.sh
