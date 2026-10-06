// Prints "current" when CFPreferences — the API Chrome's PolicyLoaderMac reads
// policy through — returns exactly the forced values in the managed policy
// file, and "stale" otherwise. Run with: osascript -l JavaScript <this> <path>
//
// The file and that view can disagree: on 2026-10-05 the file at
// /Library/Managed Preferences/com.google.Chrome.plist listed two forced
// extensions while CFPreferencesCopyAppValue("ExtensionInstallForcelist",
// "com.google.Chrome") still returned the one from before the rewrite, because
// cfprefsd serves a cached copy. Restarting the user's cfprefsd did not change
// it; the cache is root's.
ObjC.import("Foundation");

function run(argv) {
  const domain = $("com.google.Chrome");
  const policy = $.NSDictionary.dictionaryWithContentsOfFile($(argv[0]));
  if (policy.isNil()) {
    return "stale";
  }
  const keys = policy.allKeys;
  for (let i = 0; i < keys.count; i++) {
    const key = keys.objectAtIndex(i);
    const served = ObjC.castRefToObject($.CFPreferencesCopyAppValue(key, domain));
    if (
      !$.CFPreferencesAppValueIsForced(key, domain) ||
      served.isNil() ||
      !served.isEqual(policy.objectForKey(key))
    ) {
      return "stale";
    }
  }
  return "current";
}
