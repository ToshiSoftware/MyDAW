// Catches the Objective-C exceptions AVAudioEngine raises for a bad
// connection or format. Swift cannot catch them, so without this the app
// aborts. Called from Swift through @_silgen_name (ObjCExceptionCatcher.swift).

#import <Foundation/Foundation.h>
#include <string.h>

// Runs body(context). Returns true when it finished; false when it raised,
// with "name: reason" written to `reason` (at most capacity - 1 bytes).
// Whatever the interrupted code had retained is leaked, which is acceptable
// for a failure that would otherwise end the app.
extern "C" bool MyDAWCatchObjCException(
    void (*body)(void *),
    void *context,
    char *reason,
    int capacity
) {
    @try {
        body(context);
        return true;
    } @catch (NSException *exception) {
        if (reason != nullptr && capacity > 0) {
            NSString *text = [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @""];
            strlcpy(reason, text.UTF8String ?: "", static_cast<size_t>(capacity));
        }
        return false;
    }
}
