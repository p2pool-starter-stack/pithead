bundle_support_read_py() {
    cat <<'PY'
import os, re, stat, sys


def regular(path, *args, size=None, **kw):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    st = os.fstat(fd)
    if stat.S_ISREG(st.st_mode) and size in (None, st.st_size):
        return os.fdopen(fd, *args, **kw)
    os.close(fd)
    raise OSError("not a regular file of the expected size")


def guards(path):
    try:
        fh = regular(path, "rb")
    except OSError as exc:
        sys.exit("the Tor state file is not readable: %s" % type(exc).__name__)
    with fh:
        for line in fh.read(1048576).split(b"\n"):
            if re.match(rb"(TorVersion|LastWritten|Guard) ", line):
                sys.stdout.buffer.write(re.sub(rb"bridge_addr=[^ ]+", b"bridge_addr=[redacted]", line) + b"\n")
PY
}
