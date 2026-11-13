// The Debian userland: where it lives, how it gets unpacked, and how a command
// is run inside it.
//
// Everything here runs as root. sketchd is started by init from a service, and
// the CLI refuses to work when it is not root, so there is no privilege dance
// to get wrong.
#include "sketch.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>

namespace sketch {

namespace {

// Where the image keeps the userland tarball it was built with.
constexpr const char* kSystemExtDir = "/system_ext/sketch";

// toybox tar handles gzip and preserves ownership when run as root. Off-device
// (a Linux host, CI, a container) there is no toybox, so fall back to whatever
// tar the system has - which is what makes the whole runtime runnable without
// an Android image at all.
std::string TarBinary() {
  static const char* kCandidates[] = {
      "/system/bin/tar", "/bin/tar", "/usr/bin/tar", "/usr/local/bin/tar",
  };
  for (const char* c : kCandidates) {
    if (PathExists(c)) return c;
  }
  return "tar";   // last resort: let execvp search PATH
}

bool Mounted(const std::string& target) {
  std::string mounts;
  if (!ReadFile("/proc/mounts", mounts)) return false;
  return mounts.find(" " + target + " ") != std::string::npos;
}

bool BindMount(const std::string& source, const std::string& target, bool* mounted_now) {
  *mounted_now = false;
  if (!PathExists(source)) return true;          // nothing to bind, not an error
  if (Mounted(target)) return true;              // someone else already did it
  if (!Mkdirs(target)) return false;
  if (::mount(source.c_str(), target.c_str(), nullptr, MS_BIND | MS_REC, nullptr) != 0) {
    LogErrno("mount " + source + " -> " + target);
    return false;
  }
  *mounted_now = true;
  return true;
}

}  // namespace

RootfsPaths DefaultPaths() {
  RootfsPaths p;
  // SKETCH_BASE exists so the runtime can be exercised somewhere other than a
  // phone: a Linux host, a container, a CI runner, or a scratch directory.
  // On a device it is unset and this is /data/sketch.
  const char* base = ::getenv("SKETCH_BASE");
  p.base = (base != nullptr && base[0] != '\0') ? base : "/data/sketch";
  p.rootfs = JoinPath(p.base, "rootfs");
  p.db = JoinPath(p.base, "db");
  p.cache = JoinPath(p.base, "cache");
  p.run = JoinPath(p.base, "run");
  p.log = JoinPath(p.base, "log");
  return p;
}

bool EnsureDirs(const RootfsPaths& p, std::string& err) {
  const char* dirs[] = {p.base.c_str(), p.rootfs.c_str(), p.db.c_str(),
                        p.cache.c_str(), p.run.c_str(), p.log.c_str()};
  for (const char* d : dirs) {
    if (!Mkdirs(d)) {
      err = std::string("cannot create ") + d + ": " + strerror(errno);
      return false;
    }
  }
  return true;
}

bool RootfsInstalled(const RootfsPaths& p) {
  return PathExists(JoinPath(p.rootfs, "etc/sketch-arch"));
}

Machine RootfsMachine(const RootfsPaths& p) {
  std::string s;
  if (!ReadFile(JoinPath(p.rootfs, "etc/sketch-arch"), s)) return Machine::kUnknown;
  return ParseMachine(Trim(s));
}

bool InstallRootfs(const RootfsPaths& p, const std::string& from, std::string& err) {
  std::string tarball = from;
  if (tarball.empty()) {
    Machine host = HostMachine();
    const char* arch = DebianArch(host);
    std::vector<std::string> candidates = {
        std::string(kSystemExtDir) + "/rootfs-" + arch + ".tar.gz",
        JoinPath(p.base, std::string("rootfs-") + arch + ".tar.gz"),
        std::string(kSystemExtDir) + "/rootfs.tar.gz",
        JoinPath(p.base, "rootfs.tar.gz"),
    };
    for (const std::string& c : candidates) {
      if (PathExists(c)) {
        tarball = c;
        break;
      }
    }
    if (tarball.empty()) {
      err = std::string("no userland tarball found; expected ") + kSystemExtDir +
            "/rootfs-" + arch + ".tar.gz\n"
            "Build one with ./build.sh rootfs " + arch +
            ", or push one to /data/sketch/rootfs-" + arch + ".tar.gz";
      return false;
    }
  }

  if (!PathExists(tarball)) {
    err = "no such tarball: " + tarball;
    return false;
  }
  if (!Mkdirs(p.rootfs)) {
    err = "cannot create " + p.rootfs + ": " + strerror(errno);
    return false;
  }

  LogInfo("unpacking " + tarball + " into " + p.rootfs);
  int rc = RunProcess({TarBinary(), "-xzf", tarball, "-C", p.rootfs});
  if (rc != 0) {
    err = "tar failed with exit code " + std::to_string(rc);
    return false;
  }

  if (!RootfsInstalled(p)) {
    err = "the tarball did not contain etc/sketch-arch - is it a Sketch userland?";
    return false;
  }
  return true;
}

bool EnsureRootfs(const RootfsPaths& p, std::string& err) {
  if (!EnsureDirs(p, err)) return false;
  if (RootfsInstalled(p)) return true;
  LogInfo("no userland yet, installing it (this takes a minute the first time)");
  return InstallRootfs(p, "", err);
}

ChrootMounts::~ChrootMounts() { Unmount(); }

bool ChrootMounts::Mount(const std::string& rootfs, std::string& err) {
  if (active_) return true;
  struct {
    const char* source;
    const char* rel;
  } kMounts[] = {
      {"/dev", "dev"},
      {"/proc", "proc"},
      {"/sys", "sys"},
  };
  for (const auto& m : kMounts) {
    std::string target = JoinPath(rootfs, m.rel);
    if (!Mkdirs(target)) {
      err = "cannot create " + target + ": " + strerror(errno);
      Unmount();
      return false;
    }
    bool mounted_now = false;
    if (!BindMount(m.source, target, &mounted_now)) {
      err = std::string("cannot bind mount ") + m.source;
      Unmount();
      return false;
    }
    // Only unmount what this object mounted: a mount that was already there
    // belongs to whoever made it.
    if (mounted_now) mounted_.push_back(target);
  }
  active_ = true;
  return true;
}

void ChrootMounts::Unmount() {
  for (auto it = mounted_.rbegin(); it != mounted_.rend(); ++it) {
    // MNT_DETACH: busy mounts (a package's process still running) must not
    // wedge the daemon.
    if (::umount2(it->c_str(), MNT_DETACH) != 0) LogErrno("umount " + *it);
  }
  mounted_.clear();
  active_ = false;
}

int RunInChroot(const RootfsPaths& p, const std::vector<std::string>& argv) {
  if (argv.empty()) return 127;

  std::string err;
  ChrootMounts mounts;
  if (!mounts.Mount(p.rootfs, err)) {
    std::fprintf(stderr, "sketchd: %s\n", err.c_str());
    return 1;
  }

  std::vector<char*> raw;
  raw.reserve(argv.size() + 1);
  for (const std::string& a : argv) raw.push_back(const_cast<char*>(a.c_str()));
  raw.push_back(nullptr);

  pid_t pid = ::fork();
  if (pid < 0) {
    LogErrno("fork");
    return 1;
  }
  if (pid == 0) {
    if (::chroot(p.rootfs.c_str()) != 0) {
      LogErrno("chroot " + p.rootfs);
      _exit(126);
    }
    if (::chdir("/") != 0) _exit(126);
    // A clean environment: Android's own variables would confuse dpkg and the
    // maintainer scripts (LD_PRELOAD, ANDROID_ROOT, and so on).
    ::clearenv();
    ::setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
    ::setenv("HOME", "/root", 1);
    ::setenv("LANG", "C.UTF-8", 1);
    ::setenv("DEBIAN_FRONTEND", "noninteractive", 1);
    ::setenv("TERM", ::getenv("TERM") != nullptr ? ::getenv("TERM") : "dumb", 1);
    ::execvp(raw[0], raw.data());
    LogErrno(std::string("exec ") + raw[0]);
    _exit(127);
  }

  int status = 0;
  while (::waitpid(pid, &status, 0) < 0) {
    if (errno != EINTR) {
      mounts.Unmount();
      return 1;
    }
  }
  mounts.Unmount();

  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 1;
}

}  // namespace sketch
