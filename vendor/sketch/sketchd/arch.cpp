// Architecture detection and the cross-arch story.
//
// The kernel already knows how to hand an amd64 ELF to a qemu interpreter
// through binfmt_misc (Android's kernel has CONFIG_BINFMT_MISC and the generic
// kernels register the `qemu-<arch>` handlers from the userland's
// qemu-user-static). This file reports what the image can do and tells the user
// what is missing when it cannot.
#include "sketch.h"

#include <sys/utsname.h>

#include <cstdio>
#include <cstring>

namespace sketch {

Machine HostMachine() {
  struct utsname u;
  if (::uname(&u) != 0) return Machine::kUnknown;
  return ParseMachine(u.machine);
}

Machine ParseMachine(const std::string& name) {
  if (name == "aarch64" || name == "arm64") return Machine::kAarch64;
  if (name == "x86_64" || name == "amd64") return Machine::kX86_64;
  if (name == "armv7l" || name == "armv8l" || name == "armhf" || name == "arm") return Machine::kArm;
  if (name == "i686" || name == "i386" || name == "x86") return Machine::kI386;
  return Machine::kUnknown;
}

const char* MachineName(Machine m) {
  switch (m) {
    case Machine::kAarch64: return "arm64";
    case Machine::kX86_64: return "amd64";
    case Machine::kArm: return "armhf";
    case Machine::kI386: return "i386";
    default: return "unknown";
  }
}

const char* DebianArch(Machine m) {
  switch (m) {
    case Machine::kAarch64: return "arm64";
    case Machine::kX86_64: return "amd64";
    case Machine::kArm: return "armhf";
    case Machine::kI386: return "i386";
    default: return "";
  }
}

const char* QemuInterpreter(Machine m) {
  switch (m) {
    case Machine::kAarch64: return "qemu-aarch64-static";
    case Machine::kX86_64: return "qemu-x86_64-static";
    case Machine::kArm: return "qemu-arm-static";
    case Machine::kI386: return "qemu-i386-static";
    default: return "";
  }
}

bool CanRunNatively(Machine target) {
  Machine host = HostMachine();
  if (host == Machine::kUnknown || target == Machine::kUnknown) return false;
  return host == target;
}

bool CanRunEmulated(Machine target) {
  const char* interp = QemuInterpreter(target);
  if (interp == nullptr || interp[0] == '\0') return false;
  // The kernel reports a registered handler as a binfmt_misc entry.
  std::string entry = std::string("/proc/sys/fs/binfmt_misc/") + interp;
  std::string enabled;
  if (!ReadFile(entry, enabled)) return false;
  return Trim(enabled) == "enabled";
}

void PrintArchStatus() {
  Machine host = HostMachine();
  RootfsPaths p = DefaultPaths();
  Machine rootfs = RootfsMachine(p);

  std::printf("SketchOpenSourceProject\n");
  std::printf("host cpu          : %s\n", MachineName(host));
  std::printf("debian arch       : %s\n", DebianArch(host));
  std::printf("userland          : %s (%s)\n", p.rootfs.c_str(),
              RootfsInstalled(p) ? DebianArch(rootfs) : "not installed");
  std::printf("\n");

  std::printf("arm64 packages    : %s\n",
              CanRunNatively(Machine::kAarch64) ? "native"
              : CanRunEmulated(Machine::kAarch64) ? "via qemu-aarch64-static"
                                                  : "no - needs qemu-aarch64-static");
  std::printf("amd64 packages    : %s\n",
              CanRunNatively(Machine::kX86_64) ? "native"
              : CanRunEmulated(Machine::kX86_64) ? "via qemu-x86_64-static"
                                                 : "no - needs qemu-x86_64-static");

  bool any_emulated = (host != Machine::kAarch64 && CanRunEmulated(Machine::kAarch64)) ||
                      (host != Machine::kX86_64 && CanRunEmulated(Machine::kX86_64));
  if (any_emulated) {
    std::printf("\nCross-arch packages work but run interpreted: expect 5-20x slower\n"
                "than native. Install the native build of anything heavy.\n");
  } else {
    std::printf("\nNo cross-arch interpreter registered. Either run `deb rootfs init`\n"
                "so qemu-user-static lands in the userland, or check that\n"
                "CONFIG_BINFMT_MISC is set in your kernel.\n");
  }
}

}  // namespace sketch
