// Small helpers: paths, files, processes, string trimming. No libbase, no liblog.
#include "sketch.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdio>

namespace sketch {

bool WriteAll(int fd, const std::string& data) {
  size_t off = 0;
  while (off < data.size()) {
    ssize_t n = ::write(fd, data.data() + off, data.size() - off);
    if (n < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    off += static_cast<size_t>(n);
  }
  return true;
}

bool WriteFile(const std::string& path, const std::string& data) {
  int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
  if (fd < 0) return false;
  bool ok = WriteAll(fd, data);
  ::close(fd);
  return ok;
}

bool ReadFile(const std::string& path, std::string& out) {
  int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
  if (fd < 0) return false;
  out.clear();
  char buf[8192];
  for (;;) {
    ssize_t n = ::read(fd, buf, sizeof(buf));
    if (n < 0) {
      if (errno == EINTR) continue;
      ::close(fd);
      return false;
    }
    if (n == 0) break;
    out.append(buf, static_cast<size_t>(n));
  }
  ::close(fd);
  return true;
}

void LogErrno(const std::string& msg) {
  std::fprintf(stderr, "sketchd: %s: %s\n", msg.c_str(), strerror(errno));
  std::fflush(stderr);
}

void LogInfo(const std::string& msg) {
  std::fprintf(stderr, "sketchd: %s\n", msg.c_str());
  std::fflush(stderr);
}

bool Mkdirs(const std::string& path, unsigned mode) {
  if (path.empty()) return false;
  if (IsDir(path)) return true;
  std::string cur;
  size_t i = 0;
  if (path[0] == '/') {
    cur = "/";
    i = 1;
  }
  while (i <= path.size()) {
    size_t next = path.find('/', i);
    if (next == std::string::npos) next = path.size();
    if (next > i) {
      if (!cur.empty() && cur.back() != '/') cur += '/';
      cur.append(path, i, next - i);
      if (::mkdir(cur.c_str(), mode) != 0 && errno != EEXIST) return false;
    }
    i = next + 1;
  }
  return IsDir(path);
}

bool PathExists(const std::string& path) {
  struct stat st;
  return ::lstat(path.c_str(), &st) == 0;
}

bool IsDir(const std::string& path) {
  struct stat st;
  return ::stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

std::string DirName(const std::string& path) {
  size_t pos = path.find_last_of('/');
  if (pos == std::string::npos) return ".";
  if (pos == 0) return "/";
  return path.substr(0, pos);
}

std::string BaseName(const std::string& path) {
  size_t pos = path.find_last_of('/');
  if (pos == std::string::npos) return path;
  return path.substr(pos + 1);
}

std::string JoinPath(const std::string& a, const std::string& b) {
  if (a.empty()) return b;
  if (b.empty()) return a;
  if (a.back() == '/') return a + b;
  return a + "/" + b;
}

std::string UnderRoot(const std::string& root, const std::string& rel) {
  std::string clean = rel;
  while (!clean.empty() && clean.front() == '/') clean.erase(clean.begin());
  return JoinPath(root, clean);
}

std::vector<std::string> SplitWs(const std::string& s) {
  std::vector<std::string> out;
  size_t i = 0;
  while (i < s.size()) {
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) ++i;
    size_t start = i;
    while (i < s.size() && !(s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) ++i;
    if (i > start) out.push_back(s.substr(start, i - start));
  }
  return out;
}

std::string Trim(const std::string& s) {
  size_t b = 0, e = s.size();
  while (b < e && (s[b] == ' ' || s[b] == '\t' || s[b] == '\r' || s[b] == '\n')) ++b;
  while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t' || s[e - 1] == '\r' || s[e - 1] == '\n')) --e;
  return s.substr(b, e - b);
}

bool EndsWith(const std::string& s, const std::string& suffix) {
  return s.size() >= suffix.size() &&
         s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

bool StartsWith(const std::string& s, const std::string& prefix) {
  return s.size() >= prefix.size() && s.compare(0, prefix.size(), prefix) == 0;
}

namespace {

// Builds the argv vector for execvp. The strings must outlive the call.
std::vector<char*> ToArgv(const std::vector<std::string>& argv) {
  std::vector<char*> raw;
  raw.reserve(argv.size() + 1);
  for (const std::string& a : argv) raw.push_back(const_cast<char*>(a.c_str()));
  raw.push_back(nullptr);
  return raw;
}

}  // namespace

int RunProcess(const std::vector<std::string>& argv) {
  if (argv.empty()) return 127;
  std::vector<char*> raw = ToArgv(argv);
  pid_t pid = ::fork();
  if (pid < 0) {
    LogErrno("fork");
    return 127;
  }
  if (pid == 0) {
    ::execvp(raw[0], raw.data());
    _exit(127);
  }
  int status = 0;
  while (::waitpid(pid, &status, 0) < 0) {
    if (errno != EINTR) return 127;
  }
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 127;
}

int RunProcessCapture(const std::vector<std::string>& argv, std::string& out) {
  out.clear();
  if (argv.empty()) return 127;
  int pipefd[2];
  if (::pipe2(pipefd, O_CLOEXEC) != 0) {
    LogErrno("pipe");
    return 127;
  }
  std::vector<char*> raw = ToArgv(argv);
  pid_t pid = ::fork();
  if (pid < 0) {
    LogErrno("fork");
    ::close(pipefd[0]);
    ::close(pipefd[1]);
    return 127;
  }
  if (pid == 0) {
    ::close(pipefd[0]);
    ::dup2(pipefd[1], STDOUT_FILENO);
    ::dup2(pipefd[1], STDERR_FILENO);
    ::close(pipefd[1]);
    ::execvp(raw[0], raw.data());
    _exit(127);
  }
  ::close(pipefd[1]);
  char buf[4096];
  for (;;) {
    ssize_t n = ::read(pipefd[0], buf, sizeof(buf));
    if (n < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (n == 0) break;
    out.append(buf, static_cast<size_t>(n));
  }
  ::close(pipefd[0]);
  int status = 0;
  while (::waitpid(pid, &status, 0) < 0) {
    if (errno != EINTR) return 127;
  }
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 127;
}

bool CopyFile(const std::string& from, const std::string& to, std::string& err) {
  int in = ::open(from.c_str(), O_RDONLY | O_CLOEXEC);
  if (in < 0) {
    err = "cannot open " + from + ": " + strerror(errno);
    return false;
  }
  struct stat st;
  if (::fstat(in, &st) != 0) {
    err = "cannot stat " + from + ": " + strerror(errno);
    ::close(in);
    return false;
  }
  int out = ::open(to.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, st.st_mode & 0777);
  if (out < 0) {
    err = "cannot create " + to + ": " + strerror(errno);
    ::close(in);
    return false;
  }
  char buf[65536];
  bool ok = true;
  for (;;) {
    ssize_t n = ::read(in, buf, sizeof(buf));
    if (n < 0) {
      if (errno == EINTR) continue;
      err = std::string("read: ") + strerror(errno);
      ok = false;
      break;
    }
    if (n == 0) break;
    if (!WriteAll(out, std::string(buf, static_cast<size_t>(n)))) {
      err = std::string("write: ") + strerror(errno);
      ok = false;
      break;
    }
  }
  ::close(in);
  ::close(out);
  return ok;
}

}  // namespace sketch
