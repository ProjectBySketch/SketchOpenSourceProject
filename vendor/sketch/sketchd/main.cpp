// sketchd entry point.
//
//   sketchd serve             init starts this; serves /data/sketch/run/sketchd.sock
//   sketchd cli <verb> ...    explicit CLI mode
//   sketchd <verb> ...        direct use, e.g. su -c 'sketchd install x.deb'
//   deb <verb> ...            the same binary under a second name (Android.bp
//                             `symlinks`), which is the friendly CLI
#include "sketch.h"

#include <unistd.h>

#include <cstdio>
#include <string>
#include <vector>

using namespace sketch;

namespace {

bool IsInteractiveVerb(const std::string& verb) {
  return verb == "shell" || verb == "run" || verb == "exec";
}

int RunCli(const std::vector<std::string>& argv) {
  if (argv.empty()) return Dispatch(argv);

  // A shell or a one-off command needs this terminal, so it never goes through
  // the daemon: stdin and job control would not survive the socket.
  if (IsInteractiveVerb(argv[0])) return Dispatch(argv);

  int exit_code = 0;
  if (CallDaemon(argv, exit_code)) return exit_code;

  // No daemon: do the work here. This is the normal case for `su -c` and for
  // `adb root` shells where the service has not been started.
  return Dispatch(argv);
}

}  // namespace

int main(int argc, char** argv) {
  std::vector<std::string> args;
  for (int i = 1; i < argc; ++i) args.emplace_back(argv[i]);

  // Called as `deb`? Then it is the CLI whatever the first argument is.
  const std::string self = argc > 0 ? BaseName(argv[0]) : "sketchd";
  if (self == "deb") return RunCli(args);

  if (!args.empty() && args[0] == "serve") return RunDaemon();

  if (!args.empty() && args[0] == "cli") {
    std::vector<std::string> rest(args.begin() + 1, args.end());
    return RunCli(rest);
  }

  return Dispatch(args);
}
