#import <Foundation/Foundation.h>
// Fixed system domain and keys only. Journal lives in the protected directory.
BOOL battery_preferences_apply(int directory, int target, NSString **error);
// Reads back through the system service, independently of the preference file.
int battery_preferences_limit(void);
BOOL battery_preferences_is_pending(void);
