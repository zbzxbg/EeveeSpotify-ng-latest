// Sideload compat shim. LC-injected into main exec + every .appex by ipapatch.
//
// Five pieces:
//   1. SecItem* rebind — apps hard-code their entitled keychain access group
//      (e.g. `<TEAMID>.com.spotify.client.X`); resigning with another team
//      makes that group invalid. Every keychain query is rewritten to use
//      whatever access group our profile actually has.
//   2. CKContainer / CKEntitlements neutered — resigned bundle has no iCloud
//      ents; CloudKit lookups would assert. Return nil / strip the keys.
//   3. containerURLForSecurityApplicationGroupIdentifier: never nil — without
//      a real app-groups entitlement this returns nil and apps crash inside
//      `hasPrefix:` of the result. Real URL when entitled, sandbox path otherwise.
//   4. NSUserDefaults init redirect (appex-only) — appex reads `group.*`
//      suites via a real URL inside our entitled app-group container instead
//      of going through cfprefsd, so it sees what the main app wrote.
//   5. Main-app fan-out — main writes to `group.*` via cfprefsd normally,
//      and we mirror those writes to a parallel NSUserDefaults backed by the
//      shared-container URL. Pieces 4 + 5 together bridge main → appex over
//      group.* defaults. Without #5, group.* writes sit in per-process
//      cfprefsd cache and the appex never sees them.

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "../fishhook/fishhook.h"

@interface LSBundleProxy: NSObject
@property(nonatomic, assign, readonly) NSDictionary *entitlements;
@property(nonatomic, assign, readonly) NSDictionary *groupContainerURLs;
+ (instancetype)bundleProxyForCurrentProcess;
@end

@interface NSUserDefaults (Sideload)
- (id)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container;
- (NSString *)_identifier;
@end

static NSString *accessGroupId;

// =========================================================================
// helpers
// =========================================================================

static BOOL createDirectoryIfNotExists(NSString *path) {
	NSFileManager *fm = [NSFileManager defaultManager];
	if ([fm fileExistsAtPath:path]) return YES;
	NSError *error = nil;
	[fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error];
	return error == nil;
}

static NSURL *getAppGroupPathIfExists(void) {
	static NSURL *cached = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		LSBundleProxy *proxy = [objc_getClass("LSBundleProxy") bundleProxyForCurrentProcess];
		if (!proxy) return;

		NSDictionary *entitlements = proxy.entitlements;
		if (![entitlements isKindOfClass:[NSDictionary class]]) return;

		NSArray *appGroups = entitlements[@"com.apple.security.application-groups"];
		if (![appGroups isKindOfClass:[NSArray class]] || appGroups.count == 0) return;

		NSDictionary *paths = proxy.groupContainerURLs;
		if (![paths isKindOfClass:[NSDictionary class]]) return;

		NSURL *url = paths[[appGroups firstObject]];
		if ([url isKindOfClass:[NSURL class]]) cached = url;
	});
	return cached;
}

static BOOL sciIsAppExtensionProcess(void) {
	static BOOL cached = NO;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		cached = ([[NSBundle mainBundle] infoDictionary][@"NSExtension"] != nil);
	});
	return cached;
}

// Tag on the fan-out NSUserDefaults so its own setObject: doesn't recurse.
static const void *kSCIFanoutTagKey = &kSCIFanoutTagKey;

static NSURL *sciSharedContainerURLForSuite(NSString *suiteName) {
	NSURL *appGroup = getAppGroupPathIfExists();
	if (!appGroup || !suiteName.length) return nil;
	NSURL *container = [appGroup URLByAppendingPathComponent:suiteName isDirectory:YES];
	NSURL *prefs = [[container URLByAppendingPathComponent:@"Library"] URLByAppendingPathComponent:@"Preferences"];
	createDirectoryIfNotExists(prefs.path);
	return container;
}

static NSUserDefaults *sciFanoutDefaultsForSuite(NSString *suiteName) {
	static NSMutableDictionary<NSString *, NSUserDefaults *> *cache;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; });

	@synchronized(cache) {
		NSUserDefaults *hit = cache[suiteName];
		if (hit) return hit;
		NSURL *container = sciSharedContainerURLForSuite(suiteName);
		if (!container) return nil;
		NSUserDefaults *fanout = [[NSUserDefaults alloc] _initWithSuiteName:suiteName container:container];
		if (!fanout) return nil;
		objc_setAssociatedObject(fanout, kSCIFanoutTagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		cache[suiteName] = fanout;
		return fanout;
	}
}

static NSString *sciSuiteNameForDefaults(NSUserDefaults *defaults) {
	if (![defaults respondsToSelector:@selector(_identifier)]) return nil;
	return ((NSString *(*)(id, SEL))objc_msgSend)(defaults, @selector(_identifier));
}

static BOOL sciShouldFanout(NSUserDefaults *defaults) {
	if (sciIsAppExtensionProcess()) return NO;        // appex reads only
	if (!getAppGroupPathIfExists()) return NO;        // no shared container to fan out to
	if (objc_getAssociatedObject(defaults, kSCIFanoutTagKey)) return NO;  // avoid recursion
	NSString *suite = sciSuiteNameForDefaults(defaults);
	return [suite hasPrefix:@"group"];
}

// =========================================================================
// keychain access-group rebind (fishhook)
// =========================================================================

static OSStatus (*origSecItemAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*origSecItemCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*origSecItemUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*origSecItemDelete)(CFDictionaryRef);

// CFRef-owned copy of `query` with kSecAttrAccessGroup rewritten to our entitled
// group. NULL if nothing to rewrite — caller falls back to original query so a
// missing accessGroupId never poisons a request with nil.
static CFDictionaryRef sciFixedQuery(CFDictionaryRef query) {
	if (!query || !accessGroupId.length) return NULL;
	CFMutableDictionaryRef dict = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
	if (dict) CFDictionarySetValue(dict, kSecAttrAccessGroup, (__bridge const void *)accessGroupId);
	return dict;
}

static OSStatus zxSecItemAdd(CFDictionaryRef q, CFTypeRef *r) {
	CFDictionaryRef d = sciFixedQuery(q);
	OSStatus s = origSecItemAdd(d ?: q, r);
	if (d) CFRelease(d);
	return s;
}

static OSStatus zxSecItemCopyMatching(CFDictionaryRef q, CFTypeRef *r) {
	CFDictionaryRef d = sciFixedQuery(q);
	OSStatus s = origSecItemCopyMatching(d ?: q, r);
	if (d) CFRelease(d);
	return s;
}

static OSStatus zxSecItemUpdate(CFDictionaryRef q, CFDictionaryRef u) {
	CFDictionaryRef d = sciFixedQuery(q);
	OSStatus s = origSecItemUpdate(d ?: q, u);
	if (d) CFRelease(d);
	return s;
}

static OSStatus zxSecItemDelete(CFDictionaryRef q) {
	CFDictionaryRef d = sciFixedQuery(q);
	OSStatus s = origSecItemDelete(d ?: q);
	if (d) CFRelease(d);
	return s;
}

static void rebindSecFuncs(void) {
	struct rebinding rebinds[4] = {
		{"SecItemAdd", (void *)zxSecItemAdd, (void **)&origSecItemAdd},
		{"SecItemCopyMatching", (void *)zxSecItemCopyMatching, (void **)&origSecItemCopyMatching},
		{"SecItemUpdate", (void *)zxSecItemUpdate, (void **)&origSecItemUpdate},
		{"SecItemDelete", (void *)zxSecItemDelete, (void **)&origSecItemDelete},
	};
	rebind_symbols(rebinds, 4);
}

// =========================================================================
// CloudKit neutering
// =========================================================================

%hook CKContainer
- (id)_setupWithContainerID:(id)a options:(id)b { return nil; }
- (id)_initWithContainerIdentifier:(id)a { return nil; }
%end

%hook CKEntitlements
- (id)initWithEntitlementsDict:(NSDictionary *)entitlements {
	NSMutableDictionary *m = [entitlements mutableCopy];
	[m removeObjectForKey:@"com.apple.developer.icloud-container-environment"];
	[m removeObjectForKey:@"com.apple.developer.icloud-services"];
	return %orig([m copy]);
}
%end

// =========================================================================
// NSFileManager group container URL
// =========================================================================

%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
	if (NSURL *appGroupURL = getAppGroupPathIfExists()) {
		NSURL *url = [appGroupURL URLByAppendingPathComponent:groupIdentifier];
		createDirectoryIfNotExists(url.path);
		return url;
	}
	// No entitlement → sandbox path so the caller never sees nil.
	NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
	NSString *path = [docs stringByAppendingPathComponent:groupIdentifier];
	createDirectoryIfNotExists(path);
	return [NSURL fileURLWithPath:path];
}
%end

// =========================================================================
// NSUserDefaults: appex redirect + main-app fan-out
// =========================================================================

%hook NSUserDefaults

- (id)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container {
	if (!sciIsAppExtensionProcess()) return %orig(suiteName, container);

	NSURL *appGroupURL = getAppGroupPathIfExists();
	if (!appGroupURL || ![suiteName hasPrefix:@"group"]) return %orig(suiteName, container);

	NSURL *redirect = [appGroupURL URLByAppendingPathComponent:suiteName isDirectory:YES];
	if (!redirect) return %orig(suiteName, container);

	NSURL *prefs = [[redirect URLByAppendingPathComponent:@"Library"] URLByAppendingPathComponent:@"Preferences"];
	createDirectoryIfNotExists(prefs.path);
	return %orig(suiteName, redirect);
}

- (void)setObject:(id)value forKey:(NSString *)key {
	%orig;
	if (!sciShouldFanout(self)) return;
	[sciFanoutDefaultsForSuite(sciSuiteNameForDefaults(self)) setObject:value forKey:key];
}

- (void)removeObjectForKey:(NSString *)key {
	%orig;
	if (!sciShouldFanout(self)) return;
	[sciFanoutDefaultsForSuite(sciSuiteNameForDefaults(self)) removeObjectForKey:key];
}

%end

// =========================================================================
// keychain access-group bootstrap
// =========================================================================
//
// Probe a throwaway keychain entry so SecItemCopyMatching/SecItemAdd returns
// the access group the OS actually granted us based on our profile. That's
// the value we splice into every subsequent SecItem* call.

static void setRequiredIDs(void) {
	NSDictionary *query = @{
		(__bridge NSString *)kSecClass: (__bridge NSString *)kSecClassGenericPassword,
		(__bridge NSString *)kSecAttrAccount: @"zxPluginsInjectGenericEntry",
		(__bridge NSString *)kSecAttrService: @"",
		(__bridge id)kSecReturnAttributes: (id)kCFBooleanTrue,
	};

	CFDictionaryRef result = nil;
	OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
	if (status == errSecItemNotFound) {
		status = SecItemAdd((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
	}
	if (status != errSecSuccess) return;

	accessGroupId = [(__bridge NSDictionary *)result objectForKey:(__bridge NSString *)kSecAttrAccessGroup];
	if (result) CFRelease(result);
}

__attribute__((constructor)) static void init(void) {
	setRequiredIDs();
	rebindSecFuncs();
}
