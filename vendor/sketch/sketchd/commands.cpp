// The command implementations. Each one is the body of a `deb` subcommand.
#include "sketch.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>

namespace sketch {

namespace {

// A .deb is an ar archive and starts with this magic. Checking it here gives a
// clear error instead of dpkg's "not a debian format archive" in the chroot.
bool LooksLikeDeb(const std::string& path, std::string& err) {
  int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    err = "cannot open " + path + ": " + strerror(errno);
    return false;
  }
  char magic[8] = {};
  ssize_t n = ::read(fd, magic, sizeof(magic));
  ::close(fd);
  if (n != 8 || ::memcmp(magic, "!<arch>\n", 8) != 0) {
    err = path + " is not a .deb (no ar magic)";
    return false;
  }
  return true;
}

// The package file has to be visible inside the chroot, so it is copied into
// the userland's /var/tmp first and removed again afterwards.
class StagedDeb {
 public:
  StagedDeb() = default;
  ~StagedDeb() {
    if (!host_path_.empty()) ::unlink(host_path_.c_str());
  }

  bool Stage(const RootfsPaths& p, const std::string& source, std::string& err) {
    std::string name = BaseName(source);
    if (name.empty()) name = "package.deb";
    host_path_ = JoinPath(p.rootfs, "var/tmp/" + name);
    if (!Mkdirs(JoinPath(p.rootfs, "var/tmp"))) {
      err = "cannot create " + JoinPath(p.rootfs, "var/tmp");
      return false;
    }
    if (!CopyFile(source, host_path_, err)) return false;
    chroot_path_ = "/var/tmp/" + name;
    return true;
  }

  const std::string& chroot_path() const { return chroot_path_; }

 private:
  std::string host_path_;
  std::string chroot_path_;
};

int RequireRoot() {
  if (::geteuid() != 0) {
    std::fprintf(stderr,
                 "deb: needs root. On a userdebug build run `adb root` first, "
                 "otherwise `su -c 'deb ...'`.\n");
    return 1;
  }
  return 0;
}

// dpkg's own database, read straight out of the userland. The read-only commands
// use this when they are not root, so `deb list` works from an ordinary shell
// without a chroot or a mount.
std::vector<std::map<std::string, std::string>> ReadStatusDb(const RootfsPaths& p) {
  std::vector<std::map<std::string, std::string>> out;
  std::string text;
  if (!ReadFile(JoinPath(p.rootfs, "var/lib/dpkg/status"), text)) return out;

  std::map<std::string, std::string> cur;
  size_t pos = 0;
  while (pos < text.size()) {
    size_t nl = text.find('\n', pos);
    if (nl == std::string::npos) nl = text.size();
    std::string line = text.substr(pos, nl - pos);
    pos = nl + 1;

    if (Trim(line).empty()) {
      if (!cur.empty()) {
        out.push_back(cur);
        cur.clear();
      }
      continue;
    }
    if (line[0] == ' ' || line[0] == '\t') continue;   // continuation line
    size_t colon = line.find(':');
    if (colon == std::string::npos) continue;
    cur[Trim(line.substr(0, colon))] = Trim(line.substr(colon + 1));
  }
  if (!cur.empty()) out.push_back(cur);
  return out;
}

bool IsInstalled(const std::map<std::string, std::string>& stanza) {
  auto it = stanza.find("Status");
  return it != stanza.end() && it->second.find("installed") != std::string::npos;
}

std::string Field(const std::map<std::string, std::string>& stanza, const char* key) {
  auto it = stanza.find(key);
  return it == stanza.end() ? std::string("-") : it->second;
}

// Everything that runs a command in the chroot goes through here so the
// "userland is missing" case has exactly one message.
int InRootfs(const RootfsPaths& p, const std::vector<std::string>& argv) {
  std::string err;
  if (!EnsureRootfs(p, err)) {
    std::fprintf(stderr, "deb: %s\n", err.c_str());
    return 1;
  }
  return RunInChroot(p, argv);
}

void UsageInstall() {
  std::fprintf(stderr,
               "usage: deb install [--extract] <file.deb> [<file.deb> ...]\n"
               "  default        dpkg -i: unpack, then run the maintainer scripts\n"
               "  --extract      unpack only, no scripts, no dependency handling\n");
}

void Usage() {
  std::fprintf(stderr,
               "SketchOpenSourceProject - Debian .deb packages on this device\n\n"
               "  deb install [--extract] <file.deb>...\n"
               "  deb remove <package>...\n"
               "  deb list\n"
               "  deb info <package>|<file.deb>\n"
               "  deb run <command> [args...]\n"
               "  deb shell\n"
               "  deb arch\n"
               "  deb rootfs [init|status]\n"
               "  deb debloat\n"
               "  deb about\n");
}

}  // namespace

int CommandInstall(const std::vector<std::string>& args) {
  if (args.empty()) {
    UsageInstall();
    return 2;
  }

  bool extract_only = false;
  std::vector<std::string> debs;
  for (const std::string& a : args) {
    if (a == "--extract" || a == "-x") {
      extract_only = true;
    } else if (a == "--dpkg") {
      extract_only = false;
    } else if (!a.empty() && a[0] == '-') {
      std::fprintf(stderr, "deb install: unknown option %s\n", a.c_str());
      return 2;
    } else {
      debs.push_back(a);
    }
  }
  if (debs.empty()) {
    UsageInstall();
    return 2;
  }
  if (int rc = RequireRoot()) return rc;

  for (const std::string& deb : debs) {
    std::string err;
    if (!LooksLikeDeb(deb, err)) {
      std::fprintf(stderr, "deb install: %s\n", err.c_str());
      return 1;
    }
  }

  RootfsPaths p = DefaultPaths();
  if (int rc = InRootfs(p, {"/bin/true"})) {
    std::fprintf(stderr, "deb install: the userland is not usable\n");
    return rc;
  }

  int last = 0;
  for (const std::string& deb : debs) {
    StagedDeb staged;
    std::string err;
    if (!staged.Stage(p, deb, err)) {
      std::fprintf(stderr, "deb install: %s\n", err.c_str());
      return 1;
    }

    std::vector<std::string> argv;
    if (extract_only) {
      // dpkg-deb --extract into / is the same thing dpkg does before scripts.
      argv = {"/usr/bin/dpkg-deb", "--extract", staged.chroot_path(), "/"};
    } else {
      // --force-depends: the Debian archive's dependency graph is often
      // unsatisfiable on a phone, and a half-installed package you can inspect
      // beats a refusal. dpkg still records what is missing.
      argv = {"/usr/bin/dpkg", "-i", "--force-depends", staged.chroot_path()};
    }

    std::printf("deb: %s %s\n", extract_only ? "unpacking" : "installing",
                BaseName(deb).c_str());
    int rc = RunInChroot(p, argv);
    if (rc != 0) {
      std::fprintf(stderr, "deb: %s exited with %d\n", argv[0].c_str(), rc);
      last = rc;
    }
  }
  return last;
}

int CommandRemove(const std::vector<std::string>& args) {
  if (args.empty()) {
    std::fprintf(stderr, "usage: deb remove <package>...\n");
    return 2;
  }
  if (int rc = RequireRoot()) return rc;

  RootfsPaths p = DefaultPaths();
  std::vector<std::string> argv = {"/usr/bin/dpkg", "--purge", "--force-depends"};
  argv.insert(argv.end(), args.begin(), args.end());
  return InRootfs(p, argv);
}

int CommandList(const std::vector<std::string>& args) {
  RootfsPaths p = DefaultPaths();
  if (!RootfsInstalled(p)) {
    std::printf("no Debian packages installed (userland not set up yet)\n");
    return 0;
  }

  // Read-only, so no chroot and no root needed: parse the database directly.
  if (::geteuid() != 0) {
    auto db = ReadStatusDb(p);
    if (db.empty()) {
      std::printf("no packages\n");
      return 0;
    }
    for (const auto& stanza : db) {
      if (!IsInstalled(stanza)) continue;
      std::printf("%s\t%s\t%s\n", Field(stanza, "Package").c_str(),
                  Field(stanza, "Version").c_str(),
                  Field(stanza, "Architecture").c_str());
    }
    return 0;
  }

  std::vector<std::string> argv = {
      "/usr/bin/dpkg-query", "-W",
      "-f=${binary:Package}\t${Version}\t${Architecture}\n"};
  return InRootfs(p, argv);
}

int CommandInfo(const std::vector<std::string>& args) {
  if (args.empty()) {
    std::fprintf(stderr, "usage: deb info <package>|<file.deb>\n");
    return 2;
  }
  const std::string& what = args[0];
  RootfsPaths p = DefaultPaths();

  bool is_file = EndsWith(what, ".deb") || PathExists(what);
  if (!is_file) {
    // Same trick as `deb list`: no root needed to read the database.
    if (::geteuid() != 0) {
      auto db = ReadStatusDb(p);
      for (const auto& stanza : db) {
        if (Field(stanza, "Package") != what) continue;
        for (const auto& kv : stanza) {
          std::printf("%-16s: %s\n", kv.first.c_str(), kv.second.c_str());
        }
        return 0;
      }
      std::fprintf(stderr, "deb info: no package named %s\n", what.c_str());
      return 1;
    }
    return InRootfs(p, {"/usr/bin/dpkg-query", "-s", what});
  }

  std::string err;
  if (!LooksLikeDeb(what, err)) {
    std::fprintf(stderr, "deb info: %s\n", err.c_str());
    return 1;
  }
  if (int rc = RequireRoot()) return rc;

  StagedDeb staged;
  if (!staged.Stage(p, what, err)) {
    std::fprintf(stderr, "deb info: %s\n", err.c_str());
    return 1;
  }
  int rc = InRootfs(p, {"/usr/bin/dpkg-deb", "--info", staged.chroot_path()});
  if (rc == 0) {
    std::printf("\nfiles in this package:\n");
    // sh -c with $1, so a path with spaces still works.
    InRootfs(p, {"/bin/sh", "-c",
                 "/usr/bin/dpkg-deb --contents \"$1\" | wc -l",
                 "sketch-info", staged.chroot_path()});
  }
  return rc;
}

int CommandRun(const std::vector<std::string>& args) {
  if (args.empty()) {
    std::fprintf(stderr, "usage: deb run <command> [args...]\n");
    return 2;
  }
  if (int rc = RequireRoot()) return rc;
  RootfsPaths p = DefaultPaths();
  return InRootfs(p, args);
}

int CommandShell(const std::vector<std::string>& args) {
  if (int rc = RequireRoot()) return rc;
  RootfsPaths p = DefaultPaths();
  // -i so bash reads /root/.bashrc and gives job control; the terminal comes
  // from adb shell or the on-device terminal app.
  return InRootfs(p, {"/bin/bash", "-i"});
}

int CommandArch(const std::vector<std::string>& args) {
  PrintArchStatus();
  return 0;
}

int CommandRootfs(const std::vector<std::string>& args) {
  const std::string sub = args.empty() ? "status" : args[0];
  RootfsPaths p = DefaultPaths();

  if (sub == "status") {
    std::printf("base      : %s\n", p.base.c_str());
    std::printf("userland  : %s (%s)\n", p.rootfs.c_str(),
                RootfsInstalled(p) ? "installed" : "not installed");
    if (RootfsInstalled(p)) {
      std::printf("arch      : %s\n", DebianArch(RootfsMachine(p)));
    }
    std::printf("packages  : %s\n", JoinPath(p.rootfs, "var/lib/dpkg/status").c_str());
    std::printf("log       : %s\n", p.log.c_str());
    return 0;
  }

  if (sub == "init") {
    if (int rc = RequireRoot()) return rc;
    std::string err;
    if (!EnsureDirs(p, err)) {
      std::fprintf(stderr, "deb rootfs init: %s\n", err.c_str());
      return 1;
    }
    if (RootfsInstalled(p)) {
      std::printf("userland already installed at %s\n", p.rootfs.c_str());
      return 0;
    }
    if (!InstallRootfs(p, args.size() > 1 ? args[1] : "", err)) {
      std::fprintf(stderr, "deb rootfs init: %s\n", err.c_str());
      return 1;
    }
    std::printf("userland installed at %s (%s)\n", p.rootfs.c_str(),
                DebianArch(RootfsMachine(p)));
    return 0;
  }

  std::fprintf(stderr, "usage: deb rootfs [init [tarball]|status]\n");
  return 2;
}

int CommandDebloat(const std::vector<std::string>& args) {
  std::printf(
      "This image is a SketchOpenSourceProject build (vendor/sketch/debloat.mk).\n\n"
      "The base is LineageOS 23, which ships with no Google apps at all - no\n"
      "Play services, no Play Store, no GMS. On top of that, this build removes\n"
      "the stock AOSP apps a lightweight image does not need:\n"
      "  apps      browser, calendar, camera, clock, email, music, print stack,\n"
      "            settings intelligence, quick search, wallpaper pickers, live\n"
      "            wallpapers, bookmarks provider, STK, WAPPush, Protips, Traceur\n"
      "  debug     development, SDK setup, simulator app dialog\n"
      "  first run setup wizard disabled, checkin disabled, verify-only dexopt\n\n"
      "Check what is actually on the device:\n"
      "  ls /system/app /system/priv-app /system_ext/app\n"
      "Put a package back by deleting its line in vendor/sketch/debloat.mk and\n"
      "rebuilding. ro.sketch.debloat=1 marks the image.\n");
  return 0;
}

int CommandAbout(const std::vector<std::string>& args) {
  std::printf(
      "SketchOpenSourceProject\n"
      "  a lightweight Android 16 build on LineageOS (no Google apps)\n"
      "  that installs and runs Debian .deb packages\n\n"
      "  base      LineageOS 23 (Android 16)\n"
      "  runtime   dpkg inside a Debian chroot, qemu-user for cross-arch\n"
      "  built for arm64 and amd64\n\n"
      "  deb arch      what this image can run\n"
      "  deb debloat   what was left out\n"
      "  deb install   install a package\n");
  return 0;
}

int CommandHelp(const std::vector<std::string>& args) {
  Usage();
  return 0;
}

int Dispatch(const std::vector<std::string>& argv) {
  if (argv.empty()) {
    Usage();
    return 2;
  }
  const std::string& verb = argv[0];
  std::vector<std::string> rest(argv.begin() + 1, argv.end());

  if (verb == "install" || verb == "i" || verb == "add") return CommandInstall(rest);
  if (verb == "remove" || verb == "rm" || verb == "purge") return CommandRemove(rest);
  if (verb == "list" || verb == "ls") return CommandList(rest);
  if (verb == "info" || verb == "show") return CommandInfo(rest);
  if (verb == "run" || verb == "exec") return CommandRun(rest);
  if (verb == "shell") return CommandShell(rest);
  if (verb == "arch") return CommandArch(rest);
  if (verb == "rootfs") return CommandRootfs(rest);
  if (verb == "debloat") return CommandDebloat(rest);
  if (verb == "about" || verb == "version") return CommandAbout(rest);
  if (verb == "help" || verb == "--help" || verb == "-h") return CommandHelp(rest);

  std::fprintf(stderr, "deb: unknown command '%s'\n\n", verb.c_str());
  Usage();
  return 2;
}

}  // namespace sketch
