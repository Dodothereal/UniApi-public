#import <Foundation/Foundation.h>
// Persistent native-MCL preference controller. The config directory must be root-owned
// and non-writable by unprivileged users. Only its fixed target file is writable.
int battery_daemon(const char *configPath, int band);
int battery_parse_target(const char *bytes, size_t length);
// Retired adapter-cycling entry point, retained to reject old invocations.
int battery_hold(int target, int floor, pid_t owner, const char *stamp);
