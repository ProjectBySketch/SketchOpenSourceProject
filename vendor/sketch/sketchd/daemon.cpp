// The daemon: a unix socket that runs one SketchOpenSourceProject request per
// connection.
//
// Why it exists: the CLI needs root to chroot and mount, and `adb root` is not
// always what you want. With the daemon running, `deb install x.deb` works from
// an ordinary root shell of the image and the mounts are set up once by the
// process that already has the privileges.
//
// Wire format, deliberately dull:
//   client -> server   NUL-separated argv, then NUL, then shutdown(WR)
//   server -> client   the command's stdout and stderr, verbatim, followed by
//                      one marker line carrying the exit code
#include "sketch.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>

namespace sketch {

namespace {

// Starts with a control character so no command output can be mistaken for it.
constexpr char kExitMarker[] = "\x1eSKETCH-EXIT:";
constexpr size_t kMarkerLen = sizeof(kExitMarker) - 1;

std::string SocketPath() { return JoinPath(DefaultPaths().run, "sketchd.sock"); }

void SendExitCode(int fd, int code) {
  std::string line = std::string("\n") + kExitMarker + std::to_string(code) + "\n";
  WriteAll(fd, line);
}

// Reads the whole request: argv entries separated by NUL.
bool ReadRequest(int fd, std::vector<std::string>& argv) {
  std::string buf;
  char chunk[4096];
  for (;;) {
    ssize_t n = ::read(fd, chunk, sizeof(chunk));
    if (n < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    if (n == 0) break;
    buf.append(chunk, static_cast<size_t>(n));
    if (buf.size() > (1u << 20)) return false;   // a request is never this big
  }
  size_t start = 0;
  while (start < buf.size()) {
    size_t end = buf.find('\0', start);
    if (end == std::string::npos) end = buf.size();
    if (end > start) argv.push_back(buf.substr(start, end - start));
    start = end + 1;
  }
  return !argv.empty();
}

void HandleConnection(int conn) {
  std::vector<std::string> argv;
  if (!ReadRequest(conn, argv)) {
    SendExitCode(conn, 2);
    return;
  }

  // Point stdout and stderr at the socket for the duration of the request, then
  // put them back: the daemon keeps running after this connection closes, and
  // its own log must not end up pointing at a dead fd.
  int saved_out = ::dup(STDOUT_FILENO);
  int saved_err = ::dup(STDERR_FILENO);
  if (::dup2(conn, STDOUT_FILENO) < 0 || ::dup2(conn, STDERR_FILENO) < 0) {
    if (saved_out >= 0) ::close(saved_out);
    if (saved_err >= 0) ::close(saved_err);
    SendExitCode(conn, 1);
    return;
  }

  int rc = Dispatch(argv);
  std::fflush(stdout);
  std::fflush(stderr);

  if (saved_out >= 0) {
    ::dup2(saved_out, STDOUT_FILENO);
    ::close(saved_out);
  }
  if (saved_err >= 0) {
    ::dup2(saved_err, STDERR_FILENO);
    ::close(saved_err);
  }
  SendExitCode(conn, rc);
}

volatile sig_atomic_t g_stop = 0;

void OnSignal(int) { g_stop = 1; }

}  // namespace

int RunDaemon() {
  RootfsPaths p = DefaultPaths();
  std::string err;
  if (!EnsureDirs(p, err)) {
    std::fprintf(stderr, "sketchd: %s\n", err.c_str());
    return 1;
  }

  std::string path = SocketPath();
  ::unlink(path.c_str());

  int server = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (server < 0) {
    LogErrno("socket");
    return 1;
  }

  struct sockaddr_un addr;
  ::memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  if (path.size() >= sizeof(addr.sun_path)) {
    std::fprintf(stderr, "sketchd: socket path too long: %s\n", path.c_str());
    ::close(server);
    return 1;
  }
  ::memcpy(addr.sun_path, path.c_str(), path.size());

  if (::bind(server, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) != 0) {
    LogErrno("bind " + path);
    ::close(server);
    return 1;
  }
  // Root and the system group only: everything here runs as root.
  ::chmod(path.c_str(), 0660);
  if (::listen(server, 8) != 0) {
    LogErrno("listen");
    ::close(server);
    return 1;
  }

  struct sigaction sa;
  ::memset(&sa, 0, sizeof(sa));
  sa.sa_handler = OnSignal;
  ::sigaction(SIGTERM, &sa, nullptr);
  ::sigaction(SIGINT, &sa, nullptr);
  ::signal(SIGPIPE, SIG_IGN);
  ::signal(SIGCHLD, SIG_IGN);   // children are reaped by the kernel

  LogInfo("listening on " + path);

  // Requests are served one at a time. dpkg in a single userland is not safe to
  // run concurrently anyway, and serialising means one request's chroot mounts
  // can never be torn down by another.
  while (!g_stop) {
    int conn = ::accept4(server, nullptr, nullptr, SOCK_CLOEXEC);
    if (conn < 0) {
      if (errno == EINTR) continue;
      LogErrno("accept");
      break;
    }
    HandleConnection(conn);
    ::close(conn);
  }

  ::close(server);
  ::unlink(path.c_str());
  LogInfo("stopped");
  return 0;
}

bool CallDaemon(const std::vector<std::string>& argv, int& exit_code) {
  std::string path = SocketPath();
  int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return false;

  struct sockaddr_un addr;
  ::memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  if (path.size() >= sizeof(addr.sun_path)) {
    ::close(fd);
    return false;
  }
  ::memcpy(addr.sun_path, path.c_str(), path.size());

  if (::connect(fd, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) != 0) {
    ::close(fd);
    return false;
  }

  std::string request;
  for (const std::string& a : argv) {
    request += a;
    request += '\0';
  }
  request += '\0';
  if (!WriteAll(fd, request)) {
    ::close(fd);
    return false;
  }
  ::shutdown(fd, SHUT_WR);

  // Stream the output through, holding back enough of the tail that the exit
  // marker is never printed.
  std::string pending;
  char chunk[4096];
  for (;;) {
    ssize_t n = ::read(fd, chunk, sizeof(chunk));
    if (n < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (n == 0) break;
    pending.append(chunk, static_cast<size_t>(n));
    if (pending.size() > kMarkerLen + 1) {
      size_t keep = kMarkerLen + 1;
      size_t flush = pending.size() - keep;
      WriteAll(STDOUT_FILENO, pending.substr(0, flush));
      pending.erase(0, flush);
    }
  }
  ::close(fd);

  // The tail holds the marker line, if the daemon got that far.
  size_t marker = pending.rfind(kExitMarker);
  if (marker == std::string::npos) {
    WriteAll(STDOUT_FILENO, pending);
    exit_code = 1;
    return true;
  }
  WriteAll(STDOUT_FILENO, pending.substr(0, marker));
  size_t digits = marker + kMarkerLen;
  size_t end = digits;
  while (end < pending.size() && pending[end] >= '0' && pending[end] <= '9') ++end;
  exit_code = std::atoi(pending.substr(digits, end - digits).c_str());
  return true;
}

}  // namespace sketch
