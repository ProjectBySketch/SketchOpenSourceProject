// SketchOpenSourceProject shared declarations.
//
// Small on purpose: bionic, libstdc++ and nothing else, so the daemon builds in
// any LineageOS 23 (Android 16) tree without pulling in libbase or liblog.
//
// Design note: this does not reimplement dpkg. It owns the chroot, the mounts
// and the binfmt story, and hands package work to the dpkg that lives inside
// the Debian userland - so gz, xz, zstd and bzip2 packages all work exactly as
// Debian intends, and maintainer scripts run with a real shell.
#pragma once

#include <sys/types.h>

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace sketch {

// ---------------------------------------------------------------- util.cpp --

bool WriteAll(int fd, const std::string& data);
bool WriteFile(const std::string& path, const std::string& data);
bool ReadFile(const std::string& path, std::string& out);

void LogErrno(const std::string& msg);
void LogInfo(const std::string& msg);

bool Mkdirs(const std::string& path, unsigned mode = 0755);
bool PathExists(const std::string& path);
bool IsDir(const std::string& path);

std::string DirName(const std::string& path);
std::string BaseName(const std::string& path);
std::string JoinPath(const std::string& a, const std::string& b);
std::string UnderRoot(const std::string& root, const std::string& rel);

std::vector<std::string> SplitWs(const std::string& s);
std::string Trim(const std::string& s);
bool EndsWith(const std::string& s, const std::string& suffix);
bool StartsWith(const std::string& s, const std::string& prefix);

// fork + execvp + waitpid. Returns the exit code, 127 if exec failed and
// 128+signal if the child was killed.
int RunProcess(const std::vector<std::string>& argv);
// Same, with the child's stdout and stderr collected into `out`.
int RunProcessCapture(const std::vector<std::string>& argv, std::string& out);
// Recursive copy of one file, mode preserved. Used to stage a .deb.
bool CopyFile(const std::string& from, const std::string& to, std::string& err);

// --------------------------------------------------------------- arch.cpp ---

enum class Machine {
  kUnknown = 0,
  kAarch64,
  kX86_64,
  kArm,
  kI386,
};

Machine HostMachine();
Machine ParseMachine(const std::string& debian_arch_or_machine);
const char* MachineName(Machine m);
const char* DebianArch(Machine m);
const char* QemuInterpreter(Machine m);

bool CanRunNatively(Machine target);
bool CanRunEmulated(Machine target);

void PrintArchStatus();

// ---------------------------------------------------------------- rootfs.cpp -

struct RootfsPaths {
  std::string base;       // /data/sketch, or $SKETCH_BASE when set
  std::string rootfs;     // <base>/rootfs
  std::string db;         // <base>/db
  std::string cache;      // <base>/cache
  std::string run;        // <base>/run
  std::string log;        // <base>/log
};

RootfsPaths DefaultPaths();
bool EnsureDirs(const RootfsPaths& p, std::string& err);

bool RootfsInstalled(const RootfsPaths& p);
Machine RootfsMachine(const RootfsPaths& p);

// Unpacks the Debian tarball into /data/sketch/rootfs. `from` may be empty, in
// which case /system_ext/sketch/rootfs-<arch>.tar.gz is used, falling back to
// /data/sketch/rootfs-<arch>.tar.gz (for a tarball pushed by hand).
bool InstallRootfs(const RootfsPaths& p, const std::string& from, std::string& err);

// Bind-mounts /dev, /dev/pts, /proc and /sys into the rootfs; unmounts them on
// destruction. Idempotent: mounts that are already there are left alone.
class ChrootMounts {
 public:
  ChrootMounts() = default;
  ~ChrootMounts();
  bool Mount(const std::string& rootfs, std::string& err);
  void Unmount();

 private:
  std::vector<std::string> mounted_;
  bool active_ = false;
};

// Runs argv inside the rootfs with a clean environment.
int RunInChroot(const RootfsPaths& p, const std::vector<std::string>& argv);

// True when the rootfs exists; if not, installs it. Every command that touches
// packages calls this first, so `deb install` works on a fresh boot.
bool EnsureRootfs(const RootfsPaths& p, std::string& err);

// ---------------------------------------------------------------- daemon.cpp -

int RunDaemon();
// Sends one request to a running daemon. False when there is none.
bool CallDaemon(const std::vector<std::string>& argv, int& exit_code);

// -------------------------------------------------------------- commands.cpp -

int CommandInstall(const std::vector<std::string>& args);
int CommandRemove(const std::vector<std::string>& args);
int CommandList(const std::vector<std::string>& args);
int CommandInfo(const std::vector<std::string>& args);
int CommandRun(const std::vector<std::string>& args);
int CommandShell(const std::vector<std::string>& args);
int CommandArch(const std::vector<std::string>& args);
int CommandRootfs(const std::vector<std::string>& args);
int CommandDebloat(const std::vector<std::string>& args);
int CommandAbout(const std::vector<std::string>& args);
int CommandHelp(const std::vector<std::string>& args);

// Dispatches a verb (argv without the program name). -1 when it is unknown.
int Dispatch(const std::vector<std::string>& argv);

}  // namespace sketch
